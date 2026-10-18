import SwiftUI
import Minimuxer

/// AFC media transfer: the bulk photo/video trees, moved between the device's
/// `/var/mobile/Media` and this app's container.
///
/// The destructive half is behind its own switch, **off by default**. A first run
/// copies and verifies; only once the switch is on does a verified copy also
/// remove the original. That ordering is the whole reason the switch exists --
/// the store in the container is the only copy of a photo once its original is
/// gone, and the container is something iOS deletes with the app.
struct MediaView: View {
    @AppStorage("AfcMedia.deleteOriginals") private var deleteOriginals = false
    @State private var survey: AfcMediaBackup.Survey?
    @State private var manifest: AfcMediaBackup.Manifest?
    @State private var busy = false
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var confirmPull = false

    private var free: Int64 { AfcMediaBackup.containerFreeBytes() }

    /// Read once on entry rather than starting at nil. The two store-dependent
    /// buttons gate on `manifest?.entries`, so a nil manifest disabled both of
    /// them for the whole session -- including after a pull from a previous run,
    /// which is exactly when you come back to push or clear.
    private func loadManifest() {
        manifest = try? AfcMediaBackup.read()
        hasStoredFiles = storeHasFiles()
    }

    /// Whether the store holds anything — computed **once per load or action**,
    /// not on every body pass.
    ///
    /// `storeHasFiles` walks the store tree for leftovers, and the old computed
    /// property sat in two `.disabled(...)` modifiers: every re-render of this
    /// page walked the directory twice, on the main thread.  The answer only
    /// changes when an action runs, and every action ends here.
    @State private var hasStoredFiles = false

    /// From the filesystem rather than from the last run's manifest: a pull that
    /// was interrupted, or files left by an earlier build, are real data that
    /// "Empty" must still be able to remove.
    private func storeHasFiles() -> Bool {
        if let m = manifest, !m.entries.isEmpty { return true }
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: AfcMediaBackup.storeRoot.path) else { return false }
        for case let name as String in walker where name.hasSuffix(".afcpartial") { return true }
        return false
    }

    var body: some View {
        List {
            mediaSection
            if !lines.isEmpty { logSection }
            if let error { errorSection(error) }
        }
        .listStyle(.insetGrouped)
        .task { loadManifest() }
        // The only page that had no navigation bar at all, because it used to be
        // the one destination reached from a launcher (Home's card grid) rather
        // than pushed on a stack, so it never needed a back button.  Both of
        // those are gone: the sidebar is the only way in and it pushes like
        // everything else, so this page gets the same bar as the rest — title
        // included, which it never had.
        .navigationTitle("媒体")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "复制后删除 \(survey?.files.count ?? 0) 个原始文件？",
            isPresented: $confirmPull, titleVisibility: .visible
        ) {
            Button("复制并删除原始文件", role: .destructive) { Task { await doPull() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(bytes(survey?.bytes ?? 0)) 将被移入本应用的容器。"
                + "该处可用空间：\(bytes(free))。一旦删除，"
                + "容器中的副本就是唯一副本——而且如果删除本应用，"
                + "容器也会一并删除。")
        }
    }

    private var mediaSection: some View {
        Section("AFC 媒体") {
            NativeNote("将 \(AfcMediaBackup.trees.joined(separator: "、")) "
                + "从设备的 Media 根目录经 AFC 复制到本应用的容器。"
                + "无需照片图库权限。")
            surveyRows
            deleteSwitch
            Button {
                Task { await pull() }
            } label: {
                Label("拉取媒体", systemImage: "arrow.down.doc")
            }
            .disabled(busy)
            Button {
                Task { await push() }
            } label: {
                Label("推送回设备", systemImage: "arrow.up.doc")
            }
            .disabled(busy || !hasStoredFiles)
            // Was `try?` with a success message printed either way, so a failure
            // looked identical to a success. It is routed through run() so the
            // error surfaces, and loadManifest() re-reads rather than assuming
            // the store is empty now.
            Button(role: .destructive) {
                Task {
                    await run {
                        try AfcMediaBackup.clear()
                        loadManifest()
                        lines.append("本地媒体存储已清空。")
                    }
                }
            } label: {
                Label("清空本地存储", systemImage: "trash")
            }
            .disabled(busy || !hasStoredFiles)
            NativeSafetyNote("只有在原始文件已回到设备并通过校验之后，"
                + "才能安全地清空存储。")
        }
    }

    @ViewBuilder
    private var surveyRows: some View {
        if let survey {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(survey.files.count) 个文件，\(bytes(survey.bytes))"
                    + (survey.skippedSymlinks > 0 ? "，\(survey.skippedSymlinks) 个符号链接已跳过" : ""))
                    .font(.body)
                NativeNote("容器可用空间：\(bytes(free))。")
            }
        } else {
            Text("尚未扫描")
                .foregroundStyle(.secondary)
        }
        Button {
            Task { await runSurvey() }
        } label: {
            Label("扫描", systemImage: "magnifyingglass")
        }
        .disabled(busy)
    }

    private var deleteSwitch: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $deleteOriginals) {
                Text("复制后删除原始文件")
                    .foregroundStyle(deleteOriginals ? Color.red : Color.primary)
            }
            NativeNote(deleteOriginals
                ? "只有在副本大小通过校验后，才会删除对应的原始文件。"
                : "关闭：仅创建副本，原始文件保留在原处。")
        }
    }

    private var logSection: some View {
        Section("日志") {
            ForEach(lines.suffix(40), id: \.self) { line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section("失败") {
            NativeSafetyNote(error)
        }
    }

    // MARK: - Actions

    private func runSurvey() async {
        await run {
            let s = try await AfcMediaBackup.survey()
            survey = s
            lines = ["扫描：\(s.files.count) 个文件，\(bytes(s.bytes))。"]
        }
    }

    private func pull() async {
        if deleteOriginals { confirmPull = true; return }
        await doPull()
    }

    private func doPull() async {
        await run {
            let m = try await AfcMediaBackup.pull(deletingOriginals: deleteOriginals) { line in
                Task { @MainActor in lines.append(line) }
            }
            manifest = m
            // The store just changed, so the gate on Push/Empty has to be
            // recomputed here — `loadManifest()` is not called on this path.
            hasStoredFiles = storeHasFiles()
            let removed = m.entries.filter(\.deleted).count
            lines.append("已拉取 \(m.entries.count) 个文件；已删除 \(removed) 个原始文件。")
        }
    }

    private func push() async {
        await run {
            try await AfcMediaBackup.push { line in
                Task { @MainActor in lines.append(line) }
            }
            loadManifest()
        }
    }

    /// One place for the busy flag, the log and the error, so no action can end
    /// up half-updating them.
    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await body()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
