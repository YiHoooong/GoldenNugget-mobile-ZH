import SwiftUI
import UniformTypeIdentifiers

/// Passcode (lock screen keypad) themes.
///
/// The page imports a `.passthm`, shows what is in it, and writes it into
/// TelephonyUI's caches. The two settings that look like a preference —
/// language and weight — are the part worth explaining: the device picks a file
/// by name, encoding the locale, the weight and the key's subtext, so a theme is
/// a matrix of files rather than a single image, and these two settings decide
/// how much of that matrix gets written.
struct PasscodeThemeView: View {
    @State private var identity: DeviceIdentity = .unknown
    @State private var theme: PasscodeThemeInfo?
    @State private var language: PasscodeLanguageTarget = .all
    @State private var weight: PasscodeBoldTarget = .both
    @State private var log: [String] = []
    @State private var status: String?
    @State private var tone: GoldenTone = .secondary
    @State private var running = false
    @State private var showImporter = false

    var body: some View {
        List {
            deviceSection
            importSection
            if let theme { previewSection(theme) }
            optionsSection
            applySection
            if let status {
                Section {
                    Text(status)
                        .foregroundStyle(tone.nativeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !log.isEmpty { runLog }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("密码")
        .navigationBarTitleDisplayMode(.inline)
        .task { identity = await DeviceIdentity.read() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            importTheme(result)
        }
    }

    private var blocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift 需要配对记录，但目前尚未存储。请在主页导入一个。"
        }
        return ""
    }

    // MARK: - Cards

    private var deviceSection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("键盘的外观文件会写入 "
                + "/var/mobile/Library/Caches/TelephonyUI-…，它属于缓存而非"
                + "偏好设置，因此备份无法携带它。锁定设备即可查看效果。")
            if !blocker.isEmpty { NativeSafetyNote(blocker) }
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label(theme == nil ? "导入 .passthm" : "再导入一个",
                      systemImage: "square.and.arrow.down")
            }
            if let theme {
                NativeNote("\(theme.name) — \(theme.fileCount) 个文件，"
                    + "找到 \(theme.keysPreview.count) 个按键。")
            }
        }
    }

    private func previewSection(_ theme: PasscodeThemeInfo) -> some View {
        Section("按键") {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { column in
                        keySlot(theme, row: row, column: column)
                    }
                }
            }
        }
    }

    private func keySlot(_ theme: PasscodeThemeInfo, row: Int, column: Int) -> some View {
        let digit = KeypadLayout.digits.first {
            KeypadLayout.row(for: $0) == row && KeypadLayout.column(for: $0) == column
        }
        return VStack(spacing: 4) {
            if let digit, let image = theme.keysPreview[digit] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 44)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: 44)
            }
            Text(digit ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var optionsSection: some View {
        Section {
            optionRow(title: "语言", selection: $language, choices: PasscodeLanguageTarget.allCases)
            optionRow(title: "字重", selection: $weight, choices: PasscodeBoldTarget.allCases)
            NativeNote("设备会为每种语言、字重和按键"
                + "副文本各索取一个文件。“所有语言”会写入所有变体——这是唯一"
                + "在你不了解设备语言时也能生效的设置；而设备自身的"
                + "语言区域和回退项在任一种设置下都会包含。")
        }
    }

    /// A titled picker row.
    ///
    /// The platform control is used rather than a hand-drawn one: a picker on iOS
    /// *is* the wheel-and-menu the reference draws, and a switch would be the
    /// wrong shape for a seventeen-value choice.
    private func optionRow<Option: Identifiable & Hashable & RawRepresentable>(
        title: String,
        selection: Binding<Option>,
        choices: [Option]
    ) -> some View where Option.RawValue == String, Option.ID == String {
        Picker(title, selection: selection) {
            ForEach(choices) { option in
                Text(optionTitle(option)).tag(option)
            }
        }
    }

    /// The picker shows the localized display name; `id`/`rawValue` stay the
    /// stable identifiers the theme writer matches on.
    private func optionTitle<Option: RawRepresentable>(_ option: Option) -> String
    where Option.RawValue == String {
        switch option {
        case let language as PasscodeLanguageTarget: return language.title
        case let weight as PasscodeBoldTarget: return weight.title
        default: return option.rawValue
        }
    }

    private var applySection: some View {
        Section {
            Button {
                apply()
            } label: {
                HStack {
                    Label(running ? "正在应用…" : "应用主题",
                          systemImage: "lock.rectangle.stack.fill")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(running || theme == nil || !blocker.isEmpty)
            if !blocker.isEmpty { NativeSafetyNote(blocker) }
        }
    }

    private var runLog: some View {
        Section {
            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func importTheme(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // The importer hands back a security-scoped URL; the archive is read on
            // this side of the boundary, so the scope has to be open for the read —
            // and for the whole unpack, which is where the time goes.
            let scoped = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let loaded = try await PasscodeThemeReader.inspect(url: url)
                    theme = loaded
                    status = "已载入 \(loaded.name)。"
                    tone = .primary
                } catch {
                    status = error.localizedDescription
                    tone = .error
                }
            }
        case .failure(let error):
            status = error.localizedDescription
            tone = .error
        }
    }

    private func apply() {
        guard let theme else { return }
        running = true
        log = []
        Task { @MainActor in
            defer { running = false }
            do {
                try await PasscodeThemeEngine.apply(
                    theme: theme,
                    language: language,
                    weight: weight,
                    pairingPath: AppPaths.pairingFile.path,
                    log: { line in Task { @MainActor in log.append(line) } },
                    progress: { _ in }
                )
                status = "主题已应用。锁定设备即可查看。"
                tone = .primary
            } catch {
                status = error.localizedDescription
                tone = .error
            }
        }
    }
}
