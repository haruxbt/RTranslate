import Foundation

public enum PronunciationText {
    /// One pass, longest phrase first. Targets are literal text, not regex templates.
    public struct Matcher {
        private let lookup: [String: String]
        private let regex: NSRegularExpression?

        public init(_ terms: [GlossaryTerm]) {
            var lookup: [String: String] = [:]
            for term in terms where !term.source.isEmpty { lookup[term.source.lowercased()] = term.target }
            self.lookup = lookup
            let sources = lookup.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            let pattern = sources.map { source -> String in
                let escaped = NSRegularExpression.escapedPattern(for: source)
                // Match English names as whole words even when surrounded by Japanese.
                let word = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
                let left = source.unicodeScalars.first.map(word.contains) == true ? #"(?<![A-Za-z0-9_])"# : ""
                let right = source.unicodeScalars.last.map(word.contains) == true ? #"(?![A-Za-z0-9_])"# : ""
                return left + escaped + right
            }.joined(separator: "|")
            regex = pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }

        public func replacing(_ original: String) -> String {
            guard let regex else { return original }
            var result = ""
            var previous = original.startIndex
            for match in regex.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
                guard let range = Range(match.range, in: original),
                      let value = lookup[original[range].lowercased()] else { continue }
                result += original[previous..<range.lowerBound]
                result += value
                previous = range.upperBound
            }
            result += original[previous...]
            return result
        }
    }

    public static func replacing(_ original: String, terms: [GlossaryTerm]) -> String {
        Matcher(terms).replacing(original)
    }
    public static func displayed(_ original: String, terms: [GlossaryTerm] = []) -> String {
        var text = replacing(original, terms: terms)
        // Only unambiguous action phrases. Do not turn 「会場に行った」 into おこなった.
        let actions = "監査|調査|検証|確認|評価|分析|点検|実験|試験|テスト|作業|対応|実装|翻訳|説明|設定|変更|対策|訓練|トレーニング|レビュー|会議|講演"
        text = text.replacingOccurrences(of: "((?:" + actions + ")(?:など)?を)行っ", with: "$1おこなっ", options: .regularExpression)
        // 人を指す表現だけ。方法・一方・方向・比較の「〜する方がよい」は保持する。
        let people = "担当の|多くの|ほとんどの|関心のある|興味のある|資格をお持ちの|登録された|参加された|ご参加の|ご利用の"
        text = text.replacingOccurrences(of: "((?:" + people + "))方(?![\\p{Han}]|が(?:良|よ|いい))", with: "$1かた", options: .regularExpression)
        return text
    }
}
