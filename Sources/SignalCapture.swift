import Foundation
import AppKit
import CoreGraphics
import Darwin

// In-memory, read-only capture. Lifecycle methods are called on the main thread;
// subprocess sampling and report encoding never block the AppKit event loop.
final class SignalCapture {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumSamples = 100
    private static let maximumEvents = 1_000
    private static let maximumEventBytes = 256 * 1024
    private static let maximumOutputBytes = 512 * 1024
    private static let clockScale: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
    private static func now() -> Double { Double(mach_continuous_time()) * clockScale }
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private let queue = DispatchQueue(label: "OpenClam.signal-capture", qos: .utility)
    private let lock = NSLock()
    private let helperURL: URL
    private let observeSystemEvents: Bool
    private let sampleInterval: Double
    private var running = false
    private var stopRequested = false
    private var acceptingEvents = false
    private var startTick: Double?
    private var startedAt = ""
    private var duration = 180.0
    private var samples: [[String: Any]] = []
    private var sampleBytes = 0
    private var events: [[String: Any]] = []
    private var eventBytes = 0
    private var droppedEvents = 0
    private var finalizedData: Data?
    private var completionHandlers: [() -> Void] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var displayObserverRegistered = false

    // Injecting the helper and a shorter interval is only for process/limit
    // tests. The app uses the default two-second interval and bundled helper.
    init(helperURL: URL? = nil, observeSystemEvents: Bool = true, sampleInterval: Double = 2) {
        self.helperURL = helperURL ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("display-link")
        self.observeSystemEvents = observeSystemEvents
        self.sampleInterval = sampleInterval.isFinite ? min(2, max(0.01, sampleInterval)) : 2
    }

    var isRunning: Bool { lock.withLock { running } }
    // This also enables "stop and save" while sampling. reportData remains nil
    // until the child is reaped and the final routing report has been captured.
    var hasReport: Bool { lock.withLock { startTick != nil } }
    var started: Bool { hasReport }
    var statusText: String {
        lock.withLock {
            if running && stopRequested { return "正在结束采样" }
            if running { return "正在采样（\(samples.count) 份记录）" }
            if finalizedData != nil { return "采样已完成（\(samples.count) 份记录）" }
            return "尚未开始采样"
        }
    }

    @discardableResult func start(duration requestedDuration: Double = 180) -> Bool {
        precondition(Thread.isMainThread)
        let began = Self.now(), wall = Self.timestamp()
        let accepted = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true; stopRequested = false; acceptingEvents = true
            startTick = began; startedAt = wall
            duration = requestedDuration.isFinite ? min(180, max(0.1, requestedDuration)) : 180
            samples = []; sampleBytes = 0; events = []; eventBytes = 0; droppedEvents = 0
            finalizedData = nil; completionHandlers = []
            return true
        }
        guard accepted else { return false }
        recordEvent("capture_started", fields: [:], tick: began, wall: wall)
        if observeSystemEvents {
            let result = SignalCaptureDisplayObservers.add(self)
            displayObserverRegistered = result == .success
            recordEvent("display_callback_registration", fields: ["return": result.rawValue])
            let center = NSWorkspace.shared.notificationCenter
            let notifications: [(Notification.Name, String)] = [
                (NSWorkspace.willSleepNotification, "system_will_sleep"),
                (NSWorkspace.didWakeNotification, "system_did_wake"),
                (NSWorkspace.screensDidSleepNotification, "screens_did_sleep"),
                (NSWorkspace.screensDidWakeNotification, "screens_did_wake")
            ]
            notificationTokens = notifications.map { name, kind in
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.recordEvent(kind, fields: [:])
                }
            }
        }
        queue.async { [self] in runCapture() }
        return true
    }

    func stop(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        let action = lock.withLock { () -> Int in
            if running {
                stopRequested = true
                if let completion { completionHandlers.append(completion) }
                return 1
            }
            if finalizedData != nil, let completion {
                running = true; stopRequested = true
                completionHandlers.append(completion)
                return 2
            }
            return 0
        }
        if action == 1 { recordEvent("stop_requested", fields: [:]) }
        else if action == 2 { refreshForExport() }
        else if let completion { DispatchQueue.main.async(execute: completion) }
    }

    func mark(_ label: String) {
        precondition(Thread.isMainThread)
        // Labels originate from app actions, not arbitrary helper output.
        recordEvent("marker", fields: ["label": String(label.prefix(64))])
    }

    func reportData() -> Data? { lock.withLock { finalizedData } }

    fileprivate func displayChanged(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        recordEvent("display_reconfiguration", fields: ["displayID": display, "flags": flags.rawValue])
    }

    private func recordEvent(_ kind: String, fields: [String: Any], tick: Double? = nil, wall: String? = nil) {
        // Timestamp before taking the lock, on the callback's receiving thread.
        let received = tick ?? Self.now(), receivedWall = wall ?? Self.timestamp()
        lock.withLock {
            guard acceptingEvents, let began = startTick else { return }
            var event = fields
            event["kind"] = kind; event["elapsedSeconds"] = max(0, received - began); event["wallTime"] = receivedWall
            guard let data = try? JSONSerialization.data(withJSONObject: event),
                  events.count < Self.maximumEvents, eventBytes + data.count <= Self.maximumEventBytes else {
                droppedEvents += 1; return
            }
            events.append(event); eventBytes += data.count
        }
    }

    private func shouldStop() -> Bool { lock.withLock { stopRequested } }

    // Reuse the existing bounded/sanitized report, including its app/OS/model
    // metadata. An empty currentLinks input guarantees metadata without logs.
    private func routingReport() -> [String: Any] {
        guard let data = RoutingDiagnostics.latestReport(currentLinkData: Data("{}".utf8)),
              var report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["unavailable": true]
        }
        report.removeValue(forKey: "currentLinks")
        return report
    }

    private func runCapture() {
        let parameters = lock.withLock { (startTick!, duration) }
        let began = parameters.0, deadline = began + parameters.1
        let before = routingReport()
        let beforeSize = (try? JSONSerialization.data(withJSONObject: before).count) ?? 0
        // Reserve the existing report's maximum 2 MiB for the final context,
        // plus bounded events and ample envelope/sample-metadata space.
        let payloadBudget = Self.maximumBytes - beforeSize - 2 * 1024 * 1024 - Self.maximumEventBytes - 128 * 1024
        var nextSample = began
        var reason = "duration_elapsed"
        while Self.now() < deadline {
            if shouldStop() { reason = "stopped_by_user"; break }
            if lock.withLock({ samples.count >= Self.maximumSamples }) { reason = "sample_limit"; break }
            if Self.now() < nextSample {
                Thread.sleep(forTimeInterval: min(0.05, max(0, nextSample - Self.now())))
                continue
            }
            var sample = runSample(started: began, scheduled: nextSample, captureDeadline: deadline)
            nextSample = (sample["startedElapsedSeconds"] as? Double ?? (Self.now() - began)) + began + sampleInterval
            let exceeded = lock.withLock { () -> Bool in
                sample["index"] = samples.count
                let encodedSize = (try? JSONSerialization.data(withJSONObject: sample).count) ?? 0
                let limit = sampleBytes + encodedSize > payloadBudget
                if limit {
                    sample.removeValue(forKey: "links")
                    sample["payloadOmitted"] = "capture_byte_limit"
                }
                sampleBytes += (try? JSONSerialization.data(withJSONObject: sample).count) ?? 0
                samples.append(sample)
                return limit
            }
            if exceeded { reason = "capture_byte_limit"; break }
        }
        if shouldStop() { reason = "stopped_by_user" }
        lock.withLock { stopRequested = true }
        let after = routingReport()
        let afterCapturedAt = Self.timestamp()
        // Observer removal belongs to the main thread. Do not main.sync: callers
        // run their event loop while the asynchronous stop is finishing.
        DispatchQueue.main.async { [self] in
            if displayObserverRegistered { SignalCaptureDisplayObservers.remove(self); displayObserverRegistered = false }
            for token in notificationTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            notificationTokens.removeAll()
            let finished = Self.now(), wall = Self.timestamp()
            recordEvent("capture_finished", fields: ["reason": reason], tick: finished, wall: wall)
            lock.withLock { acceptingEvents = false }
            queue.async { [self] in
                let report: [String: Any] = lock.withLock {
                    ["format": "openclam-signal-capture", "schemaVersion": 1,
                     "startedAt": startedAt, "finishedAt": wall, "elapsedSeconds": max(0, finished - began),
                     "monotonicClock": "mach_continuous_time_includes_sleep",
                     "requestedDurationSeconds": parameters.1, "nominalIntervalSeconds": sampleInterval,
                     "samplingSchedule": "query_starts_at_least_one_interval_apart_without_overlap",
                     "finishReason": reason, "maximumSamples": Self.maximumSamples,
                     "maximumReportBytes": Self.maximumBytes, "droppedEvents": droppedEvents,
                     "metadata": before["metadata"] ?? after["metadata"] ?? [:],
                     "routingBefore": before, "routingAfter": after, "routingAfterCapturedAt": afterCapturedAt,
                     "samples": samples, "events": events]
                }
                let finalData = encodeBounded(report)
                DispatchQueue.main.async { [self] in
                    let exportRequested = lock.withLock { () -> Bool in
                        finalizedData = finalData
                        return !completionHandlers.isEmpty
                    }
                    if exportRequested { refreshForExport() }
                    else { complete(with: finalData) }
                }
            }
        }
    }

    private func encodeBounded(_ original: [String: Any]) -> Data? {
        var report = original
        var data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
        // Keep every outcome if final routing context consumes the reserved
        // budget. The same bound applies when refreshing a completed capture.
        if data == nil || data!.count > Self.maximumBytes {
            report["samples"] = (report["samples"] as? [[String: Any]] ?? []).map { record -> [String: Any] in
                var reduced = record; reduced.removeValue(forKey: "links")
                reduced["payloadOmitted"] = "report_byte_limit"; return reduced
            }
            data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
        }
        return data.flatMap { $0.count <= Self.maximumBytes ? $0 : nil }
    }

    // A confirmation dialog can outlive the capture's time limit. Refresh the
    // final routing context at save time so its feedback/recovery is retained,
    // while finishedAt and the sampling timeline remain unchanged.
    private func refreshForExport() {
        precondition(Thread.isMainThread)
        let previous = lock.withLock { finalizedData }
        queue.async { [self] in
            var updated = previous
            if let previous,
               var report = (try? JSONSerialization.jsonObject(with: previous)) as? [String: Any] {
                report["routingAfter"] = routingReport()
                report["routingAfterCapturedAt"] = Self.timestamp()
                report["exportedAt"] = Self.timestamp()
                updated = encodeBounded(report)
            }
            let finalData = updated
            DispatchQueue.main.async { [self] in complete(with: finalData) }
        }
    }

    private func complete(with data: Data?) {
        precondition(Thread.isMainThread)
        let completions = lock.withLock { () -> [() -> Void] in
            finalizedData = data; running = false
            let pending = completionHandlers; completionHandlers = []; return pending
        }
        completions.forEach { $0() }
    }

    private func runSample(started began: Double, scheduled: Double, captureDeadline: Double) -> [String: Any] {
        let process = Process(), output = Pipe()
        process.executableURL = helperURL; process.arguments = ["--extended"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let tick = Self.now(), wall = Self.timestamp()
        var sample: [String: Any] = ["startedAt": wall, "scheduledElapsedSeconds": max(0, scheduled - began),
            "startedElapsedSeconds": max(0, tick - began), "timedOut": false, "stoppedEarly": false]
        do { try process.run() }
        catch {
            sample["result"] = "launch_failed" // Do not export error text or executable paths.
            sample["exitStatus"] = NSNull(); sample["terminationReason"] = "not_started"
            sample["finishedAt"] = Self.timestamp(); sample["finishedElapsedSeconds"] = Self.now() - began
            sample["queryDurationSeconds"] = Self.now() - tick
            return sample
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        let nonblocking = flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        var bytes = Data(), totalBytes = 0, overflow = false, readFailed = !nonblocking
        var terminatedAt: Double?
        var timedOut = false, stopped = false, killed = false
        func drain(maximumToRead: Int = 64 * 8192) {
            guard nonblocking && !overflow else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound each drain pass as well as stored data; a noisy process
            // must not prevent deadline checks while its pipe stays writable.
            var remaining = maximumToRead
            while remaining > 0 {
                let count = read(descriptor, &buffer, min(buffer.count, remaining))
                if count > 0 {
                    totalBytes += count; remaining -= count
                    if bytes.count + count <= Self.maximumOutputBytes && !overflow { bytes.append(contentsOf: buffer.prefix(count)) }
                    else { overflow = true; break }
                } else if count < 0 && errno == EINTR { continue }
                else { if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK { readFailed = true }; break }
            }
        }
        while process.isRunning {
            drain()
            let current = Self.now()
            if terminatedAt == nil {
                timedOut = current - tick >= 6
                stopped = shouldStop() || current >= captureDeadline
                if timedOut || stopped || overflow || readFailed {
                    process.terminate(); terminatedAt = current
                }
            } else if current - terminatedAt! >= 0.2 && process.isRunning && !killed {
                // Only this Process's PID is signalled, never an app name,
                // process group or a separately running display-link instance.
                _ = kill(process.processIdentifier, SIGKILL)
                killed = true
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        // A fast child may exit before the first poll. Probe one byte beyond
        // the limit so an exactly full first drain cannot hide extra output.
        drain(maximumToRead: Self.maximumOutputBytes + 1)
        try? output.fileHandleForReading.close()
        let finished = Self.now()
        sample["finishedAt"] = Self.timestamp(); sample["finishedElapsedSeconds"] = max(0, finished - began)
        sample["queryDurationSeconds"] = max(0, finished - tick); sample["stdoutBytes"] = totalBytes
        sample["exitStatus"] = process.terminationStatus
        sample["terminationReason"] = process.terminationReason == .exit ? "exit" : "signal"
        sample["timedOut"] = timedOut || (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGALRM)
        sample["stoppedEarly"] = stopped
        var result = timedOut ? "parent_timeout" : (stopped ? "capture_stopped" : "helper_failed")
        if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGALRM { result = "helper_timeout" }
        if overflow { result = "output_limit" }
        else if readFailed { result = "output_read_failed" }
        else if let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                object["extendedSchemaVersion"] as? Int == 1,
                object["displays"] is [Any], object["framebuffers"] is [Any], object["ports"] is [Any] {
            // Only the expected helper schema is accepted; reuse the existing
            // sanitizer for identity/path filtering and depth/array bounds.
            if let report = RoutingDiagnostics.latestReport(currentLinkData: bytes),
               let sanitized = (try? JSONSerialization.jsonObject(with: report)) as? [String: Any],
               let links = sanitized["currentLinks"] as? [String: Any] {
                sample["links"] = links
                if !timedOut && !stopped && process.terminationReason == .exit && process.terminationStatus == 0 { result = "sampled" }
            } else { result = "sanitized_payload_unavailable" }
        } else if !timedOut && !stopped && process.terminationReason == .exit && process.terminationStatus == 0 {
            result = "invalid_helper_json"
        }
        sample["result"] = result
        return sample
    }
}

// No unretained context pointer crosses the C callback boundary. Each callback
// takes strong snapshots of weak listeners, so removal/deallocation cannot leave
// a queued callback dereferencing the previous capture's memory.
private enum SignalCaptureDisplayObservers {
    private final class WeakCapture { weak var value: SignalCapture?; init(_ value: SignalCapture) { self.value = value } }
    private static let lock = NSLock()
    private static var listeners: [ObjectIdentifier: WeakCapture] = [:]
    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, _ in
        let captures = lock.withLock { listeners.values.compactMap { $0.value } }
        captures.forEach { $0.displayChanged(display, flags: flags) }
    }
    static func add(_ capture: SignalCapture) -> CGError {
        precondition(Thread.isMainThread)
        if lock.withLock({ listeners.isEmpty }) {
            let result = CGDisplayRegisterReconfigurationCallback(callback, nil)
            guard result == .success else { return result }
        }
        lock.withLock { listeners[ObjectIdentifier(capture)] = WeakCapture(capture) }
        return .success
    }
    static func remove(_ capture: SignalCapture) {
        precondition(Thread.isMainThread)
        let empty = lock.withLock { listeners.removeValue(forKey: ObjectIdentifier(capture)); return listeners.isEmpty }
        if empty { CGDisplayRemoveReconfigurationCallback(callback, nil) }
    }
}
