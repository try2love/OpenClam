import Foundation
import CoreGraphics
import Darwin

private let driverHelper = executable.deletingLastPathComponent().appendingPathComponent("clamshell-driver")
private let linkHelper = executable.deletingLastPathComponent().appendingPathComponent("display-link")
private let rebindHelper = executable.deletingLastPathComponent().appendingPathComponent("display-rebind")
private var routingInterrupted: sig_atomic_t = 0
private var routingLogHandle: FileHandle?
private var routingOutput: FileHandle { routingLogHandle ?? FileHandle.standardError }

// New experiments are suspended after a report that an external output stayed
// unavailable after app exit and a physical lid close. Keep recovery callable.
let routingExperimentEnabled = false
let routingExperimentDisabledMessage = "双外屏实验已停用：发现可能影响外屏后续连接的回归，当前版本不再启动此实验。"

// Enumeration is only a prerequisite for a preview, never proof of scanout.
func routingTopologyReady(queryOK: Bool, physicallyOpen: Bool, builtinActive: Bool,
                          activeExternalIDs: [UInt32]) -> Bool {
    queryOK && physicallyOpen && !builtinActive && Set(activeExternalIDs).count >= 2
}

func routingConfirmationExpired(readyAt: Double?, now: Double, confirmed: Bool) -> Bool {
    guard let readyAt = readyAt else { return false }
    return !confirmed && now - readyAt >= 30
}

private func routingReady(requireAwake: Bool = true) -> Bool {
    let (error, ids) = displays()
    return routingTopologyReady(queryOK: error == .success, physicallyOpen: lidClosed() == false,
        builtinActive: ids.contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 },
        activeExternalIDs: ids.filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 && (!requireAwake || CGDisplayIsAsleep($0) == 0)
        })
}

private func builtinRestored() -> Bool {
    let (error, ids) = displays()
    return error == .success && ids.contains {
        CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
    }
}

private func routingEvent(_ event: [String: Any]) {
    var record = event
    record["timestamp"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        routingOutput.write(data + Data([10]))
    }
}

// Own/reap every mutator before rollback: a late close must never race an open.
private func boundedRun(_ url: URL, _ arguments: [String], timeout: Double = 5) -> (Int32, String) {
    let child = Process(), output = Pipe()
    let operation = url == rebindHelper ? "rebind-external" : (arguments.first ?? "snapshot")
    routingEvent(["event": "helper_start", "helper": url.lastPathComponent, "operation": operation])
    // Foundation Process creates a fresh process group. Join explicitly in a
    // small launcher before exec, so an orphaned mutator remains killable with
    // its guardian group. The alarm survives exec even if the guardian dies.
    child.executableURL = executable
    child.arguments = ["--routing-child", String(getpgrp()), String(Int(ceil(timeout)) + 1), url.path] + arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output; child.standardError = routingOutput
    do { try child.run() } catch {
        routingEvent(["event": "helper_end", "helper": url.lastPathComponent, "operation": operation, "exitStatus": 127])
        return (127, error.localizedDescription)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
    let expired = child.isRunning
    if expired {
        child.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    child.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    if !data.isEmpty { routingOutput.write(data) }
    routingEvent(["event": "helper_end", "helper": url.lastPathComponent, "operation": operation,
                  "exitStatus": expired ? 124 : child.terminationStatus, "timedOut": expired])
    return (expired ? 124 : child.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func jsonRecord(_ result: (Int32, String)) -> [String: Any]? {
    guard result.0 == 0, let data = result.1.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// Bounded, read-only snapshots. Never query the HID sensor in a guardian.
private func routingEvidence(_ phase: String) {
    routingEvent(["event": "phase", "phase": phase])
    _ = boundedRun(linkHelper, [])
}

func routingDiagnosticReport() -> Data? {
    routingEvent(["event": "report_current_snapshot"])
    let result = boundedRun(linkHelper, [])
    return RoutingDiagnostics.latestReport(currentLinkData: result.0 == 0 ? result.1.data(using: .utf8) : nil)
}

private func recoverRouting(target: String, savedState: String, selectedExternal: Bool) -> Bool {
    routingEvent(["event": "restore_started", "selectedExternal": selectedExternal])
    if selectedExternal { _ = boundedRun(driverHelper, ["quiesce", target]) }
    let opened = boundedRun(driverHelper, ["open", target]).0 == 0
    // Release the override immediately; restore the panel only after a real reopening.
    while lidClosed() == true { Thread.sleep(forTimeInterval: 0.5) }
    if selectedExternal { _ = boundedRun(driverHelper, ["select-internal", target]) }
    var restored = false
    for _ in 0..<2 {
        // Observe the original built-in endpoint before energizing its panel.
        guard boundedRun(executable, ["--routing-prepare", savedState], timeout: 5).0 == 0 else { continue }
        // Power only. The old `on` fallback could confuse IOMFB indices with CG IDs.
        _ = boundedRun(helper, ["panel-on"])
        let result = boundedRun(executable, ["--routing-recover", savedState], timeout: 14)
        if result.0 == 0 && builtinRestored() { restored = true; break }
    }
    routingEvent(["event": "restore_finished", "opened": opened, "modeRestored": restored])
    return opened && restored
}

func routingChild(group: pid_t, timeout: UInt32, command: [String]) -> Never {
    let siblings = ["display-helper", "clamshell-driver", "display-link", "display-rebind"].map {
        executable.deletingLastPathComponent().appendingPathComponent($0).path
    }
    let ownRecovery = command.first == executable.path && command.count == 3 &&
        ["--routing-prepare", "--routing-recover"].contains(command[1])
    guard let path = command.first, siblings.contains(path) || ownRecovery,
          timeout > 0, timeout <= 15, group > 1, group == getpgid(getppid()),
          setpgid(0, group) == 0, getpgrp() == group else { exit(126) }
    alarm(timeout)
    var argv = command.map { strdup($0) } + [nil]
    path.withCString { pointer in _ = execv(pointer, &argv) }
    for pointer in argv { free(pointer) }
    exit(127)
}

func routingGuardian(duration: Double, savedState: String) -> Never {
    guard routingExperimentEnabled else {
        print("FAILED:\(routingExperimentDisabledMessage)"); fflush(stdout); exit(2)
    }
    // The owner can stop every surviving mutator if this guardian itself dies.
    guard setpgid(0, 0) == 0 else { print("FAILED:无法隔离恢复守护进程"); fflush(stdout); exit(0) }
    signal(SIGINT) { _ in routingInterrupted = 1 }
    signal(SIGTERM) { _ in routingInterrupted = 1 }
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    let started = ProcessInfo.processInfo.systemUptime
    var lastBeat = started
    var readyAt: Double?
    var confirmed = false
    func stopReason() -> String? {
        if routingInterrupted != 0 { return "interrupted" }
        var bytes = [UInt8](repeating: 0, count: 128)
        let now = ProcessInfo.processInfo.systemUptime
        var n: Int
        repeat {
            n = read(STDIN_FILENO, &bytes, bytes.count)
            if n > 0 {
                lastBeat = now
                if readyAt != nil && bytes.prefix(n).contains(2) && routingReady() { confirmed = true }
            }
        } while n > 0 // Drain queued heartbeats to observe EOF before any further mutation.
        if let reason = recoveryReason(externals: externalCount(), eof: n == 0,
            readError: n < 0 && errno != EAGAIN && errno != EINTR,
            age: now - lastBeat, elapsed: now - started, duration: duration) { return reason }
        if duration == 0 && routingConfirmationExpired(readyAt: readyAt, now: now, confirmed: confirmed) {
            return "confirmation_expired"
        }
        return nil
    }
    func fail(_ message: String, recovered: Bool = true) -> Never {
        print("FAILED:\(message)"); fflush(stdout); exit(recovered ? 0 : 3)
    }
    guard Data(base64Encoded: savedState).flatMap({ try? JSONDecoder().decode(BuiltinDisplayState.self, from: $0) }) != nil,
          lidClosed() == false, externalCount() > 0, let originalID = builtinID(),
          CGDisplayIsActive(originalID) != 0, !hasMirroring() else {
        fail("需要开盖、可用的内屏和至少一台处于扩展模式的外屏")
    }
    let originalExternals = Set(displays().1.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 })
    guard let record = jsonRecord(boundedRun(driverHelper, ["identify"])),
          let registryID = record["registryID"] as? NSNumber else { fail("未找到可控制的内建显示通道") }
    let target = registryID.stringValue
    routingEvent(["event": "routing_baseline", "originalExternalIDs": originalExternals.sorted(),
                  "pinnedRegistryID": registryID, "preparation": "layout_only"])
    routingEvidence("before_layout_off")
    var changed = false, selectedExternal = false
    func rollback(_ reason: String) -> Bool {
        guard changed else { return true }
        let ok = recoverRouting(target: target, savedState: savedState, selectedExternal: selectedExternal)
        FileHandle.standardError.write(Data(("{\"routingRestore\":\(ok),\"reason\":\"\(reason)\"}\n").utf8))
        return ok
    }
    func abort(_ reason: String, _ message: String) -> Never {
        let ok = rollback(reason)
        fail(message + (ok ? "，内屏已恢复" : "，内屏恢复尚未确认"), recovered: ok)
    }
    if let reason = stopReason() { fail(reason) }
    changed = true
    // Let WindowServer manage power while disabling the built-in layout. The
    // normal off helper additionally requests power0 outside its bookkeeping;
    // on M3 the shared endpoint subsequently enumerated with no picture. Avoid
    // that extra vote in this experiment; layout-off can still power down via CA.
    let off = boundedRun(helper, ["layout-off", "--commit", "session"]).0
    if off != 0 || stopReason() != nil { abort("layout_off_interrupted", "切换中止") }
    routingEvidence("after_layout_off")
    Thread.sleep(forTimeInterval: 1)
    if let reason = stopReason() { abort(reason, "切换中止") }
    if boundedRun(driverHelper, ["close", target]).0 != 0 { abort("driver_rejected", "系统未接受合盖请求") }
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    var stableSince: Double?
    var topologyReady = false
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let reason = stopReason() { abort(reason, "切换中止") }
        if routingReady(requireAwake: false) {
            if stableSince == nil { stableSince = ProcessInfo.processInfo.systemUptime }
            if ProcessInfo.processInfo.systemUptime - stableSince! >= 1 { topologyReady = true; break }
        } else { stableSince = nil }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard topologyReady else {
        routingEvidence("topology_not_ready")
        abort("dual_external_not_observed", "未能识别两台活动外屏")
    }
    let newIDs = Set(displays().1.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }).subtracting(originalExternals)
    routingEvent(["event": "routing_selection_decision", "originalExternalIDs": originalExternals.sorted(),
                  "currentExternalIDs": displays().1.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }.sorted(),
                  "newExternalIDs": newIDs.sorted(), "selectionRequired": !newIDs.isEmpty])
    routingEvent(["event": "phase", "phase": "after_clamshell_close"])
    let afterClose = boundedRun(linkHelper, [])
    // Select only the newly appeared external on the shared internal channel.
    // A successful A476 lid request did not by itself start M3 scanout in v0.2.
    if !newIDs.isEmpty {
        guard let links = jsonRecord(afterClose),
              let channels = links["framebuffers"] as? [[String: Any]],
              let pinned = channels.first(where: { ($0["registryID"] as? NSNumber)?.stringValue == target }),
              let id = (pinned["matchedDisplayID"] as? NSNumber)?.uint32Value, newIDs.contains(id) else {
            abort("new_external_binding_unknown", "无法确认第二外屏的输出通道")
        }
        if let reason = stopReason() { abort(reason, "切换中止") }
        routingEvent(["event": "external_selection_target", "displayID": id, "pinnedRegistryID": registryID])
        selectedExternal = true // Even a rejected/timed-out request requires symmetric recovery.
        if boundedRun(driverHelper, ["select-external", target, String(id)]).0 != 0 {
            routingEvidence("external_selection_rejected")
            abort("external_selection_rejected", "系统未接受外屏输出选择")
        }
        Thread.sleep(forTimeInterval: 1)
        routingEvidence("before_external_rebind")
        if let reason = stopReason() { abort(reason, "切换中止") }
        // Driver selection alone left the M3 external enumerated but dark.
        // Request one real WindowServer activation cycle on that endpoint;
        // its independent helper revalidates UUID, framebuffer and saved mode.
        if boundedRun(rebindHelper, [target, String(id)], timeout: 12).0 != 0 {
            routingEvidence("external_rebind_failed")
            abort("external_rebind_failed", "系统未能重新启用第二外屏")
        }
    }
    routingEvidence(selectedExternal ? "after_external_rebind" : "output_selection_skipped")
    if let reason = stopReason() { abort(reason, "切换中止") }
    guard routingReady() else { abort("topology_lost", "外屏状态未保持稳定") }
    readyAt = ProcessInfo.processInfo.systemUptime
    print("PREVIEW"); fflush(stdout)
    _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    emit(["routingGuardianPreview": true, "visualConfirmed": false, "selectedNewExternal": selectedExternal])
    while true {
        if let reason = stopReason() { exit(rollback(reason) ? 0 : 3) }
        if builtinRestored() { exit(rollback("builtin_reactivated") ? 0 : 3) }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

final class RoutingSession {
    private var child: Process?
    private var input: Pipe?
    private var recoveryTarget: (registryID: String, savedState: String)?
    private var orphanGroup: pid_t?
    private var diagnostics: RoutingDiagnostics?

    func recordFeedback(_ value: String) {
        diagnostics?.append(event: ["event": "visual_feedback", "result": value])
    }
    private(set) var recoveryUnconfirmed = false
    private(set) var visualConfirmed = false
    var lastError = ""
    var running: Bool { child?.isRunning == true }

    private func refreshCompletion() {
        guard let process = child, !process.isRunning else { return }
        process.waitUntilExit()
        input?.fileHandleForWriting.closeFile(); input = nil
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            orphanGroup = process.processIdentifier
        }
        diagnostics?.append(event: ["event": "guardian_exit", "status": process.terminationStatus,
                                    "normalExit": process.terminationReason == .exit])
        child = nil; visualConfirmed = false
        recoveryUnconfirmed = process.terminationReason != .exit || process.terminationStatus != 0
        if !recoveryUnconfirmed { recoveryTarget = nil }
    }

    func start(duration: Double) -> Bool {
        guard routingExperimentEnabled else { lastError = routingExperimentDisabledMessage; return false }
        refreshCompletion()
        guard !running else { lastError = "已有双外屏会话正在运行"; return false }
        guard !recoveryUnconfirmed else { lastError = "内屏恢复尚未确认，请先点击恢复内建显示器"; return false }
        do {
            diagnostics = try RoutingDiagnostics.begin()
            routingLogHandle = diagnostics?.stderrHandle
        }
        catch { lastError = "无法保存本次实验记录，请检查可用磁盘空间"; return false }
        diagnostics?.append(event: ["event": "session_start", "duration": duration, "physicalLidClosed": lidClosed() as Any? ?? NSNull(), "activeExternalCount": externalCount()])
        guard lidClosed() == false, externalCount() > 0, let originalID = builtinID(),
              CGDisplayIsActive(originalID) != 0, !hasMirroring(),
              let state = captureBuiltinDisplayState(), let data = try? JSONEncoder().encode(state) else {
            lastError = "需要开盖、可用的内屏和至少一台处于扩展模式的外屏"
            diagnostics?.append(event: ["event": "start_refused", "reason": "preconditions"]); return false
        }
        guard let record = jsonRecord(boundedRun(driverHelper, ["identify"])),
              let registryID = record["registryID"] as? NSNumber else {
            lastError = "未找到可控制的内建显示通道"; return false
        }
        let savedState = data.base64EncodedString()
        recoveryTarget = (registryID.stringValue, savedState)
        let process = Process(), heartbeat = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--routing-guard", String(duration), savedState]
        process.standardInput = heartbeat; process.standardOutput = output
        process.standardError = diagnostics?.stderrHandle
        do { try process.run() } catch {
            recoveryTarget = nil; lastError = error.localizedDescription; return false
        }
        child = process; input = heartbeat; visualConfirmed = false
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        var response = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            beat()
            var bytes = [UInt8](repeating: 0, count: 1024)
            let n = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if n > 0 { response.append(contentsOf: bytes.prefix(n)) }
            if response.contains(10) || !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let message = String(data: response, encoding: .utf8) ?? ""
        guard message.hasPrefix("PREVIEW\n") else {
            lastError = message.hasPrefix("FAILED:") ? String(message.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) : "切换未完成，已请求恢复内屏"
            diagnostics?.append(event: ["event": "preview_failed", "message": lastError])
            _ = stop(); return false
        }
        diagnostics?.append(event: ["event": "preview_started"])
        return true
    }
    func confirmVisibleOutputs() -> Bool {
        beat()
        guard running, routingReady(), let pipe = input else { return false }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: Data([2])); visualConfirmed = true
            recordFeedback("both_outputs_visible"); return true
        }
        catch { return false }
    }
    func beat() {
        refreshCompletion()
        if running { try? input?.fileHandleForWriting.write(contentsOf: Data([1])) }
    }
    @discardableResult func stop() -> Bool {
        input?.fileHandleForWriting.closeFile(); input = nil
        if let process = child {
            if process.isRunning && lidClosed() == true { return false }
            process.waitUntilExit()
            refreshCompletion()
        }
        guard recoveryUnconfirmed else { return true }
        guard lidClosed() != true, let target = recoveryTarget else { return false }
        // Reaping the guardian alone does not reap its helper descendants.
        // Its isolated group must be empty before a fallback can change displays.
        if let group = orphanGroup {
            _ = kill(-group, SIGKILL)
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            while kill(-group, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard kill(-group, 0) != 0 && errno == ESRCH else { return false }
            orphanGroup = nil
        }
        let restored = recoverRouting(target: target.registryID, savedState: target.savedState, selectedExternal: true)
        diagnostics?.append(event: ["event": "owner_recovery_finished", "restored": restored])
        recoveryUnconfirmed = !restored
        if restored { recoveryTarget = nil }
        return restored
    }
}
