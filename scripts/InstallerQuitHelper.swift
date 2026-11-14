import AppKit
import Foundation

// Ask only this application to quit normally. Never kill or force-terminate it.
let expectedID = "local.webinarnihongo.app"
let deadline = Date().addingTimeInterval(20)
var asked = Set<pid_t>()
var quietSince: Date?
repeat {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: expectedID).filter {
        !$0.isTerminated && $0.executableURL?.lastPathComponent == "WebinarNihongo"
    }
    if apps.isEmpty {
        if quietSince == nil { quietSince = Date() }
        if Date().timeIntervalSince(quietSince!) >= 2 { print("RTranslate is closed."); exit(0) }
    } else {
        quietSince = nil
        for app in apps where !asked.contains(app.processIdentifier) {
            asked.insert(app.processIdentifier)
            guard app.terminate() else { fputs("R翻訳を通常終了できません。メニューバーから終了してください。\n", stderr); exit(1) }
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
} while Date() < deadline
fputs("R翻訳が終了しませんでした。Safariも終了し、R翻訳のメニューから終了して再実行してください。自動で強制終了はしません。\n", stderr)
exit(1)
