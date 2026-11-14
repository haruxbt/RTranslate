import AppKit

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var ending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard !ending else { return .terminateLater }
        ending = true
        Task { await model.shutdownGracefully(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
