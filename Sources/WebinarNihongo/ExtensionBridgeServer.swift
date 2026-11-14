import Foundation
import Network

/// Only the sandboxed native extension connects here. No CORS, webpage origins,
/// redirects or arbitrary worker URLs are accepted. Audio and transcripts stay local.
final class ExtensionBridgeServer: @unchecked Sendable {
    typealias Handler = @MainActor ([String: Any]) async -> [String: Any]
    private let queue = DispatchQueue(label: "webinar.extension.ipc")
    private var listener: NWListener?
    private let handler: Handler
    init(handler: @escaping Handler) { self.handler = handler }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 50023)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            let request = Request(connection: connection, handler: handler)
            request.read()
            queue.asyncAfter(deadline: .now() + 15) { [weak request] in request?.cancel() }
        }
        listener.start(queue: queue)
    }
    func stop() { listener?.cancel(); listener = nil }
    private final class Request: @unchecked Sendable {
        let connection: NWConnection
        let handler: Handler
        var bytes = Data()
        var completed = false
        init(connection: NWConnection, handler: @escaping Handler) { self.connection = connection; self.handler = handler }
        func cancel() { completed = true; connection.cancel() }
        func reply(_ value: [String: Any], status: Int = 200) {
            guard !completed else { return }; completed = true
            let body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
            var output = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            output.append(body)
            connection.send(content: output, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
                guard !completed else { return }
                if let data { bytes.append(data) }
                guard bytes.count <= 96_000 else { reply(["ok": false], status: 413); return }
                if let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    guard let head = String(data: bytes[..<headerEnd.lowerBound], encoding: .utf8) else { reply(["ok": false], status: 400); return }
                    let lines = head.components(separatedBy: "\r\n")
                    var headers = [String: String]()
                    for line in lines.dropFirst() {
                        guard let separator = line.firstIndex(of: ":") else { reply(["ok": false], status: 400); return }
                        let key = line[..<separator].lowercased()
                        guard headers[key] == nil else { reply(["ok": false], status: 400); return }
                        headers[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    }
                    guard lines.first == "POST /extension HTTP/1.1", headers["host"] == "127.0.0.1:50023",
                          headers["origin"] == nil, headers["transfer-encoding"] == nil,
                          headers["content-type"] == "application/json", let count = Int(headers["content-length"] ?? ""),
                          count > 0, count <= 64_000 else { reply(["ok": false], status: 403); return }
                    let body = bytes[headerEnd.upperBound...]
                    if body.count == count {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { reply(["ok": false], status: 400); return }
                        Task { @MainActor [self] in
                            let result = await self.handler(object)
                            self.connection.send(content: self.responseData(result), completion: .contentProcessed { [connection = self.connection] _ in connection.cancel() })
                        }
                        completed = true
                        return
                    }
                    if body.count > count { reply(["ok": false], status: 400); return }
                }
                if done || error != nil { cancel() } else { read() }
            }
        }
        private func responseData(_ result: [String: Any]) -> Data {
            let body = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
            var output = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            output.append(body); return output
        }
    }
}
