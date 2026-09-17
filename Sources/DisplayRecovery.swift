import Foundation
import CoreGraphics
import Darwin

struct BuiltinDisplayMode: Codable, Equatable {
    let modeID: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let ioFlags: UInt32

    init(_ mode: CGDisplayMode) {
        modeID = mode.ioDisplayModeID
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate; ioFlags = mode.ioFlags
    }

    // A mode number may be reassigned during hotplug. All of its observable
    // mode properties must still match before an equivalent mode is accepted.
    func matches(_ mode: CGDisplayMode) -> Bool {
        width == mode.width && height == mode.height &&
        pixelWidth == mode.pixelWidth && pixelHeight == mode.pixelHeight &&
        abs(refreshRate - mode.refreshRate) < 0.01 && ioFlags == mode.ioFlags
    }
}

struct BuiltinDisplayState: Codable, Equatable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32
    let mode: BuiltinDisplayMode

    fileprivate func matches(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(display) != 0 &&
        CGDisplayVendorNumber(display) == vendorID &&
        CGDisplayModelNumber(display) == modelID &&
        CGDisplaySerialNumber(display) == serialNumber
    }
}

struct DisplayRecoveryResult: Codable {
    let restored: Bool
    let stage: String
    let detail: String
    let displayID: CGDirectDisplayID?
    let cycled: Bool
}

private typealias RecoveryDisplayList = @convention(c)
    (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> Int32
private typealias RecoveryConfigureEnabled = @convention(c)
    (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

private final class RecoverySkyLight {
    let handle: UnsafeMutableRawPointer
    let displayList: RecoveryDisplayList
    let configureEnabled: RecoveryConfigureEnabled

    init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else { return nil }
        guard let list = dlsym(library, "SLSGetDisplayList"),
              let configure = dlsym(library, "SLSConfigureDisplayEnabled") else {
            dlclose(library); return nil
        }
        handle = library
        displayList = unsafeBitCast(list, to: RecoveryDisplayList.self)
        configureEnabled = unsafeBitCast(configure, to: RecoveryConfigureEnabled.self)
    }

    deinit { dlclose(handle) }

    // SkyLight includes disabled displays which CGGetOnlineDisplayList omits.
    func ids() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard displayList(0, nil, &count) == CGError.success.rawValue, count <= 128 else { return nil }
        guard count > 0 else { return [] }
        var result = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let capacity = count
        guard displayList(capacity, &result, &count) == CGError.success.rawValue, count <= capacity else { return nil }
        return Array(result.prefix(Int(count))).sorted()
    }

    func builtin(matching saved: BuiltinDisplayState? = nil) -> CGDirectDisplayID? {
        guard let all = ids() else { return nil }
        let matches = all.filter { saved?.matches($0) ?? (CGDisplayIsBuiltin($0) != 0) }
        return matches.count == 1 ? matches[0] : nil
    }
}

func captureBuiltinDisplayState() -> BuiltinDisplayState? {
    guard let sky = RecoverySkyLight(), let id = sky.builtin(),
          CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
          let mode = CGDisplayCopyDisplayMode(id),
          mode.width > 0, mode.height > 0, mode.refreshRate.isFinite else { return nil }
    return BuiltinDisplayState(vendorID: CGDisplayVendorNumber(id),
        modelID: CGDisplayModelNumber(id), serialNumber: CGDisplaySerialNumber(id),
        mode: BuiltinDisplayMode(mode))
}

private struct RecoveryTopologyEntry: Equatable {
    let id: CGDirectDisplayID
    let builtin: Bool
    let active: Bool
    let asleep: Bool
    let mode: BuiltinDisplayMode?
}

private func recoveryTopology(_ sky: RecoverySkyLight) -> [RecoveryTopologyEntry]? {
    guard let ids = sky.ids() else { return nil }
    return ids.map {
        RecoveryTopologyEntry(id: $0, builtin: CGDisplayIsBuiltin($0) != 0,
            active: CGDisplayIsActive($0) != 0, asleep: CGDisplayIsAsleep($0) != 0,
            mode: CGDisplayCopyDisplayMode($0).map(BuiltinDisplayMode.init))
    }
}

private func recoveryPause() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}

private func recoverySettle(_ sky: RecoverySkyLight, until deadline: Double,
                            matching saved: BuiltinDisplayState? = nil) -> Bool {
    var previous: [RecoveryTopologyEntry]?
    var quietSince = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime < deadline {
        let now = ProcessInfo.processInfo.systemUptime
        let current = recoveryTopology(sky)
        if current == nil || current != previous {
            quietSince = now; previous = current
        }
        if current != nil && now - quietSince >= 0.75 &&
           (saved == nil || sky.builtin(matching: saved) != nil) { return true }
        recoveryPause()
    }
    return false
}

private func recoveryMode(_ saved: BuiltinDisplayMode, display: CGDirectDisplayID) -> CGDisplayMode? {
    // The default mode list omits some currently selected HiDPI modes. On the
    // test M4, mode6 (1470x956 / 2940x1912) exists only with this option enabled.
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    let matching = modes.filter { saved.matches($0) }
    if let mode = matching.first(where: { $0.ioDisplayModeID == saved.modeID }) ?? matching.first { return mode }
    if let current = CGDisplayCopyDisplayMode(display), saved.matches(current) { return current }
    return nil
}

private struct RecoveryConfigurationResult {
    let code: Int32
    let step: String
    var succeeded: Bool { code == CGError.success.rawValue }
    var detail: String { "\(step) returned \(code)" }
}

private func recoveryOperation(_ step: String, _ code: Int32,
                               display: CGDirectDisplayID) -> RecoveryConfigurationResult {
    if let data = try? JSONSerialization.data(withJSONObject:
        ["recoveryStep": step, "return": code, "displayID": display], options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
    }
    return RecoveryConfigurationResult(code: code, step: step)
}

private func recoveryCommit(_ sky: RecoverySkyLight, display: CGDirectDisplayID,
                            saved: BuiltinDisplayState, enabled: Bool) -> RecoveryConfigurationResult {
    let prefix = enabled ? "enable" : "disable"
    // Recheck immediately before staging: a former built-in ID must never
    // authorize a change to an external that now occupies that ID.
    guard saved.matches(display) else {
        return recoveryOperation("\(prefix)_identity", CGError.invalidOperation.rawValue, display: display)
    }
    if !enabled && recoveryTopology(sky)?.contains(where: { !$0.builtin && $0.active && !$0.asleep }) != true {
        return recoveryOperation("disable_external_guard", CGError.invalidOperation.rawValue, display: display)
    }
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success, let configuration else {
        return recoveryOperation("\(prefix)_begin", (begin == .success ? CGError.failure : begin).rawValue, display: display)
    }
    _ = recoveryOperation("\(prefix)_begin", begin.rawValue, display: display)
    let enabledResult = sky.configureEnabled(configuration, display, enabled)
    let staged = recoveryOperation("\(prefix)_sls", enabledResult, display: display)
    guard enabledResult == CGError.success.rawValue else {
        CGCancelDisplayConfiguration(configuration)
        return staged
    }
    guard saved.matches(display) else {
        CGCancelDisplayConfiguration(configuration)
        return recoveryOperation("\(prefix)_identity", CGError.invalidOperation.rawValue, display: display)
    }
    if !enabled && recoveryTopology(sky)?.contains(where: { !$0.builtin && $0.active && !$0.asleep }) != true {
        CGCancelDisplayConfiguration(configuration)
        return recoveryOperation("disable_external_guard", CGError.invalidOperation.rawValue, display: display)
    }
    return recoveryOperation("\(prefix)_commit", CGCompleteDisplayConfiguration(configuration, .forSession).rawValue, display: display)
}

private func recoveryModeCommit(display: CGDirectDisplayID, saved: BuiltinDisplayState,
                                mode: CGDisplayMode) -> RecoveryConfigurationResult {
    guard saved.matches(display), CGDisplayIsActive(display) != 0, CGDisplayIsAsleep(display) == 0 else {
        return recoveryOperation("mode_active_identity", CGError.invalidOperation.rawValue, display: display)
    }
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success, let configuration else {
        return recoveryOperation("mode_begin", (begin == .success ? CGError.failure : begin).rawValue, display: display)
    }
    _ = recoveryOperation("mode_begin", begin.rawValue, display: display)
    let staged = recoveryOperation("mode_cg", CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil).rawValue, display: display)
    guard staged.succeeded else { CGCancelDisplayConfiguration(configuration); return staged }
    guard saved.matches(display), CGDisplayIsActive(display) != 0, CGDisplayIsAsleep(display) == 0 else {
        CGCancelDisplayConfiguration(configuration)
        return recoveryOperation("mode_active_identity", CGError.invalidOperation.rawValue, display: display)
    }
    return recoveryOperation("mode_commit", CGCompleteDisplayConfiguration(configuration, .forSession).rawValue, display: display)
}

// Read-only barrier between driver-open and panel-on. A prepared result means
// endpoint identity/topology settled; it does not assert that the panel is on.
func prepareBuiltinDisplayRecovery(_ saved: BuiltinDisplayState) -> DisplayRecoveryResult {
    guard let sky = RecoverySkyLight() else {
        return DisplayRecoveryResult(restored: false, stage: "prepare", detail: "SkyLight display enumeration unavailable",
                                     displayID: nil, cycled: false)
    }
    guard recoverySettle(sky, until: ProcessInfo.processInfo.systemUptime + 3.25, matching: saved),
          let id = sky.builtin(matching: saved) else {
        return DisplayRecoveryResult(restored: false, stage: "prepare", detail: "Original built-in identity/topology did not settle; panel-on target is unconfirmed",
                                     displayID: nil, cycled: false)
    }
    return DisplayRecoveryResult(restored: true, stage: "prepared", detail: "Original built-in endpoint identity/topology settled; visibility not yet restored",
                                 displayID: id, cycled: false)
}

// The caller first submits driver-open and panel-on, then runs this function
// in its separately bounded/reaped recovery child. Polling is bounded here;
// synchronous WindowServer calls still require the caller's process deadline.
func restoreBuiltinDisplayState(_ saved: BuiltinDisplayState) -> DisplayRecoveryResult {
    var cycled = false
    var currentID: CGDirectDisplayID?
    func result(_ restored: Bool, _ stage: String, _ detail: String) -> DisplayRecoveryResult {
        DisplayRecoveryResult(restored: restored, stage: stage, detail: detail,
                              displayID: currentID, cycled: cycled)
    }
    guard let sky = RecoverySkyLight() else { return result(false, "load", "SkyLight configuration API unavailable") }
    let deadline = ProcessInfo.processInfo.systemUptime + 9.5
    guard recoverySettle(sky, until: min(deadline, ProcessInfo.processInfo.systemUptime + 4), matching: saved),
          let id = sky.builtin(matching: saved) else {
        return result(false, "settle", "Current built-in display identity did not settle after driver-open/panel-on")
    }
    currentID = id

    // A disconnected endpoint may not publish its mode list yet. Visibility
    // recovery must not depend on that list: first enable the freshly matched
    // built-in using macOS's existing mode, then query the complete mode list.
    if CGDisplayIsActive(id) == 0 || CGDisplayIsAsleep(id) != 0 ||
       recoveryMode(saved.mode, display: id) == nil {
        let enabled = recoveryCommit(sky, display: id, saved: saved, enabled: true)
        guard enabled.succeeded else {
            return result(false, "initial_enable", enabled.detail)
        }
        _ = recoverySettle(sky, until: min(deadline, ProcessInfo.processInfo.systemUptime + 2), matching: saved)
    }
    guard let readyID = sky.builtin(matching: saved) else {
        return result(false, "rediscover", "Built-in identity unavailable after initial enable")
    }
    currentID = readyID
    guard recoveryMode(saved.mode, display: readyID) != nil else {
        return result(false, "mode", "Built-in enable was submitted; captured mode is still unavailable, so no further disable was attempted")
    }

    // Never blank the only usable screen or start another off transition when
    // insufficient time remains to restore and verify it.
    if CGDisplayIsActive(readyID) != 0,
       deadline - ProcessInfo.processInfo.systemUptime > 2.5,
       recoveryTopology(sky)?.contains(where: { !$0.builtin && $0.active && !$0.asleep }) == true {
        let disabled = recoveryCommit(sky, display: readyID, saved: saved, enabled: false)
        guard disabled.succeeded else {
            if let freshID = sky.builtin(matching: saved) {
                _ = recoveryCommit(sky, display: freshID, saved: saved, enabled: true)
            }
            return result(false, "disable", disabled.detail)
        }
        cycled = true
        // Always proceed to re-enable, including after a settle timeout or an
        // external unplug; an incomplete off transition still needs recovery.
        _ = recoverySettle(sky, until: min(deadline, ProcessInfo.processInfo.systemUptime + 2))
    }

    guard let restoredID = sky.builtin(matching: saved) else {
        return result(false, "rediscover", "Built-in identity unavailable after layout transition; refusing a cached display ID")
    }
    currentID = restoredID
    // Mode configuration rejects some disabled display IDs even when an SLS
    // enable is pending in the same transaction. Commit visibility first; a
    // later optional mode failure must never cancel this enable transaction.
    let enabled = recoveryCommit(sky, display: restoredID, saved: saved, enabled: true)
    guard enabled.succeeded else {
        return result(false, "enable", enabled.detail)
    }
    var modeAttempted = false
    var verifiedSince: Double?
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let freshID = sky.builtin(matching: saved), CGDisplayIsActive(freshID) != 0,
           CGDisplayIsAsleep(freshID) == 0, let currentMode = CGDisplayCopyDisplayMode(freshID) {
            currentID = freshID
            if saved.mode.matches(currentMode) {
                // The real off/on transition already refreshed CA. If macOS
                // restored the saved mode itself, do not stage a no-op mode.
                let now = ProcessInfo.processInfo.systemUptime
                if verifiedSince == nil { verifiedSince = now }
                if now - verifiedSince! >= 0.75 {
                    return result(true, "verified", "Built-in active, awake, and captured mode stable; pixel color is not verified")
                }
            } else {
                verifiedSince = nil
                if !modeAttempted, let available = recoveryMode(saved.mode, display: freshID) {
                    modeAttempted = true
                    let applied = recoveryModeCommit(display: freshID, saved: saved, mode: available)
                    guard applied.succeeded else {
                        _ = recoveryCommit(sky, display: freshID, saved: saved, enabled: true)
                        return result(false, "mode", "Built-in enable committed separately; \(applied.detail)")
                    }
                }
            }
        } else { verifiedSince = nil }
        recoveryPause()
    }
    return result(false, "verify", "Built-in active/awake/captured-mode verification timed out")
}
