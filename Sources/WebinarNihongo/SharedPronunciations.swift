import Foundation
import Combine
import AppKit
import WebinarCore

@MainActor
final class SharedPronunciations: ObservableObject {
    private struct File: Decodable {
        let schemaVersion: Int
        let version: String
        let entries: [SpeechPronunciation]
    }

    private struct PersonalEntry: Codable {
        let id: UUID?
        let word: String
        let reading: String
        let accent: Int?
        let priority: Int?

        var pronunciation: SpeechPronunciation {
            SpeechPronunciation(word: word,
                                reading: reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading,
                                accent: accent ?? 0, priority: priority ?? 5)
        }
    }

    private static let personalDomain = "local.flop.RSpeech"
    private static let personalKey = "readingDictionaryV1"

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

    var entries: [SpeechPronunciation] {
        Array(Dictionary((common + personal).map { ($0.word.lowercased(), $0) },
                         uniquingKeysWith: { _, personal in personal }).values)
    }

    private func personalEntries(in defaults: UserDefaults) throws -> [PersonalEntry] {
        guard let saved = defaults.object(forKey: Self.personalKey) else { return [] }
        guard let data = saved as? Data, data.count <= 1_048_576,
              let entries = try? JSONDecoder().decode([PersonalEntry].self, from: data),
              entries.count <= 1000 else {
            throw AppError.message("RSpeechの個人辞書を読み込めませんでした。")
        }
        return entries
    }

    func refreshPersonal() {
        guard let defaults = UserDefaults(suiteName: Self.personalDomain),
              let rows = try? personalEntries(in: defaults) else { return }
        let next = rows.map(\.pronunciation).filter(\.valid)
        if next != personal { personal = next; revision += 1 }
    }

    func addPersonal(word: String, reading: String, accent: Int) throws {
        guard let defaults = UserDefaults(suiteName: Self.personalDomain) else {
            throw AppError.message("RSpeechの個人辞書を開けませんでした。")
        }
        // RSpeech keeps an editable copy while it runs and can save it back in full.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.personalDomain).isEmpty else {
            throw AppError.message("RSpeechのメニューバーから「終了」を選んでから追加してください。")
        }
        let kana = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = try personalEntries(in: defaults)
        let index = rows.firstIndex { $0.word.caseInsensitiveCompare(term) == .orderedSame }
        let previous = index.map { rows[$0] }
        let entry = PersonalEntry(id: previous?.id ?? UUID(), word: term, reading: kana, accent: accent,
                                  priority: previous?.priority ?? 5)
        let pronunciation = entry.pronunciation
        guard pronunciation.valid else {
            throw AppError.message("単語と読み方を64文字以内で入力し、アクセントの値を確認してください。")
        }
        let normalized = PersonalEntry(id: entry.id, word: term, reading: pronunciation.reading,
                                       accent: accent, priority: entry.priority)
        if let index { rows[index] = normalized }
        else {
            guard rows.count < 1000 else { throw AppError.message("RSpeechの個人辞書は1000件まで登録できます。") }
            rows.append(normalized)
        }
        defaults.set(try JSONEncoder().encode(rows), forKey: Self.personalKey)
        refreshPersonal()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !updating else { return false }
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
            return true
        } catch {
            message = "更新できませんでした。保存済みの共通辞書を使用します。"
            return false
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

    var unpublished: [SpeechPronunciation] {
        let known = Set(common.map { $0.word.lowercased() })
        return personal.filter { !known.contains($0.word.lowercased()) && Self.canShare($0) }
            .sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    static let batchLimit = 8

    private static func canShare(_ pronunciation: SpeechPronunciation) -> Bool {
        pronunciation.valid && GitHubDraft.shareableTerm(pronunciation.word)
    }

    static func issueURL(for pronunciations: [SpeechPronunciation]) -> URL? {
        guard let first = pronunciations.first, pronunciations.count <= batchLimit,
              pronunciations.allSatisfy(canShare) else { return nil }
        let encoder = JSONEncoder()
        let body = try? (pronunciations.count == 1 ? encoder.encode(first) : encoder.encode(pronunciations))
        guard let body else { return nil }
        return GitHubDraft.issue(repository: "RSpeech", title: submissionTitle,
                                body: String(decoding: body, as: UTF8.self))
    }
}
