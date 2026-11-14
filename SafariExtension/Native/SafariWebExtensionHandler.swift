import AppKit
import Foundation
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let command = message["command"] as? String,
              ["start", "stop", "status", "timeline", "pcm", "heartbeat", "voice", "settings", "preview", "dictionaryGet", "dictionarySave", "assetsStatus", "assetsPrepare", "uninstallReview", "uninstall"].contains(command),
              let body = try? JSONSerialization.data(withJSONObject: message), body.count <= 64_000 else {
            respond(["ok": false, "error": "未対応の操作です。"], to: context); return
        }
        Task {
            do {
                let result = try await send(body)
                respond(result, to: context)
            } catch {
                if command == "start" || command == "preview" || command == "dictionaryGet" || command == "assetsStatus" {
                    // User initiated start: open the containing app without a new UI window.
                    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.arguments = ["--extension-service"]
                    do {
                        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                        for _ in 0..<15 {
                            try await Task.sleep(for: .milliseconds(250))
                            if let result = try? await send(body) { respond(result, to: context); return }
                        }
                    } catch {}
                }
                respond(["ok": false, "error": "Webinar Nihongoアプリを起動してから、もう一度開始してください。"], to: context)
            }
        }
    }
    private func send(_ data: Data) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:50023/extension")!)
        request.httpMethod = "POST"; request.httpBody = data; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: RejectRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              body.count <= 512_000, let result = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NSError(domain: "WebinarExtension", code: 1)
        }
        return result
    }
    private func respond(_ value: [String: Any], to context: NSExtensionContext) {
        let response = NSExtensionItem(); response.userInfo = [SFExtensionMessageKey: value]
        context.completeRequest(returningItems: [response])
    }
}
final class RejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
