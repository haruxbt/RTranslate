import Foundation
import NaturalLanguage

public enum PageReading {
    // Keep context small enough for live translation and preserve paragraph order.
    public static func chunks(_ text: String, separateLanguages: Bool = false) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let paragraph = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            let target = hasJapanese(paragraph) ? 180 : 420
            tokenizer.string = paragraph
            var current = ""
            var currentEnglish = false
            func append(_ fragment: String) {
                let english = separateLanguages && needsEnglishTranslation(fragment)
                if !current.isEmpty && (current.count + fragment.count + 1 > target || currentEnglish != english) {
                    result.append(current)
                    current = ""
                }
                currentEnglish = english
                current += current.isEmpty ? fragment : " " + fragment
            }
            for range in tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex) {
                var sentence = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                while sentence.count > target {
                    let prefix = sentence.prefix(target)
                    let end = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
                    append(String(sentence[..<end]))
                    sentence = sentence[end...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !sentence.isEmpty { append(sentence) }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    public static func hasJapanese(_ text: String) -> Bool {
        text.range(of: #"[\p{Hiragana}\p{Katakana}\p{Han}]"#, options: .regularExpression) != nil
    }

    public static func needsEnglishTranslation(_ text: String) -> Bool {
        let latin = text.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        guard latin > 0 else { return false }
        let japanese = text.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
        }.count
        return japanese == 0 || latin >= japanese * 3
    }

    public static func containsUntranslatedProse(_ text: String) -> Bool {
        let pattern = hasJapanese(text) ? #"\b[a-z]{2,}(?:[ \t]+[a-z]{2,}){5,}\b"# :
            #"\b[A-Za-z]+(?:[\s,]+[A-Za-z]+){3,}\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
