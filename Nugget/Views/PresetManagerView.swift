import SwiftUI
import UniformTypeIdentifiers

/// The preset manager — GoldenNugget's `IOSPresetsPage`
/// (`src/gui/ios/presets.py`) and the actions it shares with the home popup
/// (`src/gui/ios/preset_menu.py`).
///
/// The reference's whole toolkit lives here: save the current configuration,
/// load one (with the compatibility warnings), delete, export, partial export,
/// import, and roll back to the snapshot taken before the last successful
/// apply.  The desktop's animated *Manage* popup on the home screen is not
/// reproduced — its own *Manage presets* button opens a full page, and a
/// phone-width screen wants the page.
///
/// **Documented divergence**: the reference relaunches the app after a load so
/// the freshly written config is read back.  Here a load writes straight into
/// the live selection and persists it to the autosave the next launch reads,
/// which is the same observable result without a restart.
struct PresetManagerView: View {
    /// The live selection.  Loading a preset writes into it, because the
    /// **home Apply** is what delivers it — the same hoisted binding the Tweaks
    /// and Daemons pages edit.
    @Binding var selection: TweakSelection

    @ObservedObject private var deviceMonitor = DeviceIdentityMonitor.shared
    private var identity: DeviceIdentity { deviceMonitor.current }

    @State private var presets: [GoldenNuggetPresets.PresetInfo] = []
    @State private var selectedName: String?
    @State private var newName = ""
    @State private var newDescription = ""
    /// One status line, in the reference's own words.
    @State private var message: String?
    @State private var messageTone: GoldenTone = .primary
    /// The last load's report, kept visible until the next action.
    @State private var loadReport: TweakImportReport?
    @State private var confirmLoad: GoldenNuggetPresets.PresetInfo?
    @State private var confirmRollback = false
    @State private var pendingDelete: GoldenNuggetPresets.PresetInfo?
    @State private var share: ShareItem?
    @State private var partialExport: PartialExportTarget?
    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                NativeNote("保存、切换并分享完整的调整配置。"
                    + "载入预设会替换当前的选择；"
                    + "主页上的“应用”仍会将其下发到设备。")
            }

            saveSection
            presetsSection
            actionsSection

            if let message { messageSection(message) }
            if let loadReport { reportSection(loadReport) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("预设")
        .navigationBarTitleDisplayMode(.inline)
        // Compact widths only -- the split view draws its own sidebar toggle.
        .goldenSidebarButton()
        .task {
            await deviceMonitor.refresh()
            refresh()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importPreset(from: url)
            case .failure(let error): setMessage(error.localizedDescription, .error)
            }
        }
        .alert("载入预设", isPresented: isPresented($confirmLoad),
               presenting: confirmLoad) { info in
            Button("取消", role: .cancel) { confirmLoad = nil }
            Button("载入") {
                performLoad(info)
                confirmLoad = nil
            }
        } message: { info in
            Text(loadConfirmMessage(info))
        }
        .alert("回滚上次应用", isPresented: $confirmRollback) {
            Button("取消", role: .cancel) {}
            Button("回滚") { performRollback() }
        } message: {
            Text("载入上次成功应用前拍摄的快照？"
                + "这会替换你当前的配置。")
        }
        .alert("删除预设", isPresented: isPresented($pendingDelete),
               presenting: pendingDelete) { info in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                performDelete(info)
                pendingDelete = nil
            }
        } message: { info in
            Text("删除预设“\(info.name)”？")
        }
        .sheet(item: $share) { item in
            ShareSheet(url: item.url)
        }
        .sheet(item: $partialExport) { target in
            PartialExportSheet(target: target) { include in
                partialExport = nil
                export(include: include)
            } onCancel: {
                partialExport = nil
            }
        }
    }

    // MARK: - Sections

    private var saveSection: some View {
        Section("保存当前配置") {
            TextField("预设名称", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("描述（可选）", text: $newDescription)
            Button {
                saveCurrent()
            } label: {
                Label("保存预设", systemImage: "square.and.arrow.down")
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var presetsSection: some View {
        Section("已保存的预设") {
            if presets.isEmpty {
                Text("还没有预设。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets) { info in
                    Button {
                        selectedName = selectedName == info.name ? nil : info.name
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedName == info.name
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedName == info.name
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name)
                                    .foregroundStyle(.primary)
                                Text(subtitle(info))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showImporter = true
            } label: {
                Label("导入预设…", systemImage: "square.and.arrow.up.on.square")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button("载入") { requestLoad() }
                .disabled(selected == nil)
            Button("导出") { export(include: nil) }
                .disabled(selected == nil)
            Button("部分导出…") { requestPartialExport() }
                .disabled(selected == nil)
            Button("回滚上次应用") { requestRollback() }
                .disabled(!GoldenNuggetPresets.hasRollback)
            Button(role: .destructive) {
                pendingDelete = selected
            } label: {
                Text("删除")
            }
            .disabled(selected == nil)
        } footer: {
            Text(GoldenNuggetPresets.hasRollback
                 ? "回滚会恢复上次成功应用前拍摄的快照。"
                 : "成功应用一次后即可使用回滚。")
        }
    }

    private func messageSection(_ text: String) -> some View {
        Section {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(messageTone.nativeColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The same block the Tweaks page writes for an import — the reference logs
    /// one report for both a preset load and an autosave import.
    private func reportSection(_ report: TweakImportReport) -> some View {
        Section("载入结果") {
            ForEach(Array(report.logLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Derived state

    private var selected: GoldenNuggetPresets.PresetInfo? {
        presets.first { $0.name == selectedName }
    }

    /// One-line secondary text for a row: device, iOS, tags — the reference's
    /// `preset_subtitle` (`preset_menu.py:55`).
    private func subtitle(_ info: GoldenNuggetPresets.PresetInfo) -> String {
        var text = "\(info.deviceModel) • iOS \(info.iosVersion)"
        if !info.tags.isEmpty { text += "  #" + info.tags.joined(separator: " #") }
        return text
    }

    // MARK: - Actions

    private func refresh() {
        presets = GoldenNuggetPresets.listWithMetadata()
            .filter { !GoldenNuggetPresets.isInternal($0.name) }
        if let selectedName, !presets.contains(where: { $0.name == selectedName }) {
            self.selectedName = nil
        }
    }

    /// `save_preset_flow` (`preset_menu.py:201`): a name is required, the rest
    /// is the manager's job.
    private func saveCurrent() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setMessage("请输入此预设的名称。", .warning)
            return
        }
        let ok = GoldenNuggetPresets.save(name,
                                          selection: selection,
                                          deviceModel: identity.productType,
                                          iosVersion: identity.version,
                                          description: newDescription)
        guard ok else {
            setMessage("保存预设失败。", .error)
            return
        }
        let stored = GoldenNuggetPresets.sanitize(name)
        setMessage("预设“\(stored)”已保存。", .success)
        newName = ""
        newDescription = ""
        refresh()
        selectedName = stored
    }

    private func requestLoad() {
        guard let info = selected else {
            setMessage("请先选择一个预设。", .warning)
            return
        }
        confirmLoad = info
    }

    /// The reference's confirm text plus its daemon-compatibility warning
    /// (`preset_menu.py:123`).  The hidden-feature warning is not reproduced:
    /// this port has no per-feature safety rules engine to consult.
    private func loadConfirmMessage(_ info: GoldenNuggetPresets.PresetInfo) -> String {
        var text = "载入预设“\(info.name)”？"
        if !info.description.isEmpty { text += "\n\n描述：\(info.description)" }
        text += "\n设备：\(info.deviceModel) • iOS \(info.iosVersion)"
        text += "\n\n这会替换你当前的配置。"
        if let warning = daemonCompatibilityWarning(info) {
            text += "\n\n⚠ \(warning)"
        }
        return text
    }

    private func daemonCompatibilityWarning(_ info: GoldenNuggetPresets.PresetInfo) -> String? {
        guard presetHasDaemonChanges(name: info.name) else { return nil }
        var mismatches: [String] = []
        if let saved = majorVersion(info.iosVersion),
           let current = majorVersion(identity.version), saved != current {
            mismatches.append("iOS \(saved)x 对比当前 iOS \(current)x")
        }
        let savedType = deviceType(info.deviceModel)
        let currentType = deviceType(identity.productType)
        if !savedType.isEmpty && !currentType.isEmpty && savedType != currentType {
            mismatches.append("\(savedType) 对比当前 \(currentType)")
        }
        guard !mismatches.isEmpty else { return nil }
        return "此预设包含为其他设备保存的"
            + "守护进程修改：\n" + mismatches.map { "• \($0)" }.joined(separator: "\n")
            + "\n\n守护进程对 iOS 版本和设备类型很敏感，"
            + "应用不兼容的守护进程可能导致设备启动循环，请谨慎操作。"
    }

    private func performLoad(_ info: GoldenNuggetPresets.PresetInfo) {
        guard let preset = GoldenNuggetPresets.load(info.name) else {
            setMessage("载入预设失败。", .error)
            return
        }
        apply(preset, label: "预设“\(info.name)”已载入。")
    }

    /// `rollback_preset_flow` (`preset_menu.py:188`): the `__Rollback` snapshot
    /// loaded through the ordinary path.
    private func requestRollback() {
        guard GoldenNuggetPresets.hasRollback else {
            setMessage("尚无可回滚的上次成功应用。", .warning)
            return
        }
        confirmRollback = true
    }

    private func performRollback() {
        guard let preset = GoldenNuggetPresets.loadRollback() else {
            setMessage("尚无可回滚的上次成功应用。", .warning)
            return
        }
        apply(preset, label: "已回滚到上次应用的状态。")
    }

    /// `PresetManager.load_preset`'s observable effect, ported: apply the parsed
    /// preset to the live selection, keep it as the autosave, and log the report.
    private func apply(_ preset: GoldenNuggetPreset, label: String) {
        var mutable = selection
        let report = GoldenNuggetPresetImport.apply(preset, to: &mutable,
                                                    deviceVersion: identity.version,
                                                    isIPhone: identity.isIPhone)
        selection = mutable
        _ = GoldenNuggetAutosave.save(selection, identity: identity)
        for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
        loadReport = report
        setMessage(label, .success)
    }

    private func export(include: Set<String>?) {
        guard let info = selected else {
            setMessage("请先选择一个预设。", .warning)
            return
        }
        guard let data = GoldenNuggetPresets.exportData(for: info.name, include: include) else {
            setMessage("导出预设失败。", .error)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(GoldenNuggetPresets.sanitize(info.name)).json")
        do {
            try data.write(to: url, options: .atomic)
            share = ShareItem(url: url)
        } catch {
            setMessage("导出预设失败：\(error.localizedDescription)", .error)
        }
    }

    private func requestPartialExport() {
        guard let info = selected else {
            setMessage("请先选择一个预设。", .warning)
            return
        }
        let ids = GoldenNuggetPresets.tweakIDs(for: info.name)
        guard !ids.isEmpty else {
            setMessage("此预设没有可导出的调整项。", .warning)
            return
        }
        partialExport = PartialExportTarget(info: info, ids: ids)
    }

    private func performDelete(_ info: GoldenNuggetPresets.PresetInfo) {
        guard GoldenNuggetPresets.delete(info.name) else {
            setMessage("删除预设失败。", .error)
            return
        }
        if selectedName == info.name { selectedName = nil }
        setMessage("预设“\(info.name)”已删除。", .success)
        refresh()
    }

    /// `import_preset_flow` (`preset_menu.py:294`): the manager validates the
    /// document and picks a unique name; the page reports the outcome.
    private func importPreset(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let (ok, result) = GoldenNuggetPresets.importPreset(from: url, newName: nil)
        if ok {
            refresh()
            selectedName = result
            setMessage("预设“\(result)”导入成功。", .success)
        } else {
            setMessage("导入预设失败：\(result)", .error)
        }
    }

    // MARK: - Helpers

    private func setMessage(_ text: String, _ tone: GoldenTone) {
        message = text
        messageTone = tone
    }

    /// Whether a stored preset carries daemon changes; the file is read raw
    /// because `presetHasDaemonChanges` takes the parsed root.
    private func presetHasDaemonChanges(name: String) -> Bool {
        let url = GoldenNuggetPresets.fileURL(for: name)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return GoldenNuggetPresets.presetHasDaemonChanges(root)
    }

    private func majorVersion(_ version: String) -> Int? {
        Int(version.split(separator: ".").first ?? "")
    }

    /// `_device_type` (`preset_menu.py:75`): the leading family name only.
    private func deviceType(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.hasPrefix("iphone") { return "iPhone" }
        if lower.hasPrefix("ipad") { return "iPad" }
        return ""
    }

    /// `isPresented:` needs a `Bool` binding even when the value it presents is
    /// optional; this keeps the alert and the pending value in step.
    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil },
                set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: - Export support

/// A file handed to the share sheet.  `Identifiable` so `.sheet(item:)` can
/// present one per export.
private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The reference exports through a save-file dialog; iOS has no such dialog, so
/// the file is written to a temporary directory and offered through the system
/// share sheet.
private struct ShareSheet: View {
    let url: URL

    var body: some View {
        VStack(spacing: 16) {
            ShareLink(item: url) {
                Label("保存或分享预设", systemImage: "square.and.arrow.up")
                    .font(.headline)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Text(url.lastPathComponent)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.height(200)])
    }
}

/// What a partial export is choosing from: the stored preset and the tweak ids
/// it holds (`PartialExportDialog` + `_filter_export`, `preset_manager.py:262`).
private struct PartialExportTarget: Identifiable {
    let info: GoldenNuggetPresets.PresetInfo
    let ids: [String]
    var id: String { info.name }
}

private struct PartialExportSheet: View {
    let target: PartialExportTarget
    let onExport: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var chosen: Set<String>

    init(target: PartialExportTarget,
         onExport: @escaping (Set<String>) -> Void,
         onCancel: @escaping () -> Void) {
        self.target = target
        self.onExport = onExport
        self.onCancel = onCancel
        _chosen = State(initialValue: Set(target.ids))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(target.ids, id: \.self) { id in
                        Button {
                            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen.contains(id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(id)
                                                     ? Color.accentColor : Color.secondary)
                                Text(id).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("要包含的调整项（\(chosen.count)/\(target.ids.count)）")
                }
            }
            .navigationTitle("部分导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") { onExport(chosen) }
                        .disabled(chosen.isEmpty)
                }
            }
        }
    }
}
