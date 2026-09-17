import Foundation
import Darwin

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
@main
struct RoutingDiagnosticsTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "child" {
            for i in 0..<100 {
                let record = ["event":"child", "index":i] as [String : Any]
                var line = try JSONSerialization.data(withJSONObject: record)
                line.append(10)
                FileHandle.standardError.write(line)
            }
            FileHandle.standardError.write(Data("serialNumber=TEST_SERIAL uuid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE /Users/TEST_USER/private folder/result.txt\n".utf8))
            exit(0)
        }
        let dir = ProcessInfo.processInfo.environment["OPENCLAM_DIAGNOSTICS_DIR"]!
        check(dir.contains("/.tmp/"), "test location is workspace scratch")
        let first = try RoutingDiagnostics.begin()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["child"]
        process.standardError = first.stderrHandle
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        for i in 0..<100 { first.append(event:["event":"owner", "index":i]) }
        process.waitUntilExit()
        check(process.terminationStatus == 0, "child finished")
        first.append(event:["event":"privacy", "savedState":"SECRET_STATE", "serialNumber":"SECRET_SERIAL",
            "uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "message":"Failure in /Users/TEST_USER/private folder/test.txt",
            "sensor":["reportHex":"010203"]])
        first.append(event: ["event": "selection_evidence", "pinnedRegistryID": 12345,
                             "newExternalIDs": [2], "digitalMode": 7, "digitalEncoding": 2,
                             "returnHex": "0xe00002c7"])
        let report = RoutingDiagnostics.latestReport(currentLinkData:Data("{\"displays\":[{\"id\":3}],\"serialNumber\":\"SECRET_LINK_SERIAL\"}".utf8))!
        let object = try JSONSerialization.jsonObject(with: report) as! [String:Any]
        let session = (object["sessions"] as! [[String:Any]])[0]
        let events = session["events"] as! [[String:Any]]
        check(events.filter{($0["event"] as? String)=="owner"}.count==100, "all concurrent owner events intact")
        check(events.filter{($0["event"] as? String)=="child"}.count==100, "all concurrent inherited-stderr events intact")
        let evidence = events.first { ($0["event"] as? String) == "selection_evidence" }!
        check((evidence["pinnedRegistryID"] as? Int) == 12345, "framebuffer identity preserved")
        check((evidence["newExternalIDs"] as? [Int]) == [2], "CG identities preserved")
        check((evidence["digitalMode"] as? Int) == 7 && (evidence["digitalEncoding"] as? Int) == 2, "driver mode evidence preserved")
        check((evidence["returnHex"] as? String) == "0xe00002c7", "raw return preserved")
        let text = String(decoding:report,as:UTF8.self)
        for secret in ["SECRET_STATE","SECRET_SERIAL","SECRET_LINK_SERIAL","TEST_SERIAL","TEST_USER","AAAAAAAA-BBBB","reportHex"] {
            check(!text.contains(secret), "export redacted \(secret)")
        }
        let directoryAttrs = try FileManager.default.attributesOfItem(atPath:dir)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath:first.path.path)
        check((directoryAttrs[.posixPermissions] as! NSNumber).intValue==0o700,"directory permissions")
        check((fileAttrs[.posixPermissions] as! NSNumber).intValue==0o600,"file permissions")
        let second=try RoutingDiagnostics.begin();second.append(event:["event":"second_failure"])
        let third=try RoutingDiagnostics.begin();third.append(event:["event":"third_started"])
        let files = try FileManager.default.contentsOfDirectory(atPath:dir).filter{$0.hasSuffix(".jsonl")}
        check(files.count==2,"retain latest and previous only")
        let rotated = try JSONSerialization.jsonObject(with:RoutingDiagnostics.latestReport()!) as! [String:Any]
        let sessions=rotated["sessions"] as! [[String:Any]]
        check(sessions.count==2,"report both retained sessions")
        check((sessions[1]["events"] as! [[String:Any]]).contains{($0["event"] as? String)=="second_failure"},"previous failure retained")
        var bulk=Data()
        for i in 0..<20000 {bulk.append(Data("{\"event\":\"bulk\",\"index\":\(i),\"message\":\"repeat . quote = : punctuation and detail\"}\n".utf8))}
        third.stderrHandle.write(bulk)
        third.append(event:["event":"tail_marker"])
        let bounded=RoutingDiagnostics.latestReport()!
        check(bounded.count<=2*1024*1024,"report bounded to 2 MiB")
        let boundedObject=try JSONSerialization.jsonObject(with:bounded) as! [String:Any]
        let boundedSession=(boundedObject["sessions"] as! [[String:Any]])[0]
        check(boundedSession["truncated"] as? Bool==true,"oversized report marked truncated")
        check((boundedSession["events"] as! [[String:Any]]).last?["event"] as? String=="tail_marker","newest event retained")
        try bounded.write(to:URL(fileURLWithPath:dir).deletingLastPathComponent().appendingPathComponent("export.json"))
        print("PASS: concurrent stderr/owner append, privacy, 0600/0700, latest+previous rotation, 2 MiB export bound, newest event retained")
    }
}
