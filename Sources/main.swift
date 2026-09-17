import AppKit
import CoreGraphics
import IOKit
import IOKit.hid
import Darwin

// Display switching signatures/implementation live in the MIT-licensed helper.
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let helper = executable.deletingLastPathComponent().appendingPathComponent("display-helper")

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
}

func registry(_ name: String, keys: [String]) -> [String: Any] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
    guard service != 0 else { return [:] }
    defer { IOObjectRelease(service) }
    var result: [String: Any] = [:]
    for key in keys {
        if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            result[key] = value
        }
    }
    return result
}

func lidClosed() -> Bool? {
    registry("IOPMrootDomain", keys: ["AppleClamshellState"])["AppleClamshellState"] as? Bool
}

func displays() -> (CGError, [CGDirectDisplayID]) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    let error = CGGetOnlineDisplayList(32, &ids, &count)
    return (error, Array(ids.prefix(Int(count))))
}

func externalCount() -> Int {
    let (error, ids) = displays()
    guard error == .success else { return 0 } // Unreadable topology fails toward restore.
    return ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }.count
}

func builtinID() -> CGDirectDisplayID? { displays().1.first { CGDisplayIsBuiltin($0) != 0 } }

func hasMirroring() -> Bool { displays().1.contains { CGDisplayIsInMirrorSet($0) != 0 } }

func sensor() -> [String: Any] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [kIOHIDVendorIDKey: 0x05ac, kIOHIDProductIDKey: 0x8104,
        kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8a]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let managerResult = IOHIDManagerOpen(manager, 0)
    defer { IOHIDManagerClose(manager, 0) }
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
        return ["available": false, "managerReturn": managerResult]
    }
    var result: [String: Any] = ["available": true, "managerReturn": managerResult]
    if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
        result["reportDescriptorHex"] = descriptor.map { String(format: "%02x", $0) }.joined()
    }
    let openResult = IOHIDDeviceOpen(device, 0)
    result["openReturn"] = openResult
    guard openResult == kIOReturnSuccess else { return result }
    defer { IOHIDDeviceClose(device, 0) }
    var bytes = [UInt8](repeating: 0, count: 8)
    var length = bytes.count
    let readResult = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
    result["readReturn"] = readResult
    if readResult == kIOReturnSuccess {
        result["reportHex"] = bytes.prefix(length).map { String(format: "%02x", $0) }.joined()
        if length >= 3 && bytes[0] == 1 {
            // Experimental report interpretation. Preserve raw bytes for other models.
            result["rawAngleDegrees"] = Int(bytes[1]) | (Int(bytes[2]) << 8)
        }
    }
    return result
}

func snapshot() -> [String: Any] {
    let (error, ids) = displays()
    return ["timestamp": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "clamshell": registry("IOPMrootDomain", keys: ["AppleClamshellState", "AppleClamshellCausesSleep"]),
        "sensor": sensor(), "displayQueryReturn": error.rawValue,
        "displays": ids.map { id -> [String: Any] in
            let bounds = CGDisplayBounds(id)
            return ["id": id, "builtin": CGDisplayIsBuiltin(id) != 0,
                "active": CGDisplayIsActive(id) != 0, "asleep": CGDisplayIsAsleep(id) != 0,
                "mirrored": CGDisplayIsInMirrorSet(id) != 0,
                "width": bounds.width, "height": bounds.height, "x": bounds.origin.x, "y": bounds.origin.y]
        }, "activeExternalCount": externalCount()]
}

@discardableResult func runHelper(_ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = helper
    process.arguments = args
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
    catch { fputs("Helper failed: \(error)\n", stderr); return 2 }
}

func restore(_ id: CGDirectDisplayID) -> Bool {
    let status = runHelper(["on", "--commit", "session", "--display-id", String(id)])
    Thread.sleep(forTimeInterval: 0.5)
    return status == 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
}

// Guardian receives a heartbeat on stdin, independent of the menu bar process.
// EOF, a missing heartbeat, loss of all external displays, or a trial deadline
// triggers restoration. It never sends fake sensor reports or changes pmset.
func recoveryReason(externals: Int, eof: Bool, readError: Bool, age: Double,
                    elapsed: Double, duration: Double) -> String? {
    if externals == 0 { return "no_external_display" }
    if eof { return "owner_exited" }
    if readError { return "heartbeat_error" }
    if age > 12 { return "heartbeat_expired" }
    if duration > 0 && elapsed >= duration { return "trial_expired" }
    return nil
}

func guardian(_ id: CGDirectDisplayID, duration: Double) -> Never {
    _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
    print("READY"); fflush(stdout)
    // Readiness alone uses the owner's pipe. Subsequent evidence must survive
    // owner death; stderr is inherited directly, not relayed by the owner.
    _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    let start = ProcessInfo.processInfo.systemUptime
    var lastBeat = start
    var reason = ""
    while true {
        let now = ProcessInfo.processInfo.systemUptime
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count > 0 { lastBeat = now }
        let readFailed = count < 0 && errno != EAGAIN && errno != EINTR
        if let next = recoveryReason(externals: externalCount(), eof: count == 0, readError: readFailed,
                                     age: now - lastBeat, elapsed: now - start, duration: duration) { reason = next }
        if !reason.isEmpty {
            // Real clamshell use is distinct: wait for actual lid opening rather
            // than repeatedly fighting macOS while the user has closed the lid.
            if lidClosed() == true { Thread.sleep(forTimeInterval: 0.5); continue }
            var success = false
            for _ in 0..<3 {
                success = restore(id)
                if success { break }
                Thread.sleep(forTimeInterval: 1)
            }
            emit(["guardianRestore": success, "reason": reason])
            exit(success ? 0 : 3)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

final class Session {
    var process: Process?
    var input: Pipe?
    var id: CGDirectDisplayID?
    var lastError = ""
    var running: Bool { process?.isRunning == true }

    func start(duration: Double) -> Bool {
        guard !running else { lastError = "已有关闭会话正在运行"; return false }
        guard lidClosed() == false, externalCount() > 0, let display = builtinID(), CGDisplayIsActive(display) != 0 else {
            lastError = "需要开盖、可用的内屏和至少一台正在显示的外屏"; return false
        }
        // The upstream off command clears mirroring. Do not change the user's
        // mirror configuration implicitly; this prototype accepts extended mode.
        guard !hasMirroring() else { lastError = "请先将显示器设置为扩展模式"; return false }
        let child = Process(), pipe = Pipe(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["--guard", String(display), String(duration)]
        child.standardInput = pipe
        child.standardOutput = output
        do { try child.run() } catch { lastError = error.localizedDescription; return false }
        // Child emits readiness before any display mutation; keep draining its
        // later output so helper logging cannot block restoration.
        let ready = output.fileHandleForReading.availableData
        guard String(data: ready, encoding: .utf8)?.contains("READY") == true else {
            pipe.fileHandleForWriting.closeFile(); lastError = "恢复守护进程未就绪"; return false
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { FileHandle.standardError.write(data) }
        }
        process = child; input = pipe; id = display
        beat()
        guard runHelper(["off", "--commit", "session"]) == 0 else {
            lastError = "显示切换失败，已请求恢复"; _ = stop(); return false
        }
        guard CGDisplayIsActive(display) == 0 && externalCount() > 0 else {
            lastError = "内屏未退出桌面或外屏不可用，已请求恢复"; _ = stop(); return false
        }
        return true
    }

    func beat() {
        guard running, let pipe = input else { return }
        try? pipe.fileHandleForWriting.write(contentsOf: Data([1]))
    }

    @discardableResult func stop() -> Bool {
        guard let display = id else { return true }
        input?.fileHandleForWriting.closeFile(); input = nil
        // Closing the pipe makes the independent guardian restore. Wait only
        // while physically open; a real closed lid defers restoration to opening.
        if lidClosed() != true {
            process?.waitUntilExit()
            let success = CGDisplayIsActive(display) != 0 && CGDisplayIsAsleep(display) == 0
            process = nil; id = nil
            return success
        }
        return false
    }
}

final class App: NSObject, NSApplicationDelegate {
    let session = Session()
    var item: NSStatusItem!
    var status: NSMenuItem!
    var enable: NSMenuItem!
    var disable: NSMenuItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "OpenClam"
        let menu = NSMenu()
        status = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        enable = menu.addItem(withTitle: "关闭内屏，保留外屏", action: #selector(turnOff), keyEquivalent: "")
        disable = menu.addItem(withTitle: "恢复内建显示器", action: #selector(turnOn), keyEquivalent: "")
        menu.addItem(withTitle: "测试关闭 10 秒后恢复", action: #selector(trial), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出并恢复内屏", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        menu.autoenablesItems = false
        item.menu = menu
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }
    func tick() {
        session.beat()
        let count = externalCount()
        let off = session.running
        status.title = "外屏 \(count) 台 · \(off ? "内屏关闭会话中" : "未启用")"
        enable.isEnabled = !off && count > 0
        disable.isEnabled = off || builtinID().map { CGDisplayIsAsleep($0) != 0 } == true
    }
    func begin(_ seconds: Double) {
        if !session.start(duration: seconds) {
            let alert = NSAlert(); alert.messageText = "暂时无法关闭内屏"
            alert.informativeText = session.lastError; alert.runModal()
        }
        tick()
    }
    @objc func turnOff() { begin(0) }
    @objc func trial() { begin(10) }
    @objc func turnOn() {
        if !session.stop() {
            let alert = NSAlert(); alert.messageText = "内屏恢复尚未确认"
            alert.informativeText = "请打开笔记本盖子；若仍未恢复，可重新连接外屏或合盖后重新打开。"
            alert.runModal()
        }
        tick()
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { _ = session.stop() }
}

signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
if args == ["self-test"] {
    // Recovery must depend on availability, not on the original external count.
    let cases: [(Int, Bool, Bool, Double, Double, Double, String?)] = [
        (2, false, false, 0, 0, 0, nil),
        (1, false, false, 0, 20, 0, nil),
        (0, false, false, 0, 1, 0, "no_external_display"),
        (2, true, false, 0, 1, 0, "owner_exited"),
        (2, false, true, 0, 1, 0, "heartbeat_error"),
        (2, false, false, 13, 13, 0, "heartbeat_expired"),
        (2, false, false, 0, 10, 10, "trial_expired"),
        (2, false, false, 0, 9, 10, nil)
    ]
    for (index, c) in cases.enumerated() {
        let actual = recoveryReason(externals: c.0, eof: c.1, readError: c.2, age: c.3, elapsed: c.4, duration: c.5)
        guard actual == c.6 else { fputs("Recovery policy failed case \(index)\n", stderr); exit(1) }
    }
    emit(["recoveryPolicyCasesPassed": cases.count])
} else if args.first == "--guard", args.count == 3, let id = UInt32(args[1]), let seconds = Double(args[2]) {
    guardian(id, duration: seconds)
} else if args == ["status"] {
    emit(snapshot())
} else if args == ["probe-open"] {
    guard lidClosed() == false else { fputs("Refusing: physical lid is not confirmed open\n", stderr); exit(2) }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { exit(2) }
    let result = IORegistryEntrySetCFProperty(service, "IOPMTestClamshellOpen" as CFString, kCFBooleanTrue)
    IOObjectRelease(service)
    emit(["operation": "IOPMTestClamshellOpen", "returnCode": result,
          "hex": String(format: "0x%08x", UInt32(bitPattern: result)),
          "interpretation": "Same-state probe only; success does not prove close-event support",
          "after": snapshot()])
} else if args.first == "trial", args.count == 2, let seconds = Double(args[1]), seconds >= 5, seconds <= 60 {
    let session = Session()
    emit(["phase": "before", "snapshot": snapshot()])
    guard session.start(duration: seconds) else { fputs("\(session.lastError)\n", stderr); exit(2) }
    emit(["phase": "off", "snapshot": snapshot()])
    _ = runHelper(["status"])
    while session.running { session.beat(); Thread.sleep(forTimeInterval: 0.5) }
    let ok = session.stop()
    emit(["phase": "restored", "verifiedLayoutAndWake": ok, "snapshot": snapshot()])
    exit(ok ? 0 : 3)
} else if args.first == "observe", args.count == 2, let seconds = Int(args[1]), (1...3600).contains(seconds) {
    for _ in 0..<seconds { emit(snapshot()); Thread.sleep(forTimeInterval: 1) }
} else if args.isEmpty {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.run()
} else {
    fputs("Usage: OpenClam [status | observe SECONDS | trial 5..60 | probe-open]\n", stderr)
    exit(2)
}
