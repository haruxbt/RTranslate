import Foundation
import Combine
import WebinarCore

@MainActor
final class SharedPronunciations: ObservableObject {
    private struct File: Decodable {
        let schemaVersion: Int
        let version: String
        let entries: [SpeechPronunciation]
    }

    static let source = URL(string: "https://raw.githubusercontent.com/haruxbt/RSpeech/main/Dictionary/common-ja.json")!
    static let submissionTitle = "[R辞書] 共有読み方の追加"
    private static var cache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RTranslate/common-pronunciations.json")
    }

    @Published private(set) var version = ""
    @Published private(set) var message = ""
    @Published private(set) var updating = false
    @Published private(set) var common: [SpeechPronunciation] = []
    @Published private(set) var personal: [SpeechPronunciation] = []
    private(set) var revision = 0

    init() {
        let bundled = Bundle.main.url(forResource: "rspeech-common-ja", withExtension: "json")
        for url in [bundled, Self.cache].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let file = Self.decode(data) { apply(file) }
        }
        refreshPersonal()
    }

    func refreshPersonal() {
        let data = UserDefaults(suiteName: "local.flop.RSpeech")?.data(forKey: "readingDictionaryV1")
        let values = data.flatMap { bytes -> [SpeechPronunciation]? in
            guard bytes.count <= 1_048_576 else { return nil }
            return try? JSONDecoder().decode([SpeechPronunciation].self, from: bytes)
        } ?? []
        let next = Array(values.prefix(1000)).filter(\.valid)
        if next != personal { personal = next; revision += 1 }
    }

    func refresh() async {
        guard !updating else { return }
        refreshPersonal()
        updating = true
        defer { updating = false }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: Self.source)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == Self.source else {
                throw AppError.message("共通辞書が取得できませんでした。")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw AppError.message("共通辞書が大きすぎます。") }
                data.append(byte)
            }
            guard let file = Self.decode(data), file.version.compare(version, options: .numeric) != .orderedAscending else {
                throw AppError.message("共通辞書の形式または版を確認できません。")
            }
            try FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.cache, options: .atomic)
            apply(file)
            message = "共通辞書 \(version)・\(common.count)語"
        } catch {
            message = "更新できませんでした。保存済みの共通辞書を使用します。"
        }
    }

    private static func decode(_ data: Data) -> File? {
        guard data.count <= 1_048_576, let file = try? JSONDecoder().decode(File.self, from: data),
              file.schemaVersion == 1, file.entries.count <= 2000,
              file.version.range(of: #"^[0-9]{4}(?:\.[0-9]+){3}$"#, options: .regularExpression) != nil,
              file.entries.allSatisfy(\.valid),
              Set(file.entries.map { $0.word.lowercased() }).count == file.entries.count else { return nil }
        return file
    }

    private func apply(_ file: File) {
        guard file.version.compare(version, options: .numeric) != .orderedAscending else { return }
        if common != file.entries {
            common = file.entries
            revision += 1
        }
        version = file.version
    }

    static func issueURL(word: String, reading: String) -> URL? {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        let entry = SpeechPronunciation(word: word, reading: kana)
        guard entry.valid,
              word.range(of: #"[\p{L}]"#, options: .regularExpression) != nil,
              word.range(of: #"^[\p{L}\p{M}\p{N} ._+&@'-]+$"#, options: .regularExpression) != nil,
              word.range(of: #"[\w.+-]+@[\w.-]+\.[a-z]{2,}|(?:sk-|gh[pousr]_)[A-Za-z0-9]{20,}"#,
                         options: [.regularExpression, .caseInsensitive]) == nil,
              let encoded = try? JSONEncoder().encode(entry) else { return nil }
        var url = URLComponents(string: "https://github.com/haruxbt/RSpeech/issues/new")!
        url.queryItems = [.init(name: "title", value: submissionTitle),
                          .init(name: "body", value: String(decoding: encoded, as: UTF8.self))]
        // A literal + in a product name must survive URL form decoding.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }
}
