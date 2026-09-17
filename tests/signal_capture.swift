// Runs only a compiled fake helper; never queries or changes real displays.
import Foundation
import Darwin

@main struct SignalCaptureTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func wait(until condition: () -> Bool, timeout: Double) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        require(condition(), "Timed out waiting for fake-helper lifecycle")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root.appendingPathComponent(".tmp/signal-capture-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldDirectory = ProcessInfo.processInfo.environment["OPENCLAM_DIAGNOSTICS_DIR"]
        setenv("OPENCLAM_DIAGNOSTICS_DIR", folder.appendingPathComponent("logs").path, 1)
        let pidFile = folder.appendingPathComponent("helper.pid")
        setenv("OPENCLAM_CAPTURE_TEST_PID_FILE", pidFile.path, 1)
        defer {
            if let oldDirectory { setenv("OPENCLAM_DIAGNOSTICS_DIR", oldDirectory, 1) }
            else { unsetenv("OPENCLAM_DIAGNOSTICS_DIR") }
            unsetenv("OPENCLAM_CAPTURE_TEST_PID_FILE")
        }
        let source = folder.appendingPathComponent("fake.c")
        let fake = folder.appendingPathComponent("success-helper")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <signal.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc != 2 || strcmp(argv[1], "--extended")) return 7;
            FILE *p = fopen(getenv("OPENCLAM_CAPTURE_TEST_PID_FILE"), "w");
            if (p) { fprintf(p, "%d", getpid()); fclose(p); }
            const char *name = strrchr(argv[0], '/'); name = name ? name + 1 : argv[0];
            if (strstr(name, "slow")) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
            fputs("UNKNOWN_STDERR_SECRET /Users/fake/private\n", stderr);
            if (strstr(name, "invalid")) { puts("UNKNOWN_STDOUT_SECRET"); return 0; }
            if (strstr(name, "overflow")) { for (int i=0;i<700000;i++) putchar('x'); return 0; }
            fputs("{\"extendedSchemaVersion\":1,\"displays\":[],\"framebuffers\":[],\"serialNumber\":\"REDACT_THIS\",\"ports\":[", stdout);
            if (strstr(name, "large")) {
                for (int i=0;i<90;i++) {
                    if (i) putchar(',');
                    printf("{\"index\":%d,\"history\":\"",i);
                    for (int j=0;j<1000;j++) putchar(j%2 ? ' ' : 'x');
                    fputs("\"}",stdout);
                }
            }
            puts("]}");
            return strstr(name, "failed") ? 3 : 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-O2", "-Wall", "-Wextra", "-Werror", source.path, "-o", fake.path]
        try compiler.run(); compiler.waitUntilExit()
        require(compiler.terminationStatus == 0, "Fake helper did not compile")
        for name in ["failed", "invalid", "slow", "large", "overflow"] {
            try FileManager.default.copyItem(at: fake, to: folder.appendingPathComponent(name + "-helper"))
        }
        func capture(_ name: String, duration: Double, interval: Double = 0.01) -> SignalCapture {
            let value = SignalCapture(helperURL: folder.appendingPathComponent(name + "-helper"),
                                      observeSystemEvents: false, sampleInterval: interval)
            require(!value.started && !value.hasReport, "Fresh capture has no report")
            require(value.start(duration: duration), "Start failed")
            require(value.isRunning && value.hasReport && value.started && value.reportData() == nil,
                    "Running capture must enable stop/save but not export an unfinished report")
            return value
        }
        func report(_ capture: SignalCapture, timeout: Double = 15) throws -> [String: Any] {
            wait(until: { !capture.isRunning }, timeout: timeout)
            let data = capture.reportData()!
            require(data.count <= 8 * 1024 * 1024, "Report exceeded byte limit")
            let text = String(decoding: data, as: UTF8.self)
            require(!text.contains("UNKNOWN_STDERR_SECRET") && !text.contains("UNKNOWN_STDOUT_SECRET") &&
                    !text.contains("REDACT_THIS"), "Unknown output or sensitive fields escaped filtering")
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func samples(_ report: [String: Any]) -> [[String: Any]] { report["samples"] as! [[String: Any]] }

        let success = capture("success", duration: 1)
        let successReport = try report(success)
        require(samples(successReport).contains { $0["result"] as? String == "sampled" }, "No successful sample")
        require(successReport["routingBefore"] != nil && successReport["routingAfter"] != nil,
                "Missing before/after routing context")
        require(samples(successReport).allSatisfy { $0["queryDurationSeconds"] != nil && $0["startedAt"] != nil },
                "Missing query timing")
        let lateDiagnostics = try RoutingDiagnostics.begin()
        lateDiagnostics.append(event: ["event": "late_visual_feedback", "result": "no_signal"])
        var refreshed = false
        let refreshStarted = ProcessInfo.processInfo.systemUptime
        success.stop {
            require(Thread.isMainThread, "Export refresh completion is not on main thread")
            refreshed = true
        }
        require(ProcessInfo.processInfo.systemUptime - refreshStarted < 0.1 && success.isRunning,
                "Refreshing an automatically completed capture blocked main")
        let refreshedReport = try report(success)
        let latestContext = String(decoding: try JSONSerialization.data(withJSONObject: refreshedReport["routingAfter"]!), as: UTF8.self)
        require(refreshed && latestContext.contains("late_visual_feedback") &&
                refreshedReport["finishedAt"] as? String == successReport["finishedAt"] as? String &&
                refreshedReport["exportedAt"] != nil && refreshedReport["routingAfterCapturedAt"] != nil,
                "Save must include late feedback without extending the sampling timeline")

        let failureReport = try report(capture("failed", duration: 1))
        require(samples(failureReport).contains { ($0["exitStatus"] as? Int) == 3 && $0["links"] != nil },
                "A failed helper must retain its allowlisted partial evidence")
        let invalidReport = try report(capture("invalid", duration: 1))
        require(samples(invalidReport).contains { $0["result"] as? String == "invalid_helper_json" }, "Invalid output not recorded")
        let overflowReport = try report(capture("overflow", duration: 2))
        require(samples(overflowReport).contains { $0["result"] as? String == "output_limit" }, "Output bound not enforced")

        try? FileManager.default.removeItem(at: pidFile)
        let stopped = capture("slow", duration: 30)
        wait(until: { FileManager.default.fileExists(atPath: pidFile.path) }, timeout: 2)
        let child = pid_t(try String(contentsOf: pidFile, encoding: .utf8))!
        var callbackRan = false
        let stopStarted = ProcessInfo.processInfo.systemUptime
        stopped.stop {
            require(Thread.isMainThread, "Stop completion is not on main thread")
            require(kill(child, 0) != 0 && errno == ESRCH, "Completion ran before child was reaped")
            callbackRan = true
        }
        require(ProcessInfo.processInfo.systemUptime - stopStarted < 0.1 && stopped.statusText == "正在结束采样", "Stop blocked main")
        let stoppedReport = try report(stopped)
        require(callbackRan && samples(stoppedReport).contains { $0["stoppedEarly"] as? Bool == true } &&
                stoppedReport["exportedAt"] != nil, "Stop outcome or export refresh missing")

        let timeoutReport = try report(capture("slow", duration: 7))
        require(samples(timeoutReport).contains { $0["result"] as? String == "parent_timeout" && $0["timedOut"] as? Bool == true },
                "Six-second parent deadline not enforced")

        let boundedEvents = capture("success", duration: 0.3)
        for i in 0..<5_000 { boundedEvents.mark("step \(i)") }
        let eventReport = try report(boundedEvents)
        require((eventReport["events"] as! [Any]).count <= 1_000 && (eventReport["droppedEvents"] as! Int) > 0,
                "Event limit not enforced")
        let countReport = try report(capture("success", duration: 60), timeout: 75)
        require(samples(countReport).count == 100 && countReport["finishReason"] as? String == "sample_limit", "Sample limit not enforced")
        let byteReport = try report(capture("large", duration: 60), timeout: 75)
        require(byteReport["finishReason"] as? String == "capture_byte_limit" && samples(byteReport).last?["payloadOmitted"] != nil,
                "Byte limit must retain the final sample's outcome")
        print("PASS: signal capture success, late-feedback export refresh, partial failure, invalid/oversized output, asynchronous stop and child reap, timeout, event/sample/byte bounds; no display operations")
    }
}
