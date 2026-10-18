import Foundation
import Minimuxer
import SwiftUI

/// An error whose message is meant for the operator, not for a stack trace.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The apply pipeline, ported from GoldenNugget's own apply pass
// (`device_manager._apply_tweak_pass`) onto this app's restore machinery.
//
// Flow:
//   1. Compile the selection to plists — before the device is touched, so an
//      impossible selection costs nothing.
//   2. Real protective backup via mobilebackup2 — triggers the iOS 27
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   3. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them), then inject
//      the compiled tweak plists as rows + payloads.
//   4. Restore via mobilebackup2.
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 2), `BackupInjector` (stage 3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()

    private init() {}

    // MARK: - Logging facade

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Run `body` under `label`, writing a failure into the log before it escapes.
    ///
    /// Every run entry point throws to a view that turns the error into a status
    /// line, and a status line lives exactly as long as the screen: the file sink
    /// is the only record a failed run leaves once the app is closed. It has to
    /// be written here rather than at the call sites because there are four of
    /// them and a fifth would silently skip it — which is how a posterboard apply
    /// came to end with its last line still on the *fetch* and nothing saying
    /// why.
    private func loggedRun<T>(_ label: String,
                              _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as TransportFailure where failure.isCancellation {
            log("\(label) 已停止：\(failure.label)")
            throw failure
        } catch {
            log("\(label) 失败：\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cancellation facade

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        // One line per call was wrong twice over: `.onAppear` fires on every
        // navigation back and `startMinimuxer` calls this again, so a session
        // that never got a tunnel printed the same "rust log → …" line a dozen
        // times — the loudest thing in a log whose real failure was one line
        // lower. The Rust side is process-wide state; the first answer is the
        // only one that describes it.
        if let cached = RustLog.initResult {
            return cached
        }

        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

        let meaning: String
        switch rc {
        case 0:   meaning = "已请求文件日志（DEBUG）"
        case -1:  meaning = "文件错误 —— Rust 拒绝了该路径"
        case -2:  meaning = "已初始化 —— 之前的 idevice_init_logger 调用已生效，Rust 日志会停留在 console(Error)，永远不会写入文件"
        case -3:  meaning = "无效的路径字符串"
        case -99: meaning = "没有可用的 ideviceGateway"
        default:  meaning = "未知"
        }
        log("Rust 日志 → \(path)：rc=\(rc)（\(meaning)）")

        // rc=0 only means the subscriber was installed; the file itself is
        // created by the first line the Rust side writes, so it is legitimately
        // absent here. What must be true NOW is that the directory exists —
        // a missing parent is the one case where the sink can never come up, and
        // it is invisible afterwards (status reads "size=MISSING" forever).
        if rc == 0 {
            let fm = FileManager.default
            let parent = URL.documents.path
            let parentExists = fm.fileExists(atPath: parent)
            log("Rust 日志目录：\(parent) exists=\(parentExists) "
                + "（文件会在写入第一行 Rust 日志时出现）")
            if !parentExists {
                log("⚠️ Rust 日志目录不存在 —— 本次会话不会写入任何 "
                    + "Rust 证据。此应用运行在 Documents "
                    + "路径不可写的位置。")
            }
        }
        return rc
    }

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Progress facade

    /// Whole-percent progress of the run in flight, or nil when nothing has
    /// reported yet.  The reference's home page prints the same number in its
    /// process-status line (`IOSApplyPage.set_status` parses `NN%` out of the
    /// status text), and a multi-minute restore with no number on it is the one
    /// screen the operator keeps re-reading to guess whether it is alive.
    private(set) var progress: Double?

    /// Route progress into the UI.  Called from the Rust progress callbacks, so
    /// the handler hops to the main actor itself.
    var onProgress: ((Double) -> Void)?

    /// Route the remaining-time estimate into the UI with the same story as
    /// `onProgress`: the feed happens on the Rust callback thread, the handler
    /// hops to the main actor.  Empty string until a stable rate is known — the
    /// desktop's status line shows nothing while `eta.py` is still quiet.
    var onEta: ((String) -> Void)?

    /// The last formatted remaining time (`""` before an estimate exists or
    /// while nothing is running).
    private(set) var etaText: String = ""

    /// The `eta.py` port.  Recreated per run so a new apply starts estimating
    /// from a clean slate even though the engine object is a singleton.
    private var etaEstimator = ProgressEta()

    private func reportProgress(_ percent: Double) {
        let clamped = percent < 0 ? 0 : min(percent, 100)
        progress = clamped
        onProgress?(clamped)
        let estimate = etaEstimator.update(clamped)
        etaText = estimate
        onEta?(estimate)
    }

    private func clearProgress() {
        progress = nil
        etaEstimator.reset()
        etaText = ""
        onProgress?(Double.nan)
        onEta?("")
    }

    // MARK: - Run: apply the ported GoldenNugget tweaks

    /// Apply everything this app can deliver: the compiled plist tweaks, the skip-setup
    /// files, and the PosterBoard selection — **one pass, one button**.
    ///
    /// This is GoldenNugget's `device_manager._apply_tweak_pass`, whose file list is
    /// built from every feature at once: its `needs_posterboard` flag decides whether the
    /// store's database has to be fetched first, and the wallpapers then ride the same
    /// restore as the tweaks.  There is no separate apply for wallpapers — this port had
    /// one for a while, a second button running the same four stages over a different
    /// payload set, and it is gone.  What is left of it is the flag.
    ///
    /// The compile runs *before* the device is touched, so an empty or impossible
    /// selection fails without paying for a backup first.  The PosterBoard database is
    /// the one input that has to come off the device; that stage therefore talks to it,
    /// but it is still ahead of the expensive protective pull and of the restore.
    func applyTweaks(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) async throws {
        // `_prepare_rollback_preset` (`main_window_mixins.py:1090`): keep the
        // last successful apply available as a one-click rollback *before* the
        // next apply overwrites it.  Best-effort, like the reference.
        GoldenNuggetPresets.prepareRollback()
        try await loggedRun("apply") {
            try await applyTweaksRun(selection: selection,
                                     posterBoard: posterBoard,
                                     statusBar: statusBar,
                                     deviceVersion: deviceVersion,
                                     isIPhone: isIPhone)
        }
        // `_save_last_applied_preset` (`main_window_mixins.py:1101`): a run
        // that returned is a successful apply — it becomes the rollback source
        // for the next one.  The model string is derived because the engine
        // does not carry a full identity; the snapshot is internal metadata.
        _ = GoldenNuggetPresets.saveLastApplied(selection: selection,
                                                deviceModel: isIPhone ? "iPhone" : "iPad",
                                                iosVersion: deviceVersion)
    }

    private func applyTweaksRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone)

        // The status bar is built here, on the version the page already read, and
        // for the same reason the plist compile is: a payload that cannot be built
        // has to fail before the device is touched.  The page resolves the
        // mechanism from this same number, so the two cannot disagree.
        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            // The count, then the parenthetical the reference's summary has: an
            // enabled-but-empty selection still writes a file, and the log has to
            // say so, or a reset reads as a no-op.
            log("状态栏：\(statusBar.overrides.activeCount) 个覆盖项"
                + "\(statusBar.overrides.activeCount == 0 ? "（未启用任何覆盖项）" : "")，通过"
                + "\(mechanism == .classic ? "经典结构" : "iOS 27 归档") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) 在 iOS 27 归档中没有对应项，未投递")
            }
        }

        // Upstream's skip-setup block rides the same apply, **ahead of** the
        // tweaks (`device_manager.add_skip_setup`).  Its warnings are logged
        // below: the parts this port cannot reproduce must not read like parity.
        //
        // Always the un-supervised variant.  The `supervised` / `organizationName`
        // arguments used to come off the Supervision page, and the page is gone —
        // it recorded `IsSupervised` without ever writing the
        // `SupervisorHostCertificates` that make the flag mean anything, so a
        // device this app "supervised" sat in a state the reference never
        // produces on purpose.  `SkipSetup` still carries the supervised shape
        // because `scripts/skipsetup-check.swift` checks both, but nothing in the
        // app selects it any more.
        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        guard !compiled.payloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive else {
            throw GoldenNuggetError("没有可应用的内容：未启用任何调整项（或所有已启用的调整项"
                + "均被跳过）、跳过设置已关闭、状态栏未改动，且"
                + "海报板页面未选择任何内容。")
        }
        log("调整项：\(compiled.payloads.count) 个文件，来自 \(compiled.locations.count) 个 plist")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ 已跳过 \(item.label)：\(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("跳过设置：\(skipSetup.payloads.count) 个文件，位于调整项之前")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        // The apply mode picks the mechanism, and it is the user's choice: the
        // backup path below and the AirLift path install the same wallpapers two
        // different ways, and neither can stand in for the other. The mode's
        // constraints are checked *here*, before `prepareRun`, so a selection the
        // chosen mode cannot honour fails without paying for a tunnel first.
        let posterBoardMode = PosterBoardApplyModeSettings.current
        if posterBoard.isActive && posterBoardMode == .airlift {
            try checkAirliftCanApply(posterBoard: posterBoard, deviceVersion: deviceVersion)
        }

        let udid = try await prepareRun()
        // Resolved once, here, because two stages need it: the PosterBoard compile (its
        // reset preferences change at 26.4) and the manifest-format fork inside
        // `deliver`.  `resolvedDeviceVersion` carries the reasoning for refusing to
        // guess — a device whose version cannot be read must not be treated as iOS 26.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("清单格式分支所用设备版本：\(version)（主版本 \(major)）")

        // PosterBoard, if the page has anything. Two mechanisms, chosen above:
        // the store's database first — a wallpaper exists only once it has a row in
        // it — and then the wallpapers themselves, unless AirLift is doing it, in
        // which case there is no database and no payload: the injection into the
        // container *is* the apply.
        var posterBoardPayloads: [TweakPayload] = []
        var posterBoardInjectedOverAirlift = false
        if posterBoard.isActive && posterBoardMode == .airlift {
            log("海报板：\(posterBoard.describe) —— 通过 AirLift，不走备份")
            try await applyPosterBoardOverAirlift(selection: posterBoard, deviceVersion: version)
            posterBoardInjectedOverAirlift = true
        } else if posterBoard.isActive {
            log("海报板：\(posterBoard.describe)")
            var structureVersion = PosterBoard.fallbackStructureVersion
            var database: URL?
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                // A reset needs no database, so it needs no fetch and no exchange.
                log("海报板：仅重置 —— 不需要数据库，也不会抓取。")
            } else {
                let fetched = try await PosterBoardBackup.fetch(
                    backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                    // The same fork `deliver` is about to take, from the same number.
                    ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                    onProgress: { overall in
                        self.logProgress("海报板备份进度", overall)
                    },
                    log: { AppLog.write($0) })
                database = fetched.database
                structureVersion = fetched.structureVersion
            }
            posterBoardPayloads = try await PosterBoard.compile(
                selection: posterBoard,
                structureVersion: structureVersion,
                database: database,
                deviceVersion: version,
                workingDirectory: PosterBoard.workDirectory,
                log: { AppLog.write($0) })
            let onDisk = posterBoardPayloads.filter { $0.source != nil }.count
            let total = posterBoardPayloads.reduce(0) { $0 + $1.byteCount }
            log("海报板：\(posterBoardPayloads.count) 个载荷，其中 \(onDisk) 个来自磁盘"
                + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        }

        // Skip setup, then the tweaks, then the status bar, then the wallpapers: one
        // array, one pass through the injector, which derives the directory rows from
        // each payload's path.  The order is the reference's — `add_skip_setup`
        // ahead of the tweaks, and `apply_classic_tweak` / `apply_ios27_tweak`
        // before the wallpapers — and it only actually matters for the two
        // skip-setup files, which land in the order they are appended.
        let payloads = skipSetup.payloads + compiled.payloads + statusBarPayloads
            + posterBoardPayloads

        // Wallpapers-only run in AirLift mode: the injection already happened and
        // it resprings on its way out, so running the backup/restore tail here
        // would buy a full protective pull for an empty payload list.
        if payloads.isEmpty && posterBoardInjectedOverAirlift {
            log("应用成功：墙纸已写入海报板的容器，并且"
                + "已重新载入界面 —— 未执行备份。")
            return
        }

        try await deliver(payloads: payloads, udid: udid, version: version, label: "apply") {
            log("应用成功：设备已确认完成。")
            log("请重启设备，使注入的偏好设置生效。")
            if posterBoardInjectedOverAirlift {
                log("墙纸已通过 AirLift 写入并已生效；只有上面的调整项"
                    + "需要重启。")
            } else if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                log("海报板存储已清空。请重启设备，然后从全新的数据库抓取中添加墙纸 —— "
                    + "因为重置会让重置之前抓取的副本"
                    + "失效。")
            } else if posterBoard.isActive {
                log("请重启设备，让海报板存储识别到新墙纸。")
            }
        }
    }

    /// Refuse a selection the AirLift path cannot carry, before anything is opened.
    ///
    /// A reset is a store operation and the video stage's frames are computed for
    /// the restore, so neither can travel a container write. Saying so up front is
    /// the alternative to accepting the selection and quietly dropping half of it.
    private func checkAirliftCanApply(posterBoard: PosterBoardSelection, deviceVersion: String) throws {
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("AirLift 无法重置海报板存储 —— 它只能添加"
                + "墙纸。要重置，请将应用模式切换为 \"保护性备份\"。")
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("AirLift 无法应用海报板视频：其帧需要"
                + "为恢复流程暂存。请将应用模式切换为 \"保护性备份\"。")
        }
        let reason = Airlift.unsupportedReason(deviceVersion: deviceVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("AirLift 需要配对记录，但当前未存储。请先在主页"
                + "导入一个。")
        }
    }

    /// Run the AirLift PosterBoard injection, reporting through the run log.
    private func applyPosterBoardOverAirlift(selection: PosterBoardSelection,
                                             deviceVersion: String) async throws {
        try await PosterBoardAirlift.apply(
            selection: selection,
            structureVersion: PosterBoard.fallbackStructureVersion,
            deviceVersion: deviceVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("海报板 AirLift", overall) }
        )
    }

    /// Fetch only the device's PosterBoard database, without applying anything.
    ///
    /// The page's own action, and the reference has the same one (its "Fetch
    /// Database File" wizard in `pb_dialog.py`) for the same reason: the fetch is
    /// the one stage of a wallpaper apply that can fail on its own terms — the
    /// device decides whether it will upload the container — so being able to run
    /// it alone, watch it, and retry is worth a button. The result is cached at
    /// `PosterBoardBackup.cachedDatabase(udid:)`, and an apply reuses nothing:
    /// it fetches its own, because a copy fetched before a reset is stale.
    func fetchPosterBoardDatabase() async throws {
        try await loggedRun("posterboard database fetch") {
            try await fetchPosterBoardDatabaseRun()
        }
    }

    private func fetchPosterBoardDatabaseRun() async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard database fetch")
        defer { stage.done() }

        let udid = try await prepareRun()
        _ = try await PosterBoardBackup.fetch(
            backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
            onProgress: { overall in self.logProgress("海报板备份进度", overall) },
            log: { AppLog.write($0) })
        log("海报板数据库已抓取并通过校验。")
    }

    /// Inject the PosterBoard packs over AirLift, and nothing else.
    ///
    /// The home page's Apply is one combined run — tweaks and wallpapers ride
    /// together through a single protective backup — which is right for a
    /// backup-mode selection and wrong for this one: AirLift writes the
    /// descriptors straight into the container, so a run that carries nothing
    /// but wallpapers should not buy a backup at all. That early return lives
    /// in the combined path and is reached only when no tweak is selected, so
    /// this is the same injection on its own, with no payloads to deliver and
    /// no mode switch to remember.
    ///
    /// - Parameters:
    ///   - selection: the page's selection. Only its packs are honoured, exactly
    ///     as in the combined run.
    ///   - deviceVersion: what the page already read; the constraints are checked
    ///     against it rather than resolved again over a second connection.
    func applyPosterBoardViaAirlift(_ selection: PosterBoardSelection,
                                    deviceVersion: String) async throws {
        try await loggedRun("posterboard airlift apply") {
            try await applyPosterBoardViaAirliftRun(selection, deviceVersion: deviceVersion)
        }
    }

    private func applyPosterBoardViaAirliftRun(_ selection: PosterBoardSelection,
                                               deviceVersion: String) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard airlift apply")
        defer { stage.done() }

        try checkAirliftCanApply(posterBoard: selection, deviceVersion: deviceVersion)
        log("海报板：\(selection.describe) —— 通过 AirLift，不走备份")
        try await applyPosterBoardOverAirlift(selection: selection, deviceVersion: deviceVersion)
        log("海报板：已通过 AirLift 注入并重新载入界面。未执行备份，也没有"
            + "投递任何调整项 —— 调整项由主页的“应用”负责投递。")
    }

    // MARK: - The shared delivery tail
    //
    // Both applies end in the same four stages, and the order is load-bearing:
    // the manifest-format fork decides whether there is anything to prune, the
    // pull is what authorizes the session, the prune must precede the injection,
    // and the restore is what delivers any of it.

    /// One payload set through stages 1–4.  `udid` and `version` come from the caller:
    /// the PosterBoard stage talks to the device (and needs the version) before this
    /// runs, so resolving them again here would be a second answer to a settled question.
    private func deliver(
        payloads: [TweakPayload],
        udid: String,
        version: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // The two versions take opposite paths, and the split is the
        // reference's one-line fork (`backup.py:113`) widened to the whole run:
        // iOS 26 speaks legacy MBDB and can have a backup built for it from
        // nothing, iOS 27+ speaks the modern sqlite Manifest.db and must keep
        // the device's own state. Comparing "26.0" against "27.0" lexically
        // would put 26.9 on the wrong side, so compare the major component.
        //
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        // Development mode can force the iOS 26 branch, so the reported version is no
        // longer the last word on which branch runs -- only the default for it. Read
        // once, here, and both decisions below quote the same snapshot.
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore
        // Reported before the fork, because this number *is* the fork: the
        // branch lines below say where the run went, this says why.
        log("清单格式分支所用设备版本：\(version)（主版本 \(major)）")
        if dev.forcePartialRestore {
            log("开发模式：在 iOS 主版本 \(major) 的设备上强制使用 iOS 26 分支 "
                + "—— 不会拉取保护性备份")
        }

        // iOS 26: a Partial Restore, built rather than pulled -- an empty device
        // directory, the host-side manifests, then this run's rows. Nothing was
        // pulled, so there is no device state to reconcile against and the
        // prune would only discard what this run just wrote.
        //
        // iOS 27: the protective backup, pulled from the device, then pruned to
        // what is on disk before injection. A synthesized manifest is not enough
        // here: `restored` rejects a domain it cannot resolve ("Failed to
        // prepare INSERT for ManagedPreferencesDomain") because the real one
        // carries the device's own domain registration.
        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("清单格式：sqlite（iOS 27+ 路径），已拉取保护性备份")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
            // Media over AFC, after the backup and before the prune: the backup
            // filter rejects the media domains, so this is the only thing that
            // collects them, and doing it here means an apply is the one action
            // that leaves media preserved rather than only tweaks applied.
            //
            // Deletion stays off. A run is not the place to remove the user's
            // photos: it is started to apply tweaks, and the media page is where
            // that choice is made with a count and a free-space figure in front
            // of the user.
            if dev.skipAfcMedia {
                log("开发模式：跳过 AFC 媒体拉取（Dev.SkipAfcMedia）")
            } else {
                clearProgress()
                log("AFC 媒体：正在收集媒体文件…")
                await mediaBackup(deletingOriginals: false)
            }
        } else {
            log("清单格式：传统 MBDB（iOS 26 路径），从零构建")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        clearProgress()
        log("正在清理并注入调整项…")
        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: label,
                             onSuccess: onSuccess)
    }

    /// Put the named pages back to stock, on the device.
    ///
    /// A port of `device_manager.reset_tweaks` (`device_manager.py:1104`): a
    /// fixed set of files written over the device's own, with nothing read back
    /// first — no psysbackup capture, on either branch. The page set comes from
    /// the picker the reference's `ResetDialog` offers, not from this app's
    /// tweak selection; the two are unrelated, and the reference's dialog is
    /// likewise built from `get_resettable_pages`, not from what is enabled.
    ///
    /// It is the same pipeline as `applyTweaks` with a different payload list, so
    /// it reuses `protectiveBackup` / `partialRestore` / `pruneAndInject` /
    /// `runRestore` rather than growing a second restore path. The two branches
    /// differ in what a nulled file is written as (0 bytes vs. a valid empty
    /// plist — `TweakReset` has the table and the reason) and in which manifest
    /// the run needs, for the same reason the apply forks:
    ///
    /// * **iOS 27+** speaks the modern sqlite `Manifest.db` and rejects a
    ///   synthesized one ("Failed to prepare INSERT for ManagedPreferencesDomain"
    ///   — the real one carries the device's own domain registration), so the
    ///   reset pulls the protective backup and prunes it, exactly as an apply
    ///   does. It does **not** pull media: a reset is a preferences operation and
    ///   the backup filter rejects the media domains anyway.
    /// * **iOS 26** speaks legacy MBDB and can have a backup built for it from
    ///   nothing, so the reset synthesises one.
    ///
    /// What is deliberately absent is the reference's `clear_lastapply`: it drops
    /// the apply record so a later apply does not skip Phase 2 against a reset
    /// device, and there is no phase-2 skip in this port to guard. The app's own
    /// selection is left alone too, exactly as the reference leaves the tweaks
    /// page as the user had it — the reset is of the *device*, and the selection
    /// is what would put the tweaks back.
    func resetPages(pages: Set<ResetPage>) async throws {
        try await loggedRun("page reset") { try await resetPagesRun(pages: pages) }
    }

    private func resetPagesRun(pages: Set<ResetPage>) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN page reset")
        defer { runStage.done() }

        guard !pages.isEmpty else {
            throw GoldenNuggetError("未选择任何页面 —— 无需重置。")
        }

        let udid = try await prepareRun()

        // Read the version here for the same reason the apply does: the pages
        // read it before lockdown answers, so a value of "" would put a 27
        // device on the 26 branch and hand it 0-byte plists.
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        let plan = TweakReset.plan(pages: pages, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("所选页面均未解析出文件 —— 无需重置。")
        }

        // The reference appends the skip-setup files to the *reset's* file list
        // too (`add_skip_setup(files_to_restore, uses_domains)`, called after the
        // null loop and before `start_restore`), subject to its own gate — which
        // on iOS 27 only passes when the file list already restores real domains,
        // and in the reset path that means the Daemons page was ticked. Reproduced
        // as written; see `TweakReset.skipSetupAllowed(pages:ios27:)`.
        let skipSetupOn = SkipSetupSettings.shared.skipSetupEnabled
        let skipSetup: SkipSetup.Build
        if !skipSetupOn {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
        } else if plan.skipSetupAllowed {
            skipSetup = SkipSetup.build(supervised: false, organizationName: "")
        } else {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
            log("“跳过设置”已开启，但参考实现在此省略了它的两个文件：在 iOS 27 上，"
                + "除非勾选 Daemons 页面，重置不会恢复真实域，"
                + "而这正是其 `add_skip_setup` 条件。请勾选 Daemons，或在 iOS 26 上"
                + "重置，才能包含这两个文件。")
        }

        log("重置：\(pages.count) 个页面 —— \(plan.targets.count) 个文件（iOS \(version)）")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) 字节]")
        }
        for item in plan.skipped { log("  ⚠️ 已跳过 \(item.label)：\(item.reason)") }
        for page in ResetPage.allCases where pages.contains(page) {
            log("  页面 \(page.title)：\(page.locations.count) 个文件")
        }
        if ios27 {
            log("iOS 27 分支：被置空的文件会写为合法的空 plist，而不是 0 字节 —— "
                + "在此版本上，截断的 plist 会导致 SpringBoard 无限重启。不会先从设备"
                + "读回任何内容：这是参考实现自身的无捕获回退，"
                + "并非用 psysbackup 恢复原始值。")
        } else {
            log("iOS 26 分支：被置空的文件会写为 0 字节，基于合成的 MBDB "
                + "备份（未拉取设备内容）。")
        }

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("清单格式：sqlite（iOS 27+ 路径），已拉取保护性备份，随后清理")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
        } else {
            log("清单格式：传统 MBDB（iOS 26 路径），从零构建")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            // Same order as the reference's file list: the daemons file first, then
            // the nulled ones, then the two skip-setup files last — the reference
            // calls `add_skip_setup` after the null loop.
            tweakPayloads: plan.payloads + skipSetup.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "page reset") {
            log("重置成功：设备已确认完成。")
            log("以上页面已恢复默认值。此应用中的选择"
                + "未受影响 —— 再次应用会把调整项写回去。")
            log("请重启设备，使恢复的文件生效。")
        }
    }

    /// The AFC media stage, as a stage rather than a separate button so the run
    /// log tells the whole story in one place.
    private func mediaBackup(deletingOriginals: Bool) async {
        do {
            let survey = try await AfcMediaBackup.survey()
            guard !survey.files.isEmpty else {
                log("AFC 媒体：以下位置没有内容 \(AfcMediaBackup.trees.joined(separator: "/")) "
                    + "—— 已跳过")
                return
            }
            log("AFC 媒体：正在拉取 \(survey.files.count) 个文件，共 \(survey.bytes) 字节")
            let manifest = try await AfcMediaBackup.pull(deletingOriginals: deletingOriginals) {
                self.log($0)
            }
            let removed = manifest.entries.filter(\.deleted).count
            log("AFC 媒体：已存储 \(manifest.entries.count) 个文件，从设备移除了 \(removed) 个"
                + "文件。")
        } catch {
            // Not fatal to the tweak apply. The store is a copy, not a
            // precondition for writing preferences, and a media failure must not
            // cost the user the tweak run they started.
            log("AFC 媒体：失败 —— \(error.localizedDescription)")
        }
        clearProgress()
    }

    // MARK: - Protective flow stages
    //
    // The full flow, kept in one place because the order is load-bearing.

    /// Stage 1: the working backup, into `<Documents>/<udid>/`.
    ///
    /// A Partial Restore, so it is built rather than pulled: an empty device
    /// directory, then the host-side manifests, then this run's rows and
    /// payloads. There is no user content to preserve and nothing to wipe, which
    /// is why the reference's three-phase flow (and its safe-state recovery) has
    /// no part here on iOS 26 -- the restore lands on the live device.
    private func partialRestore(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        log("部分恢复：正在 \(backupRoot.lastPathComponent) 处合成备份 "
            + "（未拉取设备内容）")
        return backupRoot
    }

    /// A real protective backup into `<Documents>/<udid>/`.
    private func protectiveBackup(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            self.logProgress("备份进度", overall)
        }
        log("保护性备份完成。")
        clearProgress()
        return backupRoot
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// A run must not start on top of one that was cancelled but is still
    /// running, and this makes that state visible.
    ///
    /// A blocking FFI call cannot be interrupted, so Stop only walks away from
    /// it — and `clearCancel()` at the top of a run clears the very flag that
    /// was going to make the abandoned call unwind. A second mobilebackup2
    /// exchange started in that window is two sessions on one RSD adapter, which
    /// is the hazard `InFlightCall` exists to record.
    ///
    /// This WARNS rather than blocks, deliberately. Blocking is the safer
    /// default, but an abandoned call may never drain at all, which would turn
    /// "press Stop" into "press Stop, then force-quit the app" — a worse failure
    /// than the one it prevents. The state is logged instead, so it is never
    /// invisible; adding a drain wait here is the trade to revisit if that
    /// ever looks wrong.
    ///
    /// Must run BEFORE `clearCancel()`: clearing first erases the signal the
    /// previous run is still waiting on.
    private func warnIfPreviousCallStillRunning() {
        guard InFlightCall.shared.isBusy else { return }
        log("⚠️ 上一个设备调用仍在运行 "
            + "（\(InFlightCall.shared.abandonedDescription)）—— 将在此基础上启动新的运行。"
            + "如果该调用已被取消，它可能仍持有会话；因此从这里出现的失败，"
            + "看似设备问题，实际上可能是两个会话共用同一个 RSD 适配器：请强制退出"
            + "应用，然后重新运行。")
    }

    /// Everything a run does before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root).  Throws
    /// `GoldenNuggetError` for the operator-facing failures.
    private func prepareRun() async throws -> String {
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer 尚未就绪。请确保 WiFi 和可用隧道（LocalDevVPN 或 WireGuard + em_proxy），然后选择配对文件。")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("无法获取设备 UDID")
        }
        log("设备 UDID：\(udid)")
        log("隧道：\(Tunnel.describe())")
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        return udid
    }

    /// The version the manifest-format fork branches on — never a guess.
    ///
    /// An empty `fallback` means "the page never managed to read it" (it reads
    /// once, when it appears, and lockdown may not have been answering yet), and
    /// **not** "iOS 26". Parsing it as 0 used to send a 27.0 device down the
    /// legacy branch, which cannot work there: that branch synthesises a backup
    /// from nothing, and what the device answers is
    /// `MBErrorDomain/205 — No keybag in manifest` (2026-09-26).
    ///
    /// So re-read lockdown — `prepareRun()` has just shown it is ready — and
    /// refuse to continue if even that fails. Refusing beats defaulting: the two
    /// branches want different manifest formats, and a wrong pick costs the
    /// operator a whole run plus a puzzle like this one.
    private func resolvedDeviceVersion(_ fallback: String) async throws -> String {
        if !fallback.isEmpty { return fallback }
        log("设备版本：调用方未提供（它在 lockdown 应答前读取了身份） "
            + "—— 在格式分支前重新读取")
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else {
            throw GoldenNuggetError(
                "无法读取设备的 iOS 版本（lockdown ProductVersion），而本次运行"
                + "需要它来选择清单格式：iOS 27+ 会从设备拉取保护性备份，并使用 "
                + "sqlite Manifest.db；iOS 26 则在主机上合成传统 MBDB 备份。"
                + "请解锁设备、确认隧道已建立，然后重新运行。")
        }
        log("设备版本：lockdown 应答为 \(identity.version)")
        return identity.version
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        clearProgress()
        log("正在恢复备份…（这一步会在设备上完成收尾）")
        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("恢复返回了 \(code)，但未确认完成 —— 请检查上方的日志。")
        }
    }

    // MARK: - Readiness

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }
}
