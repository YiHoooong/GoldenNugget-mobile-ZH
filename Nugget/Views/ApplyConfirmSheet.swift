import SwiftUI
import UIKit

/// The pre-apply confirmation the desktop shows before a device is touched:
/// the summary, the storage and battery warnings, the conflict list and the
/// file preview, with the reference's "Apply" / "Cancel" pair.
///
/// The reference builds this in `main_window_mixins.py` (`_build_summary` and
/// its `_storage_warning_line` / `_battery_warning_line` / `_storage_estimate_line`
/// / `_time_estimate_line` helpers) and reaches the file list through
/// `details_callback=self._show_apply_preview`; the details are inlined here
/// because the sheet is small enough to hold them without a second screen.
struct ApplyConfirmSheet: View {
    let preview: ApplyPreview
    let onApply: () -> Void
    let onCancel: () -> Void

    /// The desktop's battery warning (`main_window_mixins.py:921`): warn below
    /// 21% unless the device is charging.  Read here rather than passed in,
    /// because the battery state is a value only this sheet's moment matters for.
    private var batteryLine: String? {
        Self.batteryWarningLine()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("摘要") {
                    LabeledContent("已选调整项", value: "\(preview.selectedCount)")
                    LabeledContent("待写入文件", value: "\(preview.rows.count)")
                    LabeledContent("总大小", value: Self.size(preview.totalBytes))
                    LabeledContent("预计时间",
                                   value: ApplyPreview.timeEstimate(total: preview.selectedCount))
                }

                if let line = ApplyPreview.estimatedWorkingSpaceLine() {
                    Section("工作空间") {
                        NativeNote(line)
                    }
                }

                // Warnings are gathered so the section is absent when there is
                // nothing to warn about — the reference prints these lines only
                // when each is non-nil.
                let warnings = [ApplyPreview.storageWarningLine(), batteryLine].compactMap { $0 }
                if !warnings.isEmpty {
                    Section("警告") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            NativeSafetyNote(warning)
                        }
                    }
                }

                if !preview.conflicts.isEmpty {
                    Section("冲突") {
                        ForEach(preview.conflicts) { conflict in
                            Label(conflict.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        NativeSafetyNote("这些设置相互矛盾。后写入的"
                            + "调整项会在设备上生效，因此结果可能"
                            + "与列表所示不符。")
                    }
                }

                if !preview.notes.isEmpty {
                    Section("备注") {
                        ForEach(Array(preview.notes.enumerated()), id: \.offset) { _, note in
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !preview.rows.isEmpty {
                    Section("文件") {
                        ForEach(preview.rows) { row in
                            HStack {
                                Text(row.label)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(Self.size(row.byteCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { onApply() }
                        .font(.headline)
                }
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `_battery_warning_line`: `percent > 20` or charging means no warning;
    /// an unknown level (`batteryLevel < 0`) means none either.
    private static func batteryWarningLine() -> String? {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        let charging = device.batteryState == .charging || device.batteryState == .full
        let percent = Int((level * 100).rounded())
        if charging || percent > 20 { return nil }
        return "⚠ 电量不足：\(percent)%。请先连接充电器再恢复。"
    }
}
