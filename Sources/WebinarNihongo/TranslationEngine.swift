import Foundation
import Translation
import WebinarCore

@MainActor
protocol TextTranslator: AnyObject {
    func translate(_ text: String, context: String) async throws -> String
}

@MainActor
final class AppleTranslator: TextTranslator {
    private var session: TranslationSession?
    func translate(_ text: String, context: String) async throws -> String {
        let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "ja")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw AppError.message("「Apple翻訳を準備」で英日モデルをダウンロードしてください。")
        }
        if session == nil { session = TranslationSession(installedSource: source, target: target) }
        return try await session!.translate(text).targetText
    }
    func cancel() { session?.cancel(); session = nil }
}

/// Only the loopback endpoint reported by our own child worker is used.
@MainActor
final class PlamoTranslator: TextTranslator {
    var glossary: [GlossaryTerm] = []
    var endpointProvider: (() -> URL?)?
    func translate(_ text: String, context: String) async throws -> String {
        guard let endpoint = endpointProvider?() else { throw AppError.message("PLaMoの準備が完了していません。モデルの状態を確認してください。") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "context": context,
            "glossary": glossary.map { ["source": $0.source, "target": $0.target] }])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["translation"] as? String else {
            throw AppError.message("ローカルPLaMoの応答を確認してください。")
        }
        return result
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
