import Foundation
import Darwin

// Only this routing session's child stderr is attached to the file. No global
// stderr redirection, sensor sampling, or system-log collection occurs here.
final class RoutingDiagnostics {
    let stderrHandle: FileHandle
    let path: URL

    private static let filePrefix = "routing-session-"
    private static let maximumReportBytes = 2 * 1024 * 1024
    private static let maximumRawBytes = 1024 * 1024
    private static let maximumSessionBytes = 768 * 1024

    private init(path: URL, descriptor: Int32) {
        self.path = path
        stderrHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENCLAM_DIAGNOSTICS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenClam", isDirectory: true)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }

    private static func sessionFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func begin() throws -> RoutingDiagnostics {
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        }
        guard chmod(folder.path, 0o700) == 0 else { throw posixError() }
        // Unique filenames preserve a session's append target when the next
        // session starts; exported reports never include these filenames.
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let name = filePrefix + String(format: "%020llu", stamp) + "-" + UUID().uuidString + ".jsonl"
        let path = folder.appendingPathComponent(name)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard fchmod(fd, 0o600) == 0 else {
            let error = posixError()
            close(fd)
            try? FileManager.default.removeItem(at: path)
            throw error
        }
        let diagnostics = RoutingDiagnostics(path: path, descriptor: fd)
        for old in sessionFiles(in: folder).dropFirst(2) {
            try FileManager.default.removeItem(at: old)
        }
        diagnostics.append(event: ["event": "session_started", "metadata": metadata()])
        return diagnostics
    }

    func append(event: [String: Any]) {
        var record = Self.sanitize(event) as? [String: Any] ?? [:]
        record["timestamp"] = Self.timestamp()
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) else { return }
        if data.count > 64 * 1024 {
            record = ["event": "diagnostic_event_truncated", "timestamp": Self.timestamp()]
            guard let reduced = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) else { return }
            data = reduced
        }
        data.append(0x0a)
        // A distinct O_APPEND descriptor keeps owner writes independent of the
        // inherited child stderr's offset. Do not recreate a retired log file.
        let fd = open(path.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                written += count
            }
            _ = fsync(fd)
        }
    }

    static func latestReport(currentLinkData: Data? = nil) -> Data? {
        let files = Array(sessionFiles(in: directory).prefix(2))
        let links = currentLinkData.flatMap { try? JSONSerialization.jsonObject(with: $0) }.map { sanitize($0) }
        guard !files.isEmpty || links != nil else { return nil }
        let sessions = files.enumerated().map { index, file in
            sessionReport(file, position: index == 0 ? "latest" : "previous")
        }
        var report: [String: Any] = ["format": "openclam-routing-diagnostics", "schemaVersion": 1,
            "generatedAt": timestamp(), "metadata": metadata(), "sessions": sessions]
        if let links, let data = try? JSONSerialization.data(withJSONObject: links), data.count <= 128 * 1024 {
            report["currentLinks"] = links
        }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
              data.count <= maximumReportBytes else { return nil }
        return data
    }

    private static func sessionReport(_ file: URL, position: String) -> [String: Any] {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            return ["position": position, "truncated": false, "events": [["message": "Session log unavailable"]]]
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            let length = try handle.seekToEnd()
            let offset = length > UInt64(maximumRawBytes) ? length - UInt64(maximumRawBytes) : 0
            try handle.seek(toOffset: offset)
            var bytes = try handle.read(upToCount: maximumRawBytes) ?? Data()
            var truncated = offset != 0
            // Drop the first incomplete line when reading the tail of a log.
            if offset != 0 {
                if let newline = bytes.firstIndex(of: 0x0a) { bytes.removeSubrange(...newline) }
                else { bytes.removeAll() }
            }
            var events: [[String: Any]] = []
            var size = 0
            for line in bytes.split(separator: 0x0a).reversed() {
                let event: [String: Any]
                if let parsed = try? JSONSerialization.jsonObject(with: Data(line)), let object = parsed as? [String: Any] {
                    event = sanitize(object) as? [String: Any] ?? [:]
                } else {
                    event = ["message": sanitizedText(String(decoding: line, as: UTF8.self))]
                }
                guard let encoded = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) else { continue }
                if size + encoded.count + 1 > maximumSessionBytes || events.count >= 10_000 {
                    truncated = true; break
                }
                events.append(event); size += encoded.count + 1
            }
            return ["position": position, "truncated": truncated, "events": Array(events.reversed())]
        } catch {
            return ["position": position, "truncated": false, "events": [["message": "Session log could not be read"]]]
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func metadata() -> [String: String] {
        var size: size_t = 0
        var model = "unknown"
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size <= 256 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                model = String(cString: buffer)
            }
        }
        return ["appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "model": model]
    }

    private static func sensitiveKey(_ key: String) -> Bool {
        let name = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["serial", "uuid", "edid", "savedstate", "base64", "path"].contains(where: name.contains) ||
            ["args", "argv", "arguments", "command", "executable", "cwd", "url", "sensor", "reporthex", "reportdescriptorhex"].contains(name)
    }

    private static func sanitize(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 12 else { return "[truncated]" }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in object.keys.sorted().prefix(128) where !sensitiveKey(key) {
                result[sanitizedText(key)] = sanitize(object[key]!, depth: depth + 1)
            }
            return result
        }
        if let array = value as? [Any] { return array.prefix(128).map { sanitize($0, depth: depth + 1) } }
        if let text = value as? String { return sanitizedText(text) }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : NSNull() }
        return NSNull()
    }

    private static func sanitizedText(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "[redacted identifier]"),
            (#"(?i)(?:file://)?/(?:Users|home|private|tmp|var|Volumes|Applications|Library)(?:/[^\r\n\"<>]*)?"#, "[redacted path]"),
            (#"(?i)\b(?:serial(?:number)?|edid|uuid|saved_?state|external_keys)\s*[:=]\s*(?:\"[^\"]*\"|\S+)"#, "[redacted identifier]"),
            (#"[A-Za-z0-9+/]{80,}={0,2}"#, "[redacted long token]")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result.count > 16_384 ? String(result.prefix(16_384)) + " [truncated]" : result
    }
}
