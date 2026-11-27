import Foundation

public struct ListeningUnit: Codable, Sendable {
    public var id: UUID
    public var english: String
    public var audioEnd: Double?
    public var mediaStart: Double?
    public var mediaEnd: Double?
    public var recognizedAt: Double
    public var reason: String
}

/// Groups final ASR ranges only. Volatile text can postpone a boundary but is never translated.
public struct ListeningAssembler {
    private var pending: ListeningUnit?
    private var lastFinalAt: Double = 0
    public let maximumWait: Double
    public init(maximumWait: Double = 14) { self.maximumWait = maximumWait }
    public var snapshot: ListeningUnit? { pending }
    public mutating func append(_ text: String, audioEnd: Double?, mediaStart: Double? = nil, mediaEnd: Double? = nil, at now: Double) -> [ListeningUnit] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var output: [ListeningUnit] = []
        if let old = pending, Self.complete(old.english), Self.wordCount(old.english) >= 24, !Self.continuation(text) {
            output += flush(reason: "文境界")
        }
        if let old = pending, old.english.count + text.count + 1 > 1600 {
            output += flush(reason: "長さ上限・途中の可能性あり")
        }
        // Exceptional oversized ASR results are bounded without discarding any words.
        var pieces: [String] = [], words: [String] = [], length = 0
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if length + word.count + 1 > 1600 && !words.isEmpty {
                pieces.append(words.joined(separator: " ")); words = []; length = 0
            }
            words.append(word); length += word.count + 1
        }
        if !words.isEmpty { pieces.append(words.joined(separator: " ")) }
        for (index, piece) in pieces.enumerated() {
            if pending == nil { pending = ListeningUnit(id: UUID(), english: piece, audioEnd: audioEnd, mediaStart: mediaStart, mediaEnd: mediaEnd, recognizedAt: now, reason: "文のまとまり待ち") }
            else { pending!.english += " " + piece; pending!.audioEnd = audioEnd; pending!.mediaEnd = mediaEnd }
            lastFinalAt = now
            if index < pieces.count - 1 { output += flush(reason: "長さ上限・途中の可能性あり") }
        }
        return output
    }
    public mutating func poll(at now: Double, partial: String = "") -> [ListeningUnit] {
        guard let item = pending else { return [] }
        if now - item.recognizedAt >= maximumWait { return flush(reason: "待ち時間上限・途中の可能性あり") }
        guard !Self.continuation(partial) else { return [] }
        let idle = now - lastFinalAt
        // Brief ASR punctuation is not a reason to translate each tiny sentence alone.
        let enough = Self.wordCount(item.english) >= 24
        if Self.complete(item.english) && idle >= (enough ? 1.8 : 4.0)
            && partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return flush(reason: enough ? "文末" : "短文・無音で確定")
        }
        if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && idle >= 4.0 && Self.canStand(item.english) {
            return flush(reason: "発話の区切り")
        }
        return []
    }
    public mutating func flush(reason: String) -> [ListeningUnit] {
        guard var item = pending else { return [] }
        item.reason = reason; pending = nil; return [item]
    }
    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
    private static func continuation(_ text: String) -> Bool {
        text.range(of: #"^\s*(unless|if|because|although|though|when|while|which|that|and|but|or|provided|rather)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func canStand(_ text: String, minimumWords: Int = 4) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return false }
        let dangling = #"\b(a|an|the|of|to|with|without|unless|if|because|although|when|while|and|or|but|than|that|which|is|are|was|were|be|have|has|will|would|could|should|can|may|might|must|do|does|did|not)\s*[.,!?;:]*$"#
        if text.range(of: dangling, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if text.range(of: #"^\s*(unless|if|although|because|when|while)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            guard let comma = text.firstIndex(of: ","), text[comma...].split(whereSeparator: \.isWhitespace).count >= 4 else { return false }
        }
        return true
    }
    private static func complete(_ text: String) -> Bool {
        let terminal = text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?".contains($0) } ?? false
        // Short acknowledgements are complete, but conditional fragments are not.
        let cue = text.range(of: #"^\s*(okay|ok|right)[.!?]*\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        return terminal && (canStand(text, minimumWords: 1) || cue)
    }
}

public struct GlossaryTerm: Codable, Equatable, Sendable {
    public let source: String
    public let target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}
public enum ListeningText {
    public static func terms(_ text: String) -> [GlossaryTerm] {
        text.split(separator: "\n").compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, pair[0].count <= 64, pair[1].count <= 96,
                  !pair.contains(where: { $0.contains("<|plamo:") }) else { return nil }
            return GlossaryTerm(source: pair[0], target: pair[1])
        }
    }
    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    public static func normalizeZeroDay(_ text: String) -> String {
        let compound = #"\b(?:zero|0)[-‐‑– ]day(?=\s+(?:vulnerabilit(?:y|ies)|exploits?|attacks?|flaws?|threats?)\b)"#
        let standalone = #"\b(?:zero|0) day(?=\s*[.!?,;:]?\s*$)"#
        let normalized = replace(replace(text, compound, "zero-day"), #"\bzero[-‐‑–]day(s?)\b"#, "zero-day$1")
        if normalized.range(of: #"^\s*(?:zero|0) day[.!?]?\s*$|\b(?:an? |the |another |new )(?:zero|0) day[.!?]?\s*$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
            return replace(normalized, standalone, "zero-day")
        }
        return normalized
    }

    public static func preserveZeroDay(_ japanese: String, source: String) -> String {
        let term = #"\bzero-days?\b"#
        guard source.range(of: term, options: [.regularExpression, .caseInsensitive]) != nil else { return japanese }
        let adjacent = #"(?<![0-9０-９])[0０]\s*日\s*(?:の\s*)?(?=脆弱性|ぜい弱性|攻撃|エクスプロイト|脅威|欠陥)"#
        let fixed = replace(japanese, adjacent, "ゼロデイ")
        let otherWords = replace(source, term, "")
        if otherWords.range(of: #"\b(?:days?|hours?|dates?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return fixed
        }
        return replace(fixed, #"(?<![0-9０-９])[0０]\s*日(?!\s*(?:間|目|後|前|以内|以上|以下|未満|分|毎))"#, "ゼロデイ")
    }

    public static func correctSecurityTerms(_ original: String, context: String = "") -> String {
        let evidence = original + " " + context
        func contains(_ pattern: String) -> Bool {
            evidence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var text = original
        if contains(#"\b(?:security operations|cybersecurity|SOC|SIEM|incident response|threat detection)\b"#) {
            text = replace(text, #"\bsocks?\b(?=\s+(?:teams?|analysts?|operations|workflows?|work)\b)"#, "SOC")
            text = replace(text, #"\bsocks\b(?=\s+(?:monitor|triage|investigate|handle|share)\s+(?:security\s+)?(?:alerts|threats|incidents)\b)"#, "SOCs")
        }
        if contains(#"\b(?:software bill of materials|software supply chain|software dependencies|SBOMs?)\b"#) {
            text = replace(text, #"\bS[-– ]?bomb(s?)\b"#, "SBOM$1")
            text = replace(text, #"\bS\s*爆弾"#, "SBOM")
        }
        if contains(#"\b(?:cryptography|cryptographic|cryptographic bill of materials|CBOMs?)\b"#) {
            text = replace(text, #"\bC[-– ]?bomb(s?)\b"#, "CBOM$1")
            text = replace(text, #"\bC\s*爆弾"#, "CBOM")
        }
        return text
    }
    public static func english(_ original: String, smooth: Bool, corrections: [GlossaryTerm]) -> String {
        var text = original
        for entry in corrections {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: entry.source) + #"(?![\p{L}\p{N}])"#
            // A replacement is literal user data, never a regex replacement expression.
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches.reversed() { if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: entry.target) } }
            }
        }
        guard smooth else { return text }
        text = replace(text, #"\b(uh+|um+|erm+)\b[,\s]*"#, " ")
        text = replace(text, #"^\s*(well|okay|ok)\s*,\s*"#, "")
        text = replace(text, #"\b(really|very)(?:\s*,?\s+\1\b)+"#, "$1")
        text = replace(text, #",\s*(okay|ok|right)\?"#, ".")
        text = replace(text, #"(^|[.!?]\s+)(okay|ok|right)[?!]+(?=\s|$)"#, "$1")
        text = replace(text, #"\.\s+(?=(unless|if|because|although|when|while|which|that)\b)"#, " ")
        text = replace(text, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
    public static func japanese(_ original: String, smooth: Bool) -> String {
        guard smooth else { return original }
        var text = replace(original, #"(^|[。！？]\s*)(ええと|えーと|えっと|えー|あー|まあ)[、,\s]+"#, "$1")
        text = replace(text, #"本当に[、,\s]*本当に"#, "本当に")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
