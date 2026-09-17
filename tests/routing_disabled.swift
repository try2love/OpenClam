// Compile with Sources/Routing.swift only. Every display/logging dependency is
// a tripwire, so a rejected start must not query displays or launch a helper.
import Foundation
import CoreGraphics
import Darwin

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let helper = executable.deletingLastPathComponent().appendingPathComponent("never-run-display-helper")

private func unexpected<T>(_ operation: String) -> T {
    fputs("Unexpected operation before experimental rejection: \(operation)\n", stderr)
    exit(99)
}
func displays() -> (CGError, [CGDirectDisplayID]) { unexpected("displays") }
func lidClosed() -> Bool? { unexpected("lidClosed") }
func externalCount() -> Int { unexpected("externalCount") }
func builtinID() -> CGDirectDisplayID? { unexpected("builtinID") }
func hasMirroring() -> Bool { unexpected("hasMirroring") }
func emit(_ value: [String: Any]) { let _: Bool = unexpected("emit") }
func recoveryReason(externals: Int, eof: Bool, readError: Bool, age: Double,
                    elapsed: Double, duration: Double) -> String? { unexpected("recoveryReason") }
struct BuiltinDisplayState: Codable { let sentinel: Bool }
func captureBuiltinDisplayState() -> BuiltinDisplayState? { unexpected("captureBuiltinDisplayState") }
final class RoutingDiagnostics {
    let stderrHandle = FileHandle.nullDevice
    static func begin() throws -> RoutingDiagnostics { unexpected("diagnostics.begin") }
    static func latestReport(currentLinkData: Data?) -> Data? { unexpected("diagnostics.latestReport") }
    func append(event: [String: Any]) { let _: Bool = unexpected("diagnostics.append") }
}

@main struct RoutingDisabledTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "guardian-entry" {
            let state = try JSONEncoder().encode(BuiltinDisplayState(sentinel: true)).base64EncodedString()
            routingGuardian(duration: 0, savedState: state)
        }
        require(CommandLine.arguments.count == 1, "A rejected experiment launched a child helper")
        let session = RoutingSession()
        require(!session.start(duration: 0), "New experimental session was accepted")
        require(session.lastError == routingExperimentDisabledMessage, "Rejection explanation missing")
        require(!session.running && !session.recoveryUnconfirmed, "Rejected session acquired child or recovery state")
        require(session.stop(), "Stopping an unused session should remain available")
        session.beat()

        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["guardian-entry"]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        require(process.terminationReason == .exit && process.terminationStatus == 2,
                "Guardian did not reject before any dependency or helper")
        require(response == "FAILED:\(routingExperimentDisabledMessage)\n", "Guardian rejection explanation missing")
        print("PASS: new session and direct guardian rejected before display/logging dependencies or helper launch; idle stop remains callable")
    }
}
