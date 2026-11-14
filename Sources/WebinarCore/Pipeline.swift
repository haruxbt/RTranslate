import Foundation

public enum SpeechPacing {
    public static func speed(base: Double, backlog: Int, automatic: Bool) -> Double {
        let base = min(2, max(0.75, base))
        guard automatic else { return base }
        return max(base, backlog >= 3 ? 1.5 : base)
    }
}

/// Audio-time identity, never text identity: repeated spoken sentences are legitimate.
public struct FinalRangeGate {
    public private(set) var end: Double = -.infinity
    public init() {}
    public mutating func accept(start: Double, duration: Double) -> Bool {
        guard start.isFinite, duration.isFinite, duration > 0, start >= end - 0.025 else { return false }
        end = start + duration
        return true
    }
}

public struct TranscriptLine: Identifiable, Codable, Sendable {
    public let id: UUID
    public let english: String
    public var japanese: String?
    public var note: String
    public let audioEnd: Double?
    public let finalAt: Double
    public var translatedAt: Double?
    public var speechAt: Double?
    public var replayedAt: Double?
    public var recognizedAt: Double?
    public var segmentationReason: String?
    public var translationInput: String?
    public var originalJapanese: String?
    public var sessionID: UUID?
    public var skipTranslation: Bool?
    public var createdAt: Date?
    public init(id: UUID = UUID(), english: String, audioEnd: Double?, finalAt: Double) {
        self.id = id; self.english = english; self.audioEnd = audioEnd; self.finalAt = finalAt
        note = "翻訳待ち"; createdAt = Date()
    }
}

/// Change detection requires a changed frame followed by stable frames.
public struct SlideStability {
    public private(set) var revision: Int = 0
    private var previous: [UInt8] = []
    private var changed = true
    private var stableCount = 0
    public init() {}
    public mutating func observe(_ pixels: [UInt8]) -> Bool {
        guard !pixels.isEmpty else { return false }
        defer { previous = pixels }
        let delta: Double
        if previous.count != pixels.count { delta = 255 }
        else { delta = zip(previous, pixels).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels.count) }
        if delta > 3 { revision += 1; changed = true; stableCount = 0; return false }
        stableCount += 1
        if changed && stableCount >= 2 { changed = false; return true }
        return false
    }
}
