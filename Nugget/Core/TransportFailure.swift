import Foundation

// The device-transport failure model.
//
// WHY THIS TYPE EXISTS
//
// `IdeviceGateway` reports every failure as
// `IdeviceGatewayError(.serviceError, reason: String)` — the FFI error code is
// discarded and only the message survives.  The engine therefore had to decide
// "is this worth retrying?" by grepping `String(describing: error).lowercased()`,
// which is how two overlapping predicates appeared
// (`isTransientRestoreError` matched any message containing "mobilebackup2" —
// its own doc comment called that "too broad" — and `isTransientChannelError`
// matched the socket literals).  The retry ladder then had no way to know WHICH
// layer was broken, so it escalated by attempt number instead.
//
// This enum is the single place where the raw text becomes a type.  Everything
// downstream — the retry decision, the recovery level, the operator-facing
// message — reads the type, not the string.

/// Which layer's cached state has to be discarded before a retry can work.
///
/// Ordered: each level does everything the previous one does.
enum RecoveryLevel: Int, Comparable {
    /// Release the cached RSD adapter + handshake, so the next attempt dials a
    /// fresh RemotePairing session.
    case dropRSD = 1
    /// Also re-discover the tunnel peer.  A tunnel flap leaves the cached
    /// `deviceEndpointIp` stale, and every attempt then dies identically no
    /// matter how often the adapter is dropped.
    case refreshEndpoint = 2
    /// Also re-pin the endpoint and rebuild the muxer plumbing.  A fresh jktcp
    /// connection gets a clean sequence space, which is the only thing that
    /// closes a hole this stack has no gap recovery for.
    case restartMuxer = 3

    static func < (lhs: RecoveryLevel, rhs: RecoveryLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the retry controller should do with a failure.
enum RetryDecision {
    /// Do not retry; the failure is not about the connection.
    case failFast(reason: String)
    /// Retry, and release at least this much cached state first.
    case retry(floor: RecoveryLevel, reason: String)
}

/// A classified device-transport failure.
///
/// Carries everything the retry decision and the operator-facing message need,
/// so neither has to re-parse text or re-derive context.
enum TransportFailure: Error, LocalizedError {
    /// The operator pressed stop.  Nobody should retry this.
    case cancelled(label: String)

    /// Parked in `dl_version_exchange()` waiting for the device's FIRST
    /// DeviceLink message.  This side has not sent anything yet.
    ///
    /// ⚠️ **NOT PRODUCED ANY MORE** (2026-09-20). `StallGuard` no longer times a
    /// call out; it reports this condition and keeps waiting. See `StallGuard`'s
    /// header for the measured reason (abandoning a mid-flight exchange wedged
    /// the device-side daemon). Kept, with its recovery ladder, so reinstating
    /// the guard does not mean rewriting it.
    case handshakeSilent(label: String, heldSeconds: Int)

    /// Handshake completed, then the stream went quiet mid-operation.
    ///
    /// ⚠️ **NOT PRODUCED ANY MORE** — same note as `handshakeSilent`.
    case streamStalled(label: String, heldSeconds: Int, probeVerdict: String?)

    /// The device is still pushing bytes but jktcp cannot deliver them: the gap
    /// is a contiguous run and the only thing that fills it is the peer
    /// re-sending the missing range.
    ///
    /// (The doc used to say "a UDP segment was lost".  That is one candidate
    /// cause, not the measurement — see the note on the message below.)
    ///
    /// ⚠️ **NOT PRODUCED ANY MORE** — same note as `handshakeSilent`. The
    /// measurement itself is alive: `StallGuard.crawlObservation` still computes
    /// it every poll and prints it. Only the "abandon the call and rebuild the
    /// tunnel" half was removed, because that teardown is what wedged the daemon
    /// and it never once recovered a transfer.
    case tunnelCrawl(label: String, spanSeconds: Int, gapBytes: UInt64,
                     deliveryBytesPerSecond: Double, outOfOrderSegments: Int,
                     retransmits: Int, heldDropped: Int)

    /// The socket-level session is gone (BrokenPipe / channel closed / SSLEOF /
    /// connection terminated / reset).
    case channelLost(label: String, raw: String)

    /// The device answered, and said no.  Validation, not transport — retrying
    /// the same bytes changes nothing.
    case deviceRejected(label: String, raw: String)

    /// iOS refused the operation because the device is locked
    /// (`MBErrorDomain/208`, "Device locked").
    ///
    /// Distinct from `deviceRejected` because the operator action is different
    /// and so is the retry decision: this one is not about the backup's
    /// contents, it is "unlock the screen and run again".  It shows up on the
    /// attempt that follows a teardown, which makes it look like the retry made
    /// things worse — it did not, the screen simply went to sleep during the
    /// minutes the earlier attempt spent crawling.
    case deviceLocked(label: String, raw: String)

    /// The exchange ended without the device finishing the work, and without
    /// naming an error.
    ///
    /// A third outcome next to "succeeded" and "failed", and the one this app
    /// could not see: the device abandons a restore part-way and closes the
    /// stream exactly as cleanly as it closes one it completed, so the FFI
    /// raises nothing.  The distinction lives in the device's own response plist
    /// and in how far its progress got — and the host side here used to free
    /// that plist unread and never look at the final progress, which is how a
    /// 55 % restore came to be reported as a success.
    ///
    /// Retrying is pointless (same manifest, same device) — the host-side
    /// accounting is what has to be compared against what the manifest offered.
    case restoreIncomplete(label: String, raw: String)

    /// The gateway was never started, so there is no session to retry on.
    case notReady(label: String, raw: String)

    /// Unclassified.  Treated as non-retryable, which is the conservative
    /// choice: a device-side rejection must not be retried forever.
    case unknown(label: String, raw: String)

    var label: String {
        switch self {
        case .cancelled(let l), .handshakeSilent(let l, _), .streamStalled(let l, _, _),
             .tunnelCrawl(let l, _, _, _, _, _, _), .channelLost(let l, _),
             .deviceRejected(let l, _), .deviceLocked(let l, _),
             .restoreIncomplete(let l, _), .notReady(let l, _), .unknown(let l, _):
            return l
        }
    }

    /// True when the run ended because the operator asked it to.  The UI reads
    /// this to say "stopped" instead of "failed".
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var retryDecision: RetryDecision {
        switch self {
        case .cancelled:
            return .failFast(reason: "用户已停止 —— 不再重试。")

        // A handshake stall is NOT a dropped channel: the device accepted the
        // connection and never said a single word.  A fresh RSD tunnel does not
        // help — the Rust log shows the retry getting a brand-new tunnel and
        // then not even receiving the DeviceLink version exchange reply — so
        // fail fast instead of spending another whole attempt (and another
        // 2 minutes) to arrive at the same place.  Worst case: the device daemon
        // is wedged and only a reboot clears it.
        case .handshakeSilent:
            return .failFast(reason: "设备始终未回应握手")

        // A plain channel drop is a state of the session: drop the RSD adapter
        // and dial again.
        case .channelLost:
            return .retry(floor: .dropRSD, reason: "通道已断开")

        // A MID-STREAM stall is a different animal: the exchange ran, data
        // landed, and the stream then went quiet.  The backup already on disk
        // stays (a retry is incremental), so one more attempt is cheap next to
        // throwing the run away.  Re-discovering the endpoint is included
        // because the gateway caches both the RSD adapter AND the IP the Rust
        // tunnel dials, and either being stale reproduces the stall exactly.
        case .streamStalled:
            return .retry(floor: .refreshEndpoint, reason: "传输中途静默")

        // A tunnel crawl is retried for a stronger reason than "worth one more
        // try": it is a *state* of the jktcp connection, and the recovery below
        // discards that connection outright.  Rebuilding the RSD adapter creates
        // a new CDTunnel and a new jktcp session, i.e. a clean sequence space —
        // the one thing that can clear a hole this stack has no recovery for.
        //
        // The wording stays cause-neutral on purpose: "stopped delivering" is what
        // was measured, "a datagram went missing" is a hypothesis (see the note
        // on the crawl message).
        case .tunnelCrawl:
            return .retry(floor: .restartMuxer,
                          reason: "隧道丢失（隧道停止投递）")

        case .deviceRejected:
            return .failFast(reason: "设备拒绝了请求")
        case .deviceLocked:
            return .failFast(reason: "设备已锁定")
        // A short restore is deterministic: the same manifest goes to the same
        // device and it stops at the same place.  The work is in the host-side
        // accounting, not in another attempt.
        case .restoreIncomplete:
            return .failFast(reason: "恢复未完成")
        case .notReady:
            return .failFast(reason: "设备网关未初始化")
        case .unknown:
            return .failFast(reason: "并非通道断开")
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled(let label):
            return "\(label) 被用户停止 —— 进行中的调用已放弃 "
                + "（阻塞的 Rust 读取无法中断，只能放弃）"

        case .handshakeSilent(let label, let held):
            return "\(label) 期间设备始终未发送第一条 DeviceLink "
                + "消息（已静默 \(held)s）。此时 mobilebackup2 客户端只是读取方，"
                + "由设备以 DLMessageVersionExchange 发起、本端只负责应答 —— 因此 "
                + "应用发出的任何内容都不会导致此问题，当前加载的二进制文件也不可疑。"
                + "是设备侧的备份守护进程没有出声：它会在无法处理的请求上卡死，"
                + "并且在应用重启后仍保持卡死，因此请先重启设备再"
                + "重试。背景见：scripts/patch-idevice-target-identifier.sh"

        case .streamStalled(let label, let held, let verdict):
            var s = "\(label) 数据流已静默 \(held)s —— 主机回调与 "
                + "DeviceLink 通道均无活动"
            if let verdict { s += ". 静默开始时的带外检查：\(verdict)" }
            s += ". 从这里看，两种原因一模一样，应用日志能区分它们：要么是"
                + "设备侧阶段虽慢但仍有活动（重试会基于磁盘上已有的备份继续，"
                + "因此只损失基线），要么是 mobilebackup2 数据流卡死或"
                + "在主机侧文件错误后失去同步（见 'delegate errors' 行）。"
            return s

        case .tunnelCrawl(let label, let span, let gap, let rate, let outOfOrder,
                          let retransmits, let heldDropped):
            var s = "\(label) 隧道停止投递：jktcp 仍在从 "
                + "设备接收分段（目前已有 \(outOfOrder) 个乱序）"
            s += "，其中 \(gap / 1024) KB 卡在未填补的缺口之后"
            s += String(format: "，投递速率仅 %.1f KB/s", rate / 1024)
            s += "，持续 \(span)s。实测结果是传输层拒绝向上交付字节。"
                + "这一层之上的所有组件全程看起来正常（lockdown 有应答，"
                + "存活探测也判定设备在线）。"
            // The measurement that decides what to do next.  A hole closes only
            // when the peer re-sends the missing range, so "did it re-send
            // anything" separates a slow recovery from a dead end.
            if retransmits > 0 {
                s += " 对端确实重发了 \(retransmits) 个区间，因此缺口正在被处理 —— "
                    + "它在缓慢闭合，而不是完全不动。"
            } else {
                s += " 整个窗口内对端没有重发任何区间（jktcp 未记录到任何"
                    + "重传），所以等待无法解决：缺口之后的字节"
                    + "已被保留，但缺失的区间永远不会回来。只有重建"
                    + "连接才能闭合缺口。"
            }
            // What the receiver did with the data behind the gap.
            //
            // This clause used to say the opposite — "out-of-order data is
            // discarded rather than buffered, so the peer has to resend
            // everything" — which was accurate before the reorder buffer existed
            // and is not any more.  Measured 2026-09-19: every one of 3,509
            // out-of-order lines read `held=true`, the buffer reached 3,265,094 B,
            // and `held=false` / "reorder window full" never appeared.  Leaving
            // the old wording in place would send the next reader after a
            // receiver bug that is not there.
            if heldDropped > 0 {
                s += " 有 \(heldDropped) 个分段因重排窗口已满而不得不被拒收，"
                    + "因此部分数据流确实被丢弃而非保留 —— 那部分也需要"
                    + "重传。"
            } else {
                s += " 接收方保留了收到的每一个分段（重排窗口从未填满），"
                    + "因此缺口之后的内容没有被丢弃 —— 只是在缺失区间"
                    + "到达之前无法交付。"
            }
            // Do NOT assert that a datagram was dropped.  The contiguous run
            // makes "one datagram lost" a good guess — a tunnel datagram carries
            // many segments, so losing one costs a whole consecutive range — but
            // it is a guess: nothing in the repo exposes the tunnel's datagram
            // size, so the framing cannot be checked from here.
            //
            // The discriminator that IS available is reproducibility.  Compare
            // this crawl's gap and out-of-order count against the previous one.
            // 2026-09-19 is instructive in both directions: one earlier pair DID
            // match exactly (2544 segments / 2838 KB, twice), but five later
            // attempts produced gaps of the same magnitude and different bytes
            // (2915 / 2920 / 3048 / 3083 / 3184 / 3277 KB).  Same size, different
            // range, is not a fixed offset in a replayed stream.
            s += " 要判断这是丢了一个隧道数据报（连续空洞正是其表现），"
                + "还是固定偏移处的确定性停滞，请在得出结论前检查："
                + "新隧道上缺口与乱序计数完全相同即可排除随机性，"
                + "而缺口大小相同但字节不同则不能。"
            return s

        case .channelLost(let label, let raw):
            // `Socket(... BrokenPipe, "channel closed")` is jktcp's generic report
            // for "that TCP flow is gone" — the userspace stack drops its
            // per-port sender when the connection is torn down, so a DEVICE-SIDE
            // close and a local pump failure look identical here.  It therefore
            // cannot be read as "the device refused us".
            return "\(label) 通道断开：\(raw)。\"channel closed\" 是 jktcp 的通用"
                + "连接关闭报告 —— 它无法区分是设备侧拆除还是本地"
                + "协议栈故障。真实步骤请查看 minimuxer.log（Rust，DEBUG）。"

        case .deviceRejected(let label, let raw):
            return "设备拒绝了 \(label)：\(raw)。这是校验应答，并非通道"
                + "断开，因此同样的字节会被再次拒绝 —— 请修复备份，不要重试。"

        case .deviceLocked(let label, let raw):
            return "\(label) 被拒绝，因为设备已锁定（\(raw)）。iOS 不会在锁定设备上运行"
                + "mobilebackup2 备份或恢复，所以问题既不在"
                + "隧道也不在备份 —— 请解锁屏幕并保持常亮，然后重新运行。"
                + "值得注意：如果它出现在后续尝试中，是因为缓慢传输会让屏幕"
                + "闲置数分钟，设备会在运行中途自行锁屏，"
                + "而报告这一点的正是下一次尝试。"

        case .restoreIncomplete(let label, let raw):
            return "\(label) 提前结束：\(raw)。设备结束交换时没有给出"
                + "错误，这正是为什么看起来一切正常 —— 它中途放弃的恢复"
                + "关闭数据流的干净程度与完成时一样，而主机过去会"
                + "不读设备响应 plist 就释放它，而不是去询问发生了什么。现在会检查两个独立"
                + "信号（响应 plist 的 ErrorCode，以及设备进度"
                + "走到了哪里），而本次两者都为空。重试会把同一份"
                + "清单发给同一台设备，因此下一步是核对主机侧账目：比较"
                + "'commit:' / 'delegate errors:' 行以及 'device pulled N file(s)' 与"
                + "清单提供的载荷数量，并检查过滤器保留与排干了什么。"

        case .notReady(let label, let raw):
            return "\(label) 无法运行：设备网关尚未就绪（\(raw)）"

        case .unknown(let label, let raw):
            return "\(label) 失败：\(raw)"
        }
    }
}

// MARK: - Classification

/// The one place where raw gateway text becomes a `TransportFailure`.
///
/// Every literal here is deliberate.  Adding a phrase widens what gets retried,
/// so the lists stay explicit and narrow rather than clever.
enum TransportFailureClassifier {
    /// "The session is gone at the socket level."
    ///
    /// These are exactly the literals the old `isTransientChannelError` matched,
    /// kept verbatim so the retry set does not silently change.  jktcp reports a
    /// torn-down flow as `Socket(... BrokenPipe, channel closed)`; the HTTPS/TLS
    /// layer of RSD reports SSLEOF / ConnectionTerminated; the kernel reports
    /// ECONNRESET.
    static let channelLossLiterals: [String] = [
        "brokenpipe",
        "channel closed",
        "connectionterminated",
        "ssleof",
        "connection reset",
        "connectionreset",
    ]

    /// "The device is locked."
    ///
    /// Checked before `deviceRejectionLiterals` so the operator gets the
    /// actionable message.  Both spellings are real: the response carries the
    /// numeric code and a human description, and different daemons surface one
    /// or the other.
    static let deviceLockedLiterals: [String] = [
        "mberrordomain/208",
        "device locked",
    ]

    /// "The device understood and said no."
    ///
    /// Named so the log can say why a retry was skipped.  These are the
    /// validation answers seen from the restore daemon: a manifest row with no
    /// payload (MBErrorDomain/205, "Unknown domain name in file record"), a
    /// commit shortfall (MBErrorDomain/104, "Manifest references files not in
    /// backup"), and a rejected pairing identity.
    static let deviceRejectionLiterals: [String] = [
        "unknown domain name in file record",
        "manifest references files not in backup",
        "mberrordomain/205",
        "mberrordomain/104",
        "invalidhostid",
    ]

    /// "The exchange ended without the device finishing the work."
    ///
    /// Both spellings are produced by `IdeviceGateway.syncRestoreBackup`: one
    /// when the device named an error code in its final plist, one when it named
    /// nothing and simply stopped before the end.  They share a case because the
    /// operator action is the same — look at the manifest and the host-side
    /// accounting, not at the tunnel.
    static let restoreIncompleteLiterals: [String] = [
        "restore stopped short",
        "restore did not complete",
    ]

    /// Cached config that makes `deviceRejected` a false negative; checked last
    /// so a genuine socket error still wins the classification.
    static let notReadyLiterals: [String] = [
        "has not been initialized",
        "not initialized",
    ]

    /// Classify a thrown error.  An already-typed failure passes through
    /// unchanged, which is what keeps the stall guard's own verdicts intact
    /// through the retry ladder.
    static func classify(_ error: Error, label: String) -> TransportFailure {
        if let failure = error as? TransportFailure { return failure }

        let raw = String(describing: error)
        let lower = raw.lowercased()

        if channelLossLiterals.contains(where: { lower.contains($0) }) {
            return .channelLost(label: label, raw: raw)
        }
        if deviceLockedLiterals.contains(where: { lower.contains($0) }) {
            return .deviceLocked(label: label, raw: raw)
        }
        if deviceRejectionLiterals.contains(where: { lower.contains($0) }) {
            return .deviceRejected(label: label, raw: raw)
        }
        // Checked after the rejection literals so a device error we can name
        // still wins; this catches "no error at all, it just stopped".
        if restoreIncompleteLiterals.contains(where: { lower.contains($0) }) {
            return .restoreIncomplete(label: label, raw: raw)
        }
        if notReadyLiterals.contains(where: { lower.contains($0) }) {
            return .notReady(label: label, raw: raw)
        }
        return .unknown(label: label, raw: raw)
    }
}
