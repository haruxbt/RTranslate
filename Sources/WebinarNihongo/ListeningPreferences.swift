import Foundation
import Combine
import WebinarCore

@MainActor
final class ListeningPreferences: ObservableObject {
    @Published var smooth = UserDefaults.standard.object(forKey: "smoothSpeech") as? Bool ?? true {
        didSet { UserDefaults.standard.set(smooth, forKey: "smoothSpeech") }
    }
    @Published var glossary = UserDefaults.standard.string(forKey: "listeningGlossary") ?? "SOC = SOC\nSIEM = SIEM\nSOAR = SOAR\nEDR = EDR\nXDR = XDR\nMDR = MDR" {
        didSet { UserDefaults.standard.set(glossary, forKey: "listeningGlossary") }
    }
    @Published var corrections = UserDefaults.standard.string(forKey: "listeningCorrections") ?? "Sock work = SOC work" {
        didSet { UserDefaults.standard.set(corrections, forKey: "listeningCorrections") }
    }
    @Published var readings = UserDefaults.standard.string(forKey: "speechReadings") ?? "Square = スクエア" {
        didSet { UserDefaults.standard.set(readings, forKey: "speechReadings") }
    }
    @Published var displayTerms = UserDefaults.standard.string(forKey: "displayTerms") ?? "" {
        didSet { UserDefaults.standard.set(displayTerms, forKey: "displayTerms") }
    }
    func displayed(_ text: String) -> String { PronunciationText.displayed(text, terms: ListeningText.terms(displayTerms)) }
    let shared = SharedPronunciations()
    private var readingKey: [String] = []
    private var fallbackMatcher = PronunciationText.Matcher([])
    private var nativeMatcher = PronunciationText.Matcher([])
    private var nativeRows: [String: SpeechPronunciation] = [:]

    var inheritedReadings: [GlossaryTerm] { (shared.common + shared.personal).map(\.replacement) }

    private func refreshMatchers() {
        let key = [readings, glossary, String(shared.revision)]
        guard key != readingKey else { return }
        readingKey = key
        let direct = ListeningText.terms(readings)
        var native = Dictionary((shared.common + shared.personal).map { ($0.word.lowercased(), $0) },
                                uniquingKeysWith: { _, last in last })
        let speechTerms = inheritedReadings + direct
        let byWord = Dictionary(speechTerms.map { ($0.source.lowercased(), $0.target) },
                                uniquingKeysWith: { _, last in last })
        let localKeys = Set(direct.map { $0.source.lowercased() })
        let aliases = terms.compactMap { term -> GlossaryTerm? in
            let source = term.source.lowercased()
            let target = term.target.lowercased()
            guard let reading = byWord[source], source != target, byWord[target] == nil else { return nil }
            if !localKeys.contains(source), let entry = native[source] {
                let alias = SpeechPronunciation(word: term.target, reading: entry.reading, accent: entry.accent, priority: entry.priority)
                if alias.valid { native[target] = alias }
            }
            return GlossaryTerm(source: term.target, target: reading)
        }
        for key in localKeys { native.removeValue(forKey: key) }
        nativeRows = native
        let all = speechTerms + aliases
        fallbackMatcher = PronunciationText.Matcher(all)
        nativeMatcher = PronunciationText.Matcher(all.map {
            GlossaryTerm(source: $0.source, target: native[$0.source.lowercased()]?.word ?? $0.target)
        })
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
    var terms: [GlossaryTerm] { Array(ListeningText.terms(glossary).prefix(100)) }
    var recognitionTerms: [String] { terms.map(\.source) + ["SOC", "Security Operations Center", "SIEM", "SOAR", "EDR", "XDR", "MDR"] }
    var parsedCorrections: [GlossaryTerm] { Array(ListeningText.terms(corrections).prefix(100)) }
    var invalidLines: Int {
        [glossary, corrections].reduce(0) { $0 + $1.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count } - terms.count - parsedCorrections.count
    }
    func activeTerms(for text: String) -> [GlossaryTerm] {
        Array(terms.filter {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: $0.source) + #"(?![\p{L}\p{N}])"#
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.prefix(16))
    }
}
