import Foundation
import Combine
import WebinarCore

@MainActor
final class ListeningPreferences: ObservableObject {
    @Published var smooth = UserDefaults.standard.object(forKey: "smoothSpeech") as? Bool ?? true {
        didSet { UserDefaults.standard.set(smooth, forKey: "smoothSpeech") }
    }
    let shared = SharedPronunciations()
    private var readingRevision = -1
    private var fallbackMatcher = PronunciationText.Matcher([])
    private var nativeMatcher = PronunciationText.Matcher([])
    private var nativeRows: [String: SpeechPronunciation] = [:]

    private func refreshMatchers() {
        guard shared.revision != readingRevision else { return }
        readingRevision = shared.revision
        let entries = shared.entries
        nativeRows = Dictionary(uniqueKeysWithValues: entries.map { ($0.word.lowercased(), $0) })
        fallbackMatcher = PronunciationText.Matcher(entries.map(\.replacement))
        nativeMatcher = PronunciationText.Matcher(entries.map { GlossaryTerm(source: $0.word, target: $0.word) })
    }

    func spoken(_ text: String) -> String {
        refreshMatchers()
        return fallbackMatcher.replacing(text)
    }

    func voicevoxSpeech(_ text: String) -> (text: String, pronunciations: [SpeechPronunciation]) {
        refreshMatchers()
        let match = nativeMatcher.replacingAndMatching(text)
        let rows = Set(match.matched).sorted().compactMap { nativeRows[$0] }
        if rows.count > 24 { return (spoken(text), []) }
        return (match.text, rows)
    }
    private static let technicalTerms = [
        "SOC", "SOCs", "SIEM", "SOAR", "EDR", "XDR", "MDR", "SBOM", "SBOMs", "CBOM", "CBOMs"
    ]
    let recognitionTerms = technicalTerms + [
        "Security Operations Center", "Software Bill of Materials", "Cryptography Bill of Materials", "zero-day", "zero day"
    ]
    func activeTerms(for text: String) -> [GlossaryTerm] {
        let input = ListeningText.normalizeZeroDay(text)
        let zeroDay = ["zero-day", "zero-days"].map { GlossaryTerm(source: $0, target: "ゼロデイ") }
        return (Self.technicalTerms.map { GlossaryTerm(source: $0, target: $0) } + zeroDay).filter {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: $0.source) + #"(?![\p{L}\p{N}])"#
            return input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
