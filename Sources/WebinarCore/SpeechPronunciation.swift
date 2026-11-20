import Foundation

public struct SpeechPronunciation: Codable, Hashable, Sendable {
    public let word: String
    public let reading: String
    public let accent: Int
    public let priority: Int

    public init(word: String, reading: String, accent: Int = 0, priority: Int = 5) {
        self.word = word
        self.reading = reading
        self.accent = accent
        self.priority = priority
    }

    public var valid: Bool {
        let small = "ァィゥェォャュョヮ"
        guard (1...64).contains(word.count), word == word.trimmingCharacters(in: .whitespacesAndNewlines),
              word.rangeOfCharacter(from: .controlCharacters) == nil,
              (1...64).contains(reading.count), reading.range(of: "^[ァ-ヴー]+$", options: .regularExpression) != nil,
              let head = reading.first, !small.contains(head), head != "ー",
              reading.range(of: "[\(small)]{2}", options: .regularExpression) == nil else { return false }
        return (0...reading.filter { !small.contains($0) }.count).contains(accent) && (0...10).contains(priority)
    }
    public var replacement: GlossaryTerm { GlossaryTerm(source: word, target: reading) }
}
