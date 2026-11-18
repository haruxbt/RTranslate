import Foundation

/// The exact spoken text and speaker identify audio. Playback speed is applied later.
public struct SpeechAudioRequest: Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let speaker: Int
    public init(id: UUID, text: String, speaker: Int) { self.id = id; self.text = text; self.speaker = speaker }
}

/// One synthesis at a time: the current sentence first, then up to five future sentences.
/// Completed audio lives only in RAM. The cap excludes the current player and one in-flight result.
@MainActor public final class SpeechAudioBuffer {
    public typealias Synthesize = @MainActor (SpeechAudioRequest) async throws -> Data
    public private(set) var preparedBytes = 0
    public var preparedCount: Int { ready.count }
    public private(set) var synthesisCount = 0
    public private(set) var cacheHits = 0
    public private(set) var inFlight: SpeechAudioRequest?
    private let limit: Int
    private let byteLimit: Int
    private let synthesize: Synthesize
    private var ahead: [SpeechAudioRequest] = []
    private var demands: [SpeechAudioRequest] = []
    private var ready: [SpeechAudioRequest: Data] = [:]
    private var failures: [SpeechAudioRequest: Error] = [:]
    private var waiters: [SpeechAudioRequest: [CheckedContinuation<Data, Error>]] = [:]
    private var pump: Task<Void, Never>?
    private var epoch = UUID()
    private var capacityBlocked: SpeechAudioRequest?

    public init(limit: Int = 5, byteLimit: Int = 24 * 1024 * 1024, synthesize: @escaping Synthesize) {
        self.limit = max(0, limit); self.byteLimit = max(0, byteLimit); self.synthesize = synthesize
    }
    public func updateAhead(_ requests: [SpeechAudioRequest]) {
        var seen = Set<SpeechAudioRequest>()
        ahead = Array(requests.filter { seen.insert($0).inserted }.prefix(limit))
        let retained = Set(ahead + demands)
        for key in Array(ready.keys) where !retained.contains(key) { removeReady(key) }
        failures = failures.filter { retained.contains($0.key) }
        if let blocked = capacityBlocked, !ahead.contains(blocked) { capacityBlocked = nil }
        startPump()
    }
    public func audio(for request: SpeechAudioRequest) async throws -> Data {
        if let audio = ready[request] {
            cacheHits += 1; removeReady(request); ahead.removeAll { $0 == request }; startPump(); return audio
        }
        if let error = failures.removeValue(forKey: request) { throw error }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[request, default: []].append(continuation)
            if !demands.contains(request) { demands.append(request) }
            ahead.removeAll { $0 == request }
            startPump()
        }
    }
    public func invalidateAhead() {
        ready.removeAll(); preparedBytes = 0; failures.removeAll(); ahead = []; capacityBlocked = nil
        // Preserve an already requested current sentence. A changed speaker/text gets a new key.
    }
    public func cancelAll() {
        epoch = UUID(); invalidateAhead(); demands = []
        let cancelled = waiters.values.flatMap { $0 }; waiters = [:]
        cancelled.forEach { $0.resume(throwing: CancellationError()) }
        // Let the one running HTTP synthesis drain. Cancelling and sending another request
        // would leave wasted synthesis jobs queued at the single-threaded VOICEVOX server.
    }
    private func removeReady(_ key: SpeechAudioRequest) {
        if let old = ready.removeValue(forKey: key) { preparedBytes -= old.count; capacityBlocked = nil }
    }
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { await run() }
    }
    private func run() async {
        while true {
            let next = demands.first ?? ahead.first(where: { ready[$0] == nil && failures[$0] == nil })
            guard let request = next else { break }
            if demands.isEmpty && (capacityBlocked == request || preparedBytes >= byteLimit) { break }
            let token = epoch
            inFlight = request; synthesisCount += 1
            do {
                let audio = try await synthesize(request)
                guard token == epoch else { inFlight = nil; continue }
                if let listeners = waiters.removeValue(forKey: request) {
                    demands.removeAll { $0 == request }
                    listeners.forEach { $0.resume(returning: audio) }
                } else if ahead.contains(request) {
                    if audio.count <= byteLimit - preparedBytes { ready[request] = audio; preparedBytes += audio.count }
                    else { capacityBlocked = request }
                }
            } catch {
                guard token == epoch else { inFlight = nil; continue }
                if let listeners = waiters.removeValue(forKey: request) {
                    demands.removeAll { $0 == request }; listeners.forEach { $0.resume(throwing: error) }
                } else if ahead.contains(request) { failures[request] = error }
            }
            inFlight = nil
        }
        inFlight = nil; pump = nil
    }
}
