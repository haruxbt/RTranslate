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
    func spoken(_ text: String) -> String { PronunciationText.replacing(text, terms: ListeningText.terms(readings)) }
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
