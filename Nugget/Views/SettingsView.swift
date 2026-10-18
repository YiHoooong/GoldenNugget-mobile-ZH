import SwiftUI
import Minimuxer

/// Settings: what this build is, and the switches that change what a run does.
///
/// A plain `Form` in the system's grouped style.  The platform draws the
/// surface, the section headers, the row insets, the disclosure chrome and the
/// Liquid Glass; every colour and font here is semantic, so light and dark and
/// the user's text size all work without a palette of our own.
///
/// The About half is what a bug report actually needs — version, build, and the
/// two log files with their sizes.  The Apply half is the one switch that is not
/// a development switch: Skip Setup.  The Development half sits behind a master
/// switch because every row on it changes a real device.
struct SettingsView: View {
    // Reactive mirrors of `DevSettings.Key`, so a toggle redraws the page. The
    // engine reads the same strings through `DevSettings.effective`.
    @AppStorage(DevSettings.Key.enabled) private var devModeOn = false
    @AppStorage(DevSettings.Key.forcePartialRestore) private var forcePartialRestore = false
    @AppStorage(DevSettings.Key.verboseLog) private var verboseLog = true
    @AppStorage(DevSettings.Key.skipAfcMedia) private var skipAfcMedia = false

    /// Skip Setup's switch. Observed rather than mirrored with a second
    /// `@AppStorage` on the same key: the store is what the engine reads.
    @ObservedObject private var skipSetup = SkipSetupSettings.shared

    /// Read through `engine` rather than recomputed in the body, because a log is
    /// written by another thread while this page is open.
    @State private var logs = LogSizes()

    /// The setup guide, as a full-screen cover.
    ///
    /// It is the same view the app opens with on a first launch, on purpose: a
    /// second "getting started" page would be a second set of instructions to fall
    /// out of step with the first, and the whole reason this row exists is that a
    /// user who skipped the gate still needs it. A `NavigationLink` would have no
    /// place to return to after "Finish setup", which on an already-set-up app
    /// changes nothing the user can see.
    @State private var showSetupGuide = false

    /// The operation history (the port of `apply_history.py` and the desktop
    /// Settings page's *Operation History* card).  Held as loaded records and
    /// re-read whenever the page's filters change or an operation is cleared —
    /// the desktop re-reads the file on every refresh, and nothing else here
    /// watches the file.
    @State private var history: [ApplyHistory.Record] = []
    @State private var historySearch = ""
    @State private var historyMode = "all"
    @State private var historyResult = "all"

    /// Sizes and existence of the two files a report is built from.
    private struct LogSizes: Equatable {
        var appBytes: UInt64 = 0
        var rustBytes: UInt64 = 0
        var rustStatus: String = ""

        var appKB: UInt64 { appBytes / 1024 }
        var rustKB: UInt64 { rustBytes / 1024 }
        var hasApp: Bool { appBytes > 0 }
        var hasRust: Bool { rustBytes > 0 }
    }

    var body: some View {
        Form {
            aboutSection
            creditsSection
            setupSection
            logsSection
            applySection
            historySection
            developmentSection
        }
        .navigationTitle("设置")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSetupGuide) {
            NavigationStack {
                FirstRunView { showSetupGuide = false }
            }
        }
        .task {
            refreshLogs()
            refreshHistory()
        }
        .onChange(of: devModeOn) { _, _ in DevSettings.applyLoggingPreference() }
        .onChange(of: verboseLog) { _, _ in DevSettings.applyLoggingPreference() }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            VStack(spacing: 12) {
                NativeLogo(size: 88)
                Text("GoldenNugget")
                    .font(.title2.bold())
                Text(Self.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            // A credit, not a setting: centred and on its own, so it does not
            // read as a row.
            Text("用 ❤️ 打造\nGoldenNugget 开发团队")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)

            NativeNote("桌面版 GoldenNugget 是本应用的原始版本。"
                + "它在自己的 Rust 与 Swift 技术栈上"
                + "运行同一套协议，而不依赖 pymobiledevice3，"
                + "支持 iOS 26 与 27，而不只支持有线连接的设备。")
        }
    }

    // MARK: - Credits

    /// What the app is built on, and by whom. Every row is a component that is
    /// really in the binary — the two static Rust/C archives are linked into the
    /// executable rather than embedded as frameworks (only `EMProxy.framework`
    /// ships as a dynamic framework in the IPA).
    private var creditsSection: some View {
        Section("致谢") {
            creditRow("GoldenNugget", "桌面版应用 · 本应用是其移植版本",
                      systemImage: "desktopcomputer")
            creditRow("idevice", "Rust 设备与备份堆栈",
                      systemImage: "shippingbox")
            creditRow("libimobiledevice", "C 协议核心",
                      systemImage: "chevron.left.forwardslash.chevron.right")
            creditRow("Minimuxer", "SideStore · 隧道与 usbmux",
                      systemImage: "network")
            creditRow("ZIPFoundation", "归档处理",
                      systemImage: "archivebox")
            NativeNote("内置的第三方副本带有本地补丁，每个补丁的原因列在 "
                + "Vendor/patches/README.md 中。SideStore 的 minimuxer "
                + "版权归 © 2026 SideStore 所有。")
        }
    }

    private func creditRow(_ title: String, _ role: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(role)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Setup

    /// The guide, reachable after the fact.
    ///
    /// Its own section rather than a row under Apply: those rows are switches a run
    /// reads, and this one changes nothing about a run — it opens a screen. It
    /// also sits above them, because it is the answer to "why is nothing
    /// connecting", which is the question a user opens Settings with.
    private var setupSection: some View {
        Section("初始设置") {
            Button {
                showSetupGuide = true
            } label: {
                Label("初始设置指南", systemImage: "list.number")
            }
            NativeNote("检查本应用连接设备前所需的两项条件——"
                + "LocalDevVPN 隧道和配对记录——并逐步说明"
                + "两者的操作。这就是首次启动时打开的指南。")
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("日志") {
            // The two halves of a report's evidence: this one is what the host
            // decided, the other is what the protocol did.
            shareRow(title: "goldennugget.log",
                     size: logs.appKB,
                     systemImage: "doc.plaintext",
                     url: GoldenNuggetEngine.appLogURL,
                     available: logs.hasApp)
            shareRow(title: "minimuxer.log",
                     size: logs.rustKB,
                     systemImage: "doc.text.magnifyingglass",
                     url: GoldenNuggetEngine.rustLogURL,
                     available: logs.hasRust)
            if !logs.hasRust, !logs.rustStatus.isEmpty {
                NativeNote(logs.rustStatus)
            }
            NativeNote(logs.hasApp
                ? "报告需要这两个文件：应用日志说明做了哪些决定，"
                  + "minimuxer.log 说明设备如何应答。"
                : "还没有应用日志——它会在本次会话首次运行时写入。")
        }
    }

    private func shareRow(title: String, size: UInt64, systemImage: String,
                          url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Label("\(title) (\(size) KB)", systemImage: systemImage)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(available ? Color.primary : Color.secondary)
    }

    // MARK: - Apply

    /// Skip Setup, on its own page rather than behind the Development master: it is
    /// not a switch for working around a bug, it is part of what a run writes.
    private var applySection: some View {
        Section("应用") {
            switchRow("跳过设置",
                      note: skipSetupNote,
                      isOn: Binding(
                          get: { skipSetup.skipSetupEnabled },
                          set: { skipSetup.setSkipSetup($0) }))
        }
    }

    /// What the switch does, in the order the two files are written.
    private var skipSetupNote: String {
        [
            "默认开启，与上游一致。关闭时：应用只携带调整项。",
            "开启时：应用会在调整项之前添加两个文件，顺序如下——",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/"
                + "Library/ConfigurationProfiles/CloudConfigurationDetails.plist，其中 "
                + "\(SkipSetup.panes.count) 个设置面板已标记为跳过；",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist，设置已标记为完成。",
            "设备现有的云配置不会被合并进来（读取它需要"
                + "此移植版没有实现的 lockdown 服务），也不会生成"
                + "keybag 证书。",
        ].joined(separator: "\n")
    }

    // MARK: - Operation History

    /// The desktop Settings page's *Operation History* card
    /// (`gui/ios/settings.py:741`): the last operations, searchable and
    /// filterable, read from the same `operations.json` the reference writes
    /// (`apply_history.py`).
    ///
    /// The desktop also reaches the preset actions from this page; here they
    /// live on their own **Presets** page, so only the history is duplicated
    /// from the reference's Settings.
    private var historySection: some View {
        Section("操作历史") {
            TextField("搜索历史…", text: $historySearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("操作", selection: $historyMode) {
                Text("所有操作").tag("all")
                Text("应用").tag("apply")
                Text("重置").tag("reset")
            }
            .pickerStyle(.segmented)

            Picker("结果", selection: $historyResult) {
                Text("所有结果").tag("all")
                Text("成功").tag("success")
                Text("失败").tag("failed")
            }
            .pickerStyle(.segmented)

            Text(historyCountLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyRowText(record))
                        .font(.subheadline)
                    if !record.error.isEmpty {
                        Text(record.error)
                            .font(.caption)
                            .foregroundStyle(record.success ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                ApplyHistory.clear()
                refreshHistory()
            } label: {
                Label("清除历史", systemImage: "trash")
            }
            .disabled(history.isEmpty)
        }
    }

    /// Newest-first, filtered and searched exactly as the reference's
    /// `_refresh_history` does (`settings.py:783`).
    private var matchingHistory: [ApplyHistory.Record] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.reversed().filter { item in
            if historyMode != "all" && item.mode != historyMode { return false }
            if historyResult == "success" && !item.success { return false }
            if historyResult == "failed" && item.success { return false }
            guard !query.isEmpty else { return true }
            let haystack = [item.timestamp, item.mode, item.device, item.model, item.ios, item.error]
                .joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    /// The reference caps the list at ten rows (`settings.py:804`).
    private var visibleHistory: [ApplyHistory.Record] {
        Array(matchingHistory.prefix(10))
    }

    private var historyCountLine: String {
        let matches = matchingHistory.count
        if matches > visibleHistory.count {
            return "显示 \(visibleHistory.count) 条，共 \(matches) 条操作"
        }
        if matches > 0 {
            return "找到 \(matches) 条操作"
        }
        let filtered = !historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || historyMode != "all" || historyResult != "all"
        return filtered ? "没有匹配的操作" : "尚无操作记录"
    }

    /// One row's line, in the reference's own vocabulary
    /// (`settings.py:823`): `when • mode • device • iOS version • result`.
    private func historyRowText(_ record: ApplyHistory.Record) -> String {
        let mode = record.mode == "apply" ? "应用" : "重置"
        let result = record.success ? "成功" : "失败"
        let device = record.device.isEmpty ? "未知设备" : record.device
        let ios = record.ios.isEmpty ? "?" : record.ios
        return "\(Self.displayTimestamp(record.timestamp))  •  \(mode)  •  "
            + "\(device)  •  iOS \(ios)  •  \(result)"
    }

    /// `datetime.fromisoformat(...).strftime("%Y-%m-%d %H:%M")`, falling back to
    /// the stored string when it is not a parseable timestamp.
    private static func displayTimestamp(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func refreshHistory() {
        history = ApplyHistory.load()
    }

    // MARK: - Development

    private var developmentSection: some View {
        Section("开发") {
            Toggle(isOn: $devModeOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开发模式")
                    NativeNote(devModeOn
                        ? "下面的开关将应用于下次运行。"
                        : "关闭时：运行走正常路径，已保存的开关会被忽略。")
                }
            }

            if devModeOn {
                switchRow("强制部分恢复",
                          note: "采用 iOS 26 分支——从零构建的部分恢复——"
                              + "即便设备报告为 iOS 27 及以上，"
                              + "也会完全跳过保护性备份。",
                          isOn: $forcePartialRestore)

                switchRow("详细日志",
                          note: verboseLog
                            ? "将协议细节记录到 minimuxer.log。"
                              + "关闭后仍保留应用日志和运行本身，但会丢弃"
                              + "逐帧日志。"
                            : "协议细节未被记录。应用日志仍会记录。",
                          isOn: $verboseLog)

                switchRow("跳过 AFC 媒体",
                          note: "运行通常会在备份与清理之间复制相册媒体。"
                              + "此开关会跳过这一步；对于完整的"
                              + "相册，这意味着几分钟和几秒钟的差别。",
                          isOn: $skipAfcMedia)

                Button("重置开关", systemImage: "arrow.counterclockwise") {
                    DevSettings.resetSwitches()
                    DevSettings.applyLoggingPreference()
                }

                NativeSafetyNote("这些是开关，不是修复手段。对真实的 iOS 27 设备使用“强制部分恢复”"
                    + "预计会在恢复步骤失败，"
                    + "因为合成的清单不包含域注册信息。")
            }
        }
    }

    // MARK: - Rows

    /// A labelled switch with the explanation underneath it.
    private func switchRow(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                NativeNote(note)
            }
        }
    }

    private func refreshLogs() {
        logs = LogSizes(appBytes: GoldenNuggetEngine.appLogSize(),
                        rustBytes: GoldenNuggetEngine.rustLogSize(),
                        rustStatus: GoldenNuggetEngine.rustLogStatus())
    }

    // MARK: - Bundle facts

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "未知"
    }

    private static var versionText: String {
        "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))"
    }
}
