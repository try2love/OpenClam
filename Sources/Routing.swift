import Foundation
import CoreGraphics
import Darwin

private let driverHelper = executable.deletingLastPathComponent().appendingPathComponent("clamshell-driver")
private var routingInterrupted: sig_atomic_t = 0

// A successful setter is only a submitted request. These conditions distinguish
// M3 dual-output routing from the old single-external soft-disconnect result.
func routingAchieved(queryOK: Bool, physicallyOpen: Bool, builtinActive: Bool,
                     activeExternalIDs: [UInt32]) -> Bool {
    queryOK && physicallyOpen && !builtinActive && Set(activeExternalIDs).count >= 2
}

private func routingReady() -> Bool {
    let (error, ids) = displays()
    return routingAchieved(queryOK: error == .success, physicallyOpen: lidClosed() == false,
        builtinActive: ids.contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 },
        activeExternalIDs: ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 })
}

private func builtinRestored() -> Bool {
    let (error, ids) = displays()
    return error == .success && ids.contains {
        CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0
    }
}

// The guardian owns and reaps every mutator before starting rollback. In
// particular, owner death cannot leave a late close racing a completed open.
private func boundedRun(_ url: URL, _ arguments: [String], timeout: Double = 5) -> (Int32, String) {
    let child = Process(), output = Pipe()
    child.executableURL = url; child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output; child.standardError = FileHandle.standardError
    do { try child.run() } catch { return (127, error.localizedDescription) }
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
    if !data.isEmpty { FileHandle.standardError.write(data) }
    return (expired ? 124 : child.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func routingGuardian(duration: Double) -> Never {
    signal(SIGINT) { _ in routingInterrupted = 1 }
    signal(SIGTERM) { _ in routingInterrupted = 1 }
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    let started = ProcessInfo.processInfo.systemUptime
    var lastBeat = started
    func stopReason() -> String? {
        if routingInterrupted != 0 { return "interrupted" }
        var bytes = [UInt8](repeating: 0, count: 128)
        let now = ProcessInfo.processInfo.systemUptime
        var n: Int
        repeat {
            n = read(STDIN_FILENO, &bytes, bytes.count)
            if n > 0 { lastBeat = now }
        } while n > 0 // Drain queued heartbeats to see EOF before submitting close.
        return recoveryReason(externals: externalCount(), eof: n == 0,
            readError: n < 0 && errno != EAGAIN && errno != EINTR,
            age: now - lastBeat, elapsed: now - started, duration: duration)
    }
    func fail(_ message: String) -> Never {
        print("FAILED:\(message)"); fflush(stdout); exit(2)
    }
    guard lidClosed() == false, externalCount() > 0, let originalID = builtinID(),
          CGDisplayIsActive(originalID) != 0, !hasMirroring() else {
        fail("需要开盖、可用的内屏和至少一台处于扩展模式的外屏")
    }
    let identified = boundedRun(driverHelper, ["identify"])
    guard identified.0 == 0, let data = identified.1.data(using: .utf8),
          let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let registryID = record["registryID"] as? NSNumber else {
        fail("未找到可控制的内建显示通道")
    }
    let target = registryID.stringValue
    var changed = false
    func rollback(_ reason: String) -> Bool {
        guard changed else { return true }
        // Release the software override even if the physical lid was closed in
        // the meantime. Only panel/layout restoration waits for lid reopening.
        let opened = boundedRun(driverHelper, ["open", target]).0 == 0
        while lidClosed() == true { Thread.sleep(forTimeInterval: 0.5) }
        var restored = false
        for _ in 0..<3 {
            _ = boundedRun(helper, ["on", "--commit", "session", "--display-id", String(originalID)])
            Thread.sleep(forTimeInterval: 0.5)
            if builtinRestored() { restored = true; break }
        }
        FileHandle.standardError.write(Data(("{\"routingRestore\":\(opened && restored),\"reason\":\"\(reason)\"}\n").utf8))
        return opened && restored
    }
    if let reason = stopReason() { fail(reason) }
    changed = true // The soft-off itself also requires rollback on failure.
    // A later RequestPowerChange re-reads the physical lid and overwrites the
    // driver override. Submit closed only AFTER the soft power-off has settled.
    let off = boundedRun(helper, ["off", "--commit", "session"]).0
    Thread.sleep(forTimeInterval: 1)
    if off != 0 || stopReason() != nil {
        let ok = rollback("off_interrupted")
        fail(ok ? "切换中止，内屏已恢复" : "切换中止，内屏恢复尚未确认")
    }
    let closed = boundedRun(driverHelper, ["close", target]).0
    if closed != 0 {
        let ok = rollback("driver_rejected")
        fail(ok ? "系统未接受合盖请求，内屏已恢复" : "合盖请求失败，内屏恢复尚未确认")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    var stableSince: Double?
    var verified = false
    var interrupted: String?
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let reason = stopReason() { interrupted = reason; break }
        if routingReady() {
            if stableSince == nil { stableSince = ProcessInfo.processInfo.systemUptime }
            if ProcessInfo.processInfo.systemUptime - stableSince! >= 1 { verified = true; break }
        } else { stableSince = nil }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard verified else {
        let ok = rollback(interrupted ?? "dual_external_not_observed")
        fail(ok ? "未能启用两台外屏，内屏已自动恢复" : "未能启用两台外屏，内屏恢复尚未确认")
    }
    print("READY"); fflush(stdout)
    _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    // Keep HID reads out of the recovery loop: an unresponsive sensor must not
    // block the guardian's unplug, EOF or deadline checks.
    emit(["routingGuardianActive": true])
    while true {
        if let reason = stopReason() {
            exit(rollback(reason) ? 0 : 3)
        }
        // If the OS re-enables the internal display, end this experiment rather
        // than continually fighting macOS with repeated closure requests.
        if builtinRestored() { exit(rollback("builtin_reactivated") ? 0 : 3) }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

final class RoutingSession {
    private var child: Process?
    private var input: Pipe?
    private var recoveryTarget: (registryID: String, displayID: CGDirectDisplayID)?
    private(set) var recoveryUnconfirmed = false
    var lastError = ""
    var running: Bool { child?.isRunning == true }

    private func refreshCompletion() {
        guard let process = child, !process.isRunning else { return }
        process.waitUntilExit()
        input?.fileHandleForWriting.closeFile(); input = nil
        child = nil
        recoveryUnconfirmed = process.terminationReason != .exit || process.terminationStatus != 0
        if !recoveryUnconfirmed { recoveryTarget = nil }
    }

    func start(duration: Double) -> Bool {
        refreshCompletion()
        guard !running else { lastError = "已有双外屏会话正在运行"; return false }
        guard !recoveryUnconfirmed else { lastError = "内屏恢复尚未确认，请先点击恢复内建显示器"; return false }
        guard lidClosed() == false, externalCount() > 0, let originalID = builtinID(),
              CGDisplayIsActive(originalID) != 0, !hasMirroring() else {
            lastError = "需要开盖、可用的内屏和至少一台处于扩展模式的外屏"; return false
        }
        // Keep a recovery target in the owner even if the guardian later exits
        // unsuccessfully. Display routing may change the current CG display ID.
        let identified = boundedRun(driverHelper, ["identify"])
        guard identified.0 == 0, let data = identified.1.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let registryID = record["registryID"] as? NSNumber else {
            lastError = "未找到可控制的内建显示通道"; return false
        }
        recoveryTarget = (registryID.stringValue, originalID)
        let process = Process(), heartbeat = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--routing-guard", String(duration)]
        process.standardInput = heartbeat; process.standardOutput = output
        do { try process.run() } catch {
            recoveryTarget = nil; lastError = error.localizedDescription; return false
        }
        child = process; input = heartbeat
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        var response = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while ProcessInfo.processInfo.systemUptime < deadline {
            beat()
            var bytes = [UInt8](repeating: 0, count: 1024)
            let n = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if n > 0 { response.append(contentsOf: bytes.prefix(n)) }
            if response.contains(10) || !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let message = String(data: response, encoding: .utf8) ?? ""
        guard message.hasPrefix("READY\n") else {
            lastError = message.hasPrefix("FAILED:") ? String(message.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) : "切换未完成，已请求恢复内屏"
            _ = stop(); return false
        }
        return true
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
        // The guardian is reaped before a retry, so no late close can overwrite
        // this recovery. Preserve the target when either step is unconfirmed.
        let opened = boundedRun(driverHelper, ["open", target.registryID]).0 == 0
        _ = boundedRun(helper, ["on", "--commit", "session", "--display-id", String(target.displayID)])
        Thread.sleep(forTimeInterval: 0.5)
        let restored = opened && builtinRestored()
        recoveryUnconfirmed = !restored
        if restored { recoveryTarget = nil }
        return restored
    }
}
