import SwiftUI

/// The status-bar page: the classic override struct's fields, item toggles and
/// the iOS 27 carrier-only subset.
///
/// The reference's own page (`src/gui/ios/statusbar.py`) is a flat list of cards
/// with a switch and a pencil button on each row, and it re-gates the whole page
/// whenever the connected device changes version: on iOS 27+ only the rows marked
/// `survives_ios27` stay, and a note explains what happened to the rest.  That
/// gating is reproduced here exactly, for the same reason — the archive carries
/// only the carrier name, its badge and its bar count, so offering the others
/// would be offering a control whose value is silently dropped at apply time.
///
/// The row shape is different on purpose.  The reference toggles the override and
/// then opens a dialog to type the value; this page draws the value in the row
/// (`Stepper` for a level, a field for a string) so the value and its switch are
/// one gesture away from each other, which is what the platform form does
/// everywhere else.  Semantics are unchanged: the switch says whether the
/// override is delivered, and the value says what it delivers.
struct StatusBarView: View {
    /// Everything this page edits, **owned by `RootView`**: the selection is
    /// delivered by the home page's single `Apply`, and a `NavigationSplitView`
    /// destroys page state on every sidebar selection — so as page state the
    /// whole selection would be lost by walking over to press the button.
    @Binding var selection: StatusBarSelection

    @ObservedObject private var deviceMonitor = DeviceIdentityMonitor.shared

    /// The device version this page is currently drawing for.
    ///
    /// Read from the shared monitor rather than on this page's own, because the
    /// gate is the *device's* version and a device can be swapped or reboot under
    /// a live tunnel: the reference re-gates in `showEvent` for the same reason.
    private var mechanism: StatusBarMechanism {
        StatusBarMechanism.mechanism(for: deviceMonitor.current.version)
    }

    /// What the page needs to re-save after an edit.
    ///
    /// Every control writes through here rather than calling `saveToDisk` itself,
    /// so that turning a switch **off** is persisted the same way turning a value
    /// on is — a per-control `onChange` would only fire for some of them, and the
    /// classic failure of that is a selection that comes back with a stale
    /// override the user is sure they removed.
    private func edited() {
        selection.saveToDisk()
    }

    var body: some View {
        List {
            enableSection
            if mechanism == .archive { archiveNote }
            textSection
            levelsSection
            // The archive carries no per-item state and no silly-mode flag, and
            // the raw toggles have no archive field either. The reference hides
            // these three sections whole on iOS 27; leaving a header up with
            // nothing under it would read as a failed load.
            if mechanism == .classic {
                rawSection
                itemsSection
                extrasSection
            }
            deliveryCard
        }
        .listStyle(.insetGrouped)
        .navigationTitle("状态栏")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A page-level reload, like PosterBoard's: the selection is owned by
            // the shell and was loaded there, but a preset imported from a file
            // while this page was on screen has to be picked up too.
            selection.loadFromDisk()
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            toggleRow("启用状态栏修改", isOn: $selection.enabled) {
                edited()
            }
            NativeNote(mechanism == .archive
                ? "这会写入 \(StatusBarMechanism.archive.restorePath)（位于 \(StatusBarMechanism.archive.domain)）。"
                : "这会写入 \(StatusBarMechanism.classic.restorePath)（位于 \(StatusBarMechanism.classic.domain)）。")
        }
    }

    /// The iOS 27 explanation, where the reference puts it: hidden everywhere
    /// else, and stated once rather than repeated on every row that disappears.
    private var archiveNote: some View {
        Section {
            NativeNote("iOS 27 更换了状态栏覆盖文件，因此这里只能修改运营商"
                + "条目：其名称、服务徽标和信号格数。"
                + "徽标和格数会应用到运营商名称上，所以请先设置一个。其他"
                + "选项需要 iOS 26 或更低版本。")
        }
    }

    // MARK: - Text

    /// The string overrides.
    ///
    /// `survivesArchive` is the reference's `survives_ios27` flag, passed on each
    /// row so the gating sits next to the control it gates instead of in a second
    /// list of names that could drift out of step with the rows.
    private var textSection: some View {
        Section("文本") {
            textFieldRow(.carrierName, "运营商名称", survivesArchive: true)
            textFieldRow(.serviceBadge, "服务徽标", survivesArchive: true)
            textFieldRow(.secondaryCarrierName, "副运营商名称", survivesArchive: true)
            textFieldRow(.secondaryServiceBadge, "副服务徽标", survivesArchive: true)
            textFieldRow(.timeText, "时间文本", survivesArchive: false)
            textFieldRow(.dateText, "日期文本", survivesArchive: false)
            textFieldRow(.breadcrumb, "返回链接文本", survivesArchive: false)
            textFieldRow(.batteryDetail, "电池详情文本", survivesArchive: false)
        }
    }

    // MARK: - Levels

    /// The numeric overrides, as steppers in the reference's own ranges.
    private var levelsSection: some View {
        Section("数值") {
            levelRow(.signalBars, "蜂窝信号格数", range: 0...5, survivesArchive: true)
            levelRow(.secondarySignalBars, "副蜂窝信号格数",
                     range: 0...5, survivesArchive: true)
            levelRow(.wifiBars, "Wi-Fi 信号格数", range: 0...5, survivesArchive: false)
            levelRow(.batteryCapacity, "电池图标电量",
                     range: 0...100, survivesArchive: false)
            levelRow(.dataNetworkType, "数据网络类型", range: 0...30, survivesArchive: false)
            levelRow(.secondaryDataNetworkType, "副数据网络类型",
                     range: 0...30, survivesArchive: false)
        }
    }

    // MARK: - Raw signal strength

    /// The two "show the number instead of the bars" toggles.
    ///
    /// Two rows because the reference has two: the flags are bits 0 and 1 of the
    /// same byte (`overrideDisplayRawGSMSignal` / `overrideDisplayRawWifiSignal`),
    /// and collapsing them into one switch would have meant dropping a control
    /// the reference shows.  Neither survives the archive.
    private var rawSection: some View {
        Section("原始信号强度") {
            toggleRow("显示蜂窝信号数值",
                      isOn: $selection.overrides.rawSignalShown) { edited() }
            toggleRow("显示 Wi-Fi 信号数值",
                      isOn: $selection.overrides.rawWifiSignalShown) { edited() }
        }
    }

    // MARK: - Items

    /// The item hide-toggles, in the reference's order and wording.
    ///
    /// On means **hidden**, which is why the labels are phrased as "Disable …":
    /// the reference's switch is `hidden`, not `shown`, and a page that offered
    /// "Show Wi-Fi icon" checked by default would read as the opposite of the
    /// control next to it.  Turning a switch off **removes** the override rather
    /// than forcing the item shown, because that is the only way back to stock
    /// visibility: `set_item_override(item, True)` and "no override" are
    /// different on the device, and the reference only ever offers the second.
    private var itemsSection: some View {
        Section("项目") {
            ForEach(Self.itemRows, id: \.0) { item, title in
                // `itemHidden` already saves, so this row passes no `onChange`:
                // two saves per flip would write the same bytes twice and make
                // the disk write look like it happens twice for every item.
                toggleRow(title, isOn: itemHidden(item)) {}
            }
        }
    }

    /// The reference's fourteen rows, in its order.
    ///
    /// A hand-written list rather than all 46 items: the reference exposes these
    /// fourteen, and the other 32 are slots the device reserves for states this
    /// app has no way to reach (TTY, student status, liquid detection on a device
    /// without it). Offering them would be offering 32 switches that can only
    /// ever write a value nothing reads.
    private static let itemRows: [(StatusBarItem, String)] = [
        (.quietMode, "隐藏专注模式图标"),
        (.airplaneMode, "隐藏飞行模式图标"),
        (.cellularService, "隐藏蜂窝服务图标"),
        (.cellularDataNetwork, "隐藏 Wi-Fi 图标"),
        (.mainBattery, "隐藏电池图标"),
        (.bluetooth, "隐藏蓝牙图标"),
        (.alarm, "隐藏闹钟图标"),
        (.location, "隐藏定位图标"),
        (.rotationLock, "隐藏旋转锁定图标"),
        (.airPlay, "隐藏 AirPlay 图标"),
        (.carPlay, "隐藏 CarPlay 图标"),
        (.vpn, "隐藏 VPN 图标"),
        (.voiceControl, "隐藏语音控制图标"),
        (.liquidDetection, "隐藏液体检测警告图标")
    ]

    private func isItemHidden(_ item: StatusBarItem) -> Bool {
        selection.overrides.itemShown[item] == false
    }

    /// A binding whose `set` gets a *Bool* rather than a dictionary subscript,
    /// because the two ways out of a hidden item are not the same value: off is
    /// `nil` (no override), not `true` (forced shown).
    private func itemHidden(_ item: StatusBarItem) -> Binding<Bool> {
        Binding(
            get: { isItemHidden(item) },
            set: { hidden in
                selection.overrides.itemShown[item] = hidden ? false : nil
                edited()
            })
    }

    // MARK: - Extras

    private var extrasSection: some View {
        Section("额外") {
            toggleRow("搞怪模式（启用所有项目）", isOn: $selection.sillyMode) { edited() }
            NativeNote("搞怪模式会强制启用所有状态栏项目，覆盖上方"
                + "的任何设置。关闭后会精确恢复你原来的状态。")
        }
    }

    // MARK: - Delivery

    /// What the apply will do, restated here.
    ///
    /// The count is the reference's `count_overrides`, and the switch is what
    /// decides whether anything is written at all — so the two facts are stated
    /// together.  An enabled page with nothing overridden is a **reset**: a
    /// zeroed struct, which is the only way to clear overrides already on the
    /// device.  A page that says "0 overrides" and leaves the user guessing
    /// whether that clears or does nothing is the case worth a line of text.
    private var deliveryCard: some View {
        Section {
            Text(selection.enabled ? "准备应用" : "未应用")
                .font(.headline)
            NativeNote(selection.enabled
                ? "\(selection.overrides.activeCount) 项覆盖 → "
                    + "\(mechanism == .archive ? "iOS 27 归档" : "传统结构体"), "
                    + "将在下次应用时写入。"
                : "在开启此项之前，应用时不会写入任何内容。")
        }
    }

    // MARK: - Rows

    /// A switch row: title on the left, control on the right, the reference's
    /// card metrics around them.
    private func toggleRow(_ title: String, isOn: Binding<Bool>,
                           onChange: @escaping () -> Void = {}) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { value in
                isOn.wrappedValue = value
                onChange()
            }))
    }

    /// A string override: the switch that says whether it is delivered, and the
    /// field that says what.
    ///
    /// The field is disabled while the override is off rather than cleared, so
    /// switching off and on again does not lose what was typed — the reference
    /// keeps the value on the setter for the same reason and only drops the flag.
    @ViewBuilder
    private func textFieldRow(_ key: StatusBarOverrides.FieldKey, _ title: String,
                              survivesArchive: Bool) -> some View {
        let field = selection.overrides.field(for: key)
        if mechanism == .archive && !survivesArchive {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                toggleRow(title, isOn: overrideSwitch(for: key)) { edited() }
                TextField("(留空即清除)", text: textBinding(for: key))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!field.set)
            }
        }
    }

    /// A numeric override: the reference's own `min_val`/`max_val` as the
    /// stepper's range, so the value cannot be set to something the field cannot
    /// hold.
    @ViewBuilder
    private func levelRow(_ key: StatusBarOverrides.FieldKey, _ title: String,
                          range: ClosedRange<Int>, survivesArchive: Bool) -> some View {
        let field = selection.overrides.field(for: key)
        if mechanism == .archive && !survivesArchive {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { selection.overrides.field(for: key).set },
                    set: { on in
                        var updated = selection.overrides.field(for: key)
                        updated.set = on
                        selection.overrides.set(updated, for: key)
                        edited()
                    })) {
                    HStack {
                        Text(title)
                        Spacer()
                        Text(field.set ? "\(field.value)" : "默认")
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: levelBinding(for: key), in: range) {
                    EmptyView()
                }
                .labelsHidden()
                .disabled(!field.set)
            }
        }
    }

    /// The override switch for one field: on means the value is delivered.
    ///
    /// Switching **on** keeps the value the field already holds, which is the
    /// reference's behaviour too (`setter(current)` on the way in): the row's
    /// number is a default the page always had on it, and turning the override on
    /// applies that default rather than a zero.
    private func overrideSwitch(for key: StatusBarOverrides.FieldKey) -> Binding<Bool> {
        Binding(
            get: { selection.overrides.field(for: key).set },
            set: { on in
                var field = selection.overrides.field(for: key)
                field.set = on
                selection.overrides.set(field, for: key)
            })
    }

    private func textBinding(for key: StatusBarOverrides.FieldKey) -> Binding<String> {
        Binding(
            get: { selection.overrides.field(for: key).text },
            set: { text in
                var field = selection.overrides.field(for: key)
                field.text = text
                selection.overrides.set(field, for: key)
                // Typing is a delivery intent: the field is enabled by the switch
                // above it, so a value can only be typed into an override that is
                // already on, and the text is written with the flag already set.
                edited()
            })
    }

    private func levelBinding(for key: StatusBarOverrides.FieldKey) -> Binding<Int> {
        Binding(
            get: { selection.overrides.field(for: key).value },
            set: { value in
                var field = selection.overrides.field(for: key)
                field.value = value
                selection.overrides.set(field, for: key)
                edited()
            })
    }
}
