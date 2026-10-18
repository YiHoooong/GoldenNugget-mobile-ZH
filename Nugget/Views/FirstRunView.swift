import SwiftUI
import UIKit

/// The one-time setup guide: put a loopback VPN tunnel up, put a pairing record
/// in place, then let the user in.
///
/// Two prerequisites, in this order, because they are a chain. The app reaches the
/// device through a loopback tunnel (`Tunnel`), so with no tunnel there is
/// nothing for a pairing record to connect over — and with no pairing record
/// there is no device to reach, which is why the home page's `startMinimuxer()`
/// waits for the tunnel before it hands anything to minimuxer. Guiding the steps
/// in the order they unblock each other is the difference between a guide and a
/// list.
///
/// **Every check is one the app can actually make**, and neither step guesses:
///
///   * the VPN step is judged by the interface and the peer probe `Tunnel` itself
///     probes with — a real tunnel carrying a real lockdown port, not a guess
///     made from a bundle ID the app cannot read;
///   * the pairing step is judged by a record at `AppPaths.pairingFile` that
///     passes the same `PairingRecord` rule the restore path applies.
///
/// There is no "install" button, and that is deliberate rather than unfinished.
/// The app has no installer to call: `installation_proxy` lives in the vendored
/// `IdeviceGateway` and is not bridged into this target, and the profile route
/// this app would otherwise use is not available either — `SkipSetup` documents
/// the same wall for `MobileConfigService`. A button that promises to install an
/// app it cannot install is worse than an honest set of instructions, so the step
/// says what to install and what to type into it.
struct FirstRunView: View {
    /// Present when the guide is a page pushed from Settings rather than the
    /// app's own gate. Only then is there a way out that is not "finish", and
    /// only then does the finish button have somewhere to return to.
    var onClose: (() -> Void)?

    @ObservedObject private var firstRun = FirstRunSettings.shared
    /// Shared because the advertisement outlives this page: the user leaves for
    /// Settings → Developer Mode to confirm it, and a `NavigationSplitView`
    /// replaces the detail on every selection.
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The tunnel step. A live probe rather than a stored answer — see `probe()`.
    @State private var tunnel: TunnelStep = .unchecked
    /// Whether a usable pairing record is in place.
    @State private var pairingReady = PairingRecord.onDisk() != nil
    @State private var showPairingImporter = false
    @State private var errorText: String?

    /// The tunnel step, as the app can actually observe it.
    ///
    /// `.peerUnreachable` is deliberately **not** a failure state: the interface
    /// is up, so the VPN is on and something else — LocalDevVPN's own service —
    /// has yet to answer on the peer port. `Tunnel.waitForTunnel` waits for
    /// exactly this, and reporting it as an error would tell a user whose tunnel
    /// is working that it is not.
    private enum TunnelStep: Equatable {
        /// Not probed yet, or the last probe was interrupted.
        case unchecked
        /// No interface carries the tunnel IP: the VPN app is not connected.
        case interfaceMissing
        /// Interface up, peer port not answering yet.
        case peerUnreachable
        /// The tunnel is carrying lockdown traffic — `startMinimuxer` will go on.
        case ready

        var text: String {
            switch self {
            case .unchecked: return "尚未检查"
            case .interfaceMissing: return "无隧道——\(Tunnel.ifaceIP) 不在任何网络接口上"
            case .peerUnreachable: return "隧道接口已启用，正在等待 \(Tunnel.peerIP):\(Tunnel.servicePort)"
            case .ready: return "隧道已启用——\(Tunnel.peerIP):\(Tunnel.servicePort) 已响应"
            }
        }

        var isReady: Bool { self == .ready }
    }

    var body: some View {
        List {
            introSection
            tunnelSection
            pairingSection
            finishSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("初始设置")
        .navigationBarTitleDisplayMode(.inline)
        // No `goldenSidebarButton()`: there is no sidebar behind this page in
        // either state. As the gate this is the root; as a Settings page it is
        // pushed onto the detail stack, where the bar already carries "back".
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { onClose() }
                }
            }
        }
        .task {
            pairingReady = PairingRecord.onDisk() != nil
            await probe()
        }
        // Coming back from Settings is when a tunnel that was just switched on
        // becomes visible, and nothing in this process is told when an interface
        // appears — so the re-check is on foreground, not only on appear.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await probe()
        }
        // Re-probe until it is ready: the user's half of this step happens in
        // another app, so this screen would otherwise sit on "no tunnel" for as
        // long as they took. The `id` stops the loop the moment it succeeds, so a
        // working setup costs no more probes.
        .task(id: tunnel.isReady) {
            while !tunnel.isReady, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await probe()
            }
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingRecord.types) { result in
            switch result {
            case .success(let url):
                importRecord(from: url)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        // A pairing file arriving as a link (AirDrop, Files "Open in"), which is
        // how it usually reaches a phone.
        .onOpenURL { url in
            guard PairingRecord.hasKnownExtension(url.pathExtension) else { return }
            importRecord(from: url)
        }
        // The wireless pairing wrote a record of its own; adopt it through the
        // same contract an import goes through.
        .onChange(of: wirelessPair.generatedRecordPath) { _, path in
            adoptGeneratedRecord(at: path)
        }
        .alert("设置", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") {}
        } message: {
            Text(errorText ?? "?")
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            HStack(spacing: 16) {
                NativeLogo(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置 GoldenNugget")
                        .font(.title3.bold())
                    Text("在应用连接此设备之前，还需要完成两件事。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            NativeNote("如果隧道是在应用启动之后才连接的，"
                + "请关闭并重新打开 GoldenNugget 一次——它会在启动时决定是否启动自己的"
                + "模拟隧道，而这个决定只会做一次。")
        }
    }

    /// Step 1: the tunnel, with the values to type into LocalDevVPN.
    ///
    /// The configuration line is the same `Tunnel.requirements` string the home
    /// page's diagnostics and its tunnel-failure alert print, so the guide and
    /// the diagnostics cannot disagree about what a working tunnel looks like —
    /// including when the user has overridden the addressing.
    private var tunnelSection: some View {
        Section("1 · LocalDevVPN 隧道") {
            stepStatus(done: tunnel.isReady, text: tunnel.text)
            Text(Tunnel.requirements)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = Tunnel.requirements
            } label: {
                Label("复制这些数值", systemImage: "doc.on.doc")
            }
            Button {
                Task { await probe() }
            } label: {
                Label("再次检查", systemImage: "arrow.clockwise")
            }
            NativeNote("在这台 iPhone 上安装 LocalDevVPN（或任何等效的隧道应用），"
                + "然后开启它并输入上方这些数值：隧道 IP 是本设备"
                + "在隧道中的地址，对端则是另一头。"
                + "请保持隧道开启——GoldenNugget 的每次连接都需要它，而"
                + "本应用无法自行安装 VPN 应用或配置描述文件。")
            if tunnel == .interfaceMissing {
                NativeNote("没有网络接口承载 \(Tunnel.ifaceIP)。最常见的原因是"
                    + "VPN 应用连接到了错误的网络，或者其隧道"
                    + "IP 仍处于应用自身的默认值。")
            }
            if Tunnel.isCustomised {
                NativeSafetyNote("正在使用自定义隧道数值（见主页上的"
                    + "隧道设置）。这些数值必须与 LocalDevVPN 中的一致。")
            }
        }
    }

    /// Step 2: a pairing record, from the PC or from the phone itself.
    private var pairingSection: some View {
        Section("2 · 配对") {
            stepStatus(done: pairingReady,
                       text: pairingReady
                        ? "配对记录已就位"
                        : "还没有配对记录")
            if wirelessPair.isRunning {
                wirelessPairProgress
            } else {
                Button {
                    showPairingImporter = true
                } label: {
                    Label("导入配对文件", systemImage: "doc.badge.plus")
                }
                Button {
                    wirelessPair.start()
                } label: {
                    Label("无需电脑配对", systemImage: "wifi")
                }
            }
            NativeNote("要用电脑配对：通过 USB 连接这台 iPhone，出现提示时点按“信任”，"
                + "然后在电脑上对它运行配对工具——例如"
                + "libimobiledevice 中的 idevicepair，或 Sideloadly。该工具会写入一个"
                + ".mobiledevicepairing 文件；把这个文件发送到这部手机（AirDrop，或保存到"
                + "iCloud 云盘中），然后在上方导入它。")
            NativeNote("或者不用电脑配对：iOS 27 允许手机与自身配对，"
                + "这正是第二个按钮的作用。那份记录属于本应用——"
                + "电脑仍然需要自己的记录，用第一种方式导入。")
        }
    }

    private var finishSection: some View {
        Section {
            NativeNote(canFinish
                ? "两项都已就绪。完成后将连接到设备并打开主页；"
                    + "这里使用的记录就是它读取的那份。"
                : "隧道和配对记录都是必需的。在两者都就绪之前，“完成设置”"
                    + "会一直保持灰色不可用——无法连接的主页正是"
                    + "本指南要避免的状态。")
            NativePrimaryButton(title: "完成设置", systemImage: "checkmark", disabled: !canFinish) {
                firstRun.complete(reason: "tunnel and pairing record both ready")
                onClose?()
            }
            Button("暂时跳过设置") {
                firstRun.complete(reason: "skipped by the user")
                onClose?()
            }
            .foregroundStyle(.secondary)
            NativeNote("跳过并不会无法回头：之后仍可在“设置”中找到本指南。")
        }
    }

    // MARK: - Pieces

    /// One step's verdict: a tick, a spinner-free cross, and the sentence saying
    /// which of the two it is. The wording is the step's whole value here — an
    /// icon alone would leave a user who cannot see the screen colour with no way
    /// to tell which of the two checks failed.
    private func stepStatus(done: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The in-flight wireless pairing. Drawn in place of the two acquire buttons,
    /// because the advertisement blocks until the device connects — this row's
    /// jobs are to say the host is up, show a PIN if the device asks for one, and
    /// offer a way out so a pairing that never connects does not look frozen.
    private var wirelessPairProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text(wirelessPair.serviceName
                        .map { "正在广播“\($0)”——等待这台 iPhone 连接…" }
                     ?? "正在启动配对服务…")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pin = wirelessPair.pin {
                Text("PIN 码：\(pin)")
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                NativeNote("在“设置”→“隐私与安全性”→“开发者"
                    + "模式”→“与 \(WirelessPairing.displayName) 配对”中确认此 PIN，即可完成配对。")
            } else {
                NativeNote("请保持此屏幕开启，然后在这台 iPhone 上打开“设置”→“隐私与安全性”→“"
                    + "开发者模式”，并点按“与 "
                    + "\(WirelessPairing.displayName)”。iOS 27 会自行将手机连接到"
                    + "所广播的服务——全程无需电脑。")
            }
            Button(role: .destructive) {
                wirelessPair.cancel()
            } label: {
                Label("取消配对", systemImage: "xmark.circle")
            }
        }
    }

    private var canFinish: Bool { tunnel.isReady && pairingReady }

    // MARK: - Actions

    /// Fill the tunnel step's state, off the main actor.
    ///
    /// `Task.detached` on purpose: `probePeer` waits for the peer's lockdown port,
    /// and this runs from a view body-adjacent task that the user is scrolling —
    /// the same two-second stall the home page's `refreshTunnelStatus()` is written
    /// to avoid, in a place with nowhere to hide it.
    private func probe() async {
        let (interfaceUp, peerReachable) = await Task.detached(priority: .utility) {
            (Tunnel.isInterfaceUp(), Tunnel.probePeer(timeout: 1.0))
        }.value
        let next: TunnelStep = interfaceUp ? (peerReachable ? .ready : .peerUnreachable) : .interfaceMissing
        if next != tunnel {
            GoldenNuggetEngine.shared.log("初始设置：隧道 — \(next.text)")
        }
        tunnel = next
    }

    /// Import a record and record it the way the home page's import does.
    ///
    /// The home page adopts it on its first `.task`, reading the canonical file
    /// first — so this deliberately does **not** start anything itself: two
    /// starters would be the duplicate-start race `startMinimuxer`'s lock was added
    /// to prevent.
    private func importRecord(from url: URL) {
        do {
            let record = try PairingRecord.accept(contentsOf: url)
            PairingRecord.persist(record)
            pairingReady = true
            GoldenNuggetEngine.shared.log("初始设置：已导入配对文件 "
                + "(\(PairingRecord.sourceLabel(record)), \(record.count) bytes)")
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("初始设置：配对文件导入失败 "
                + "(\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    /// Take the record the wireless pairing produced.
    ///
    /// Routed through `PairingRecord` either way — the library's own file is the
    /// canonical one, so it is adopted in place rather than rewritten, and a
    /// library that wrote somewhere else is imported like any other file. Both
    /// paths apply `usable(_:)`, so a record produced inside the app gets the same
    /// rejection a picked file would.
    private func adoptGeneratedRecord(at path: String?) {
        guard let path else { return }
        defer { wirelessPair.reset() }
        do {
            let record = path == AppPaths.pairingFile.path
                ? try PairingRecord.adoptFromDisk()
                : try PairingRecord.accept(contentsOf: URL(fileURLWithPath: path))
            if path != AppPaths.pairingFile.path { PairingRecord.persist(record) }
            pairingReady = true
            GoldenNuggetEngine.shared.log("初始设置：已采用无线配对记录 "
                + "(\(PairingRecord.sourceLabel(record)))")
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("初始设置：无线配对记录被拒绝 — "
                + "\(error.localizedDescription)")
        }
    }
}