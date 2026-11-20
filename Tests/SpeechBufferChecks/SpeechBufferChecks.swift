import Foundation
import WebinarCore

struct CheckError: Error {}
@MainActor final class FakeSynth {
    var calls: [SpeechAudioRequest] = []
    var active = 0
    var maxActive = 0
    var bytes = 8
    var delay = 15
    func make(_ request: SpeechAudioRequest) async throws -> Data {
        calls.append(request); active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(delay))
        if request.text == "fail" { throw CheckError() }
        return Data(repeating: UInt8(request.speaker), count: bytes)
    }
}
@main struct SpeechBufferChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        fatalError("Timed out waiting for buffer")
    }
    @MainActor static func main() async throws {
        func request(_ n: Int, speaker: Int = 2, speed: Double = 1.2, id: UUID = UUID()) -> SpeechAudioRequest {
            SpeechAudioRequest(id: id, text: "sentence \(n)", speaker: speaker, speed: speed)
        }
        // Fill all five future slots with a single synthesis worker, and replenish after consumption.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let items = (0..<8).map { request($0) }
            _ = try await buffer.audio(for: items[0]); buffer.updateAhead(Array(items.dropFirst()))
            try await wait { buffer.preparedCount == 5 }
            precondition(fake.calls == Array(items.prefix(6)) && fake.maxActive == 1)
            _ = try await buffer.audio(for: items[1]); precondition(buffer.cacheHits == 1)
            buffer.updateAhead(Array(items.dropFirst(2))); try await wait { buffer.preparedCount == 5 }
            precondition(fake.calls.last == items[6]); buffer.cancelAll()
        }
        // A queued sentence may have been synthesized before the speed was changed.
        do {
            let probe = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await probe.make($0) })
            let id = UUID(), old = request(1, speed: 1.2, id: id), new = request(1, speed: 1.3, id: id)
            buffer.updateAhead([old])
            try await wait { buffer.preparedCount == 1 }
            buffer.updateAhead([new])
            _ = try await buffer.audio(for: new)
            precondition(probe.calls == [old, new])
        }

        // A reused timeline ID with different spoken text or speaker must never reuse old audio.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let id = UUID(), old = request(1, id: id), changed = request(2, speaker: 14, id: id)
            buffer.updateAhead([old]); try await wait { fake.active == 1 }
            buffer.invalidateAhead(); buffer.updateAhead([changed]); try await wait { buffer.preparedCount == 1 }
            let result = try await buffer.audio(for: changed); precondition(result.first == 14)
            precondition(fake.calls == [old, changed]); buffer.cancelAll()
        }
        // If playback catches an in-flight prefetched sentence, share that request.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let first = request(1), second = request(2)
            buffer.updateAhead([first, second]); try await wait { fake.active == 1 }
            _ = try await buffer.audio(for: first); try await wait { buffer.preparedCount == 1 }
            precondition(fake.calls == [first, second] && fake.maxActive == 1); buffer.cancelAll()
        }
        // RAM bound does not drop sentences: consuming a slot allows the next sentence to be prepared.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(byteLimit: 12, synthesize: { try await fake.make($0) })
            let items = (0..<3).map { request($0) }; buffer.updateAhead(items)
            try await wait { fake.calls.count == 2 && fake.active == 0 }
            precondition(buffer.preparedCount == 1 && buffer.preparedBytes == 8)
            for item in items { let data = try await buffer.audio(for: item); precondition(data.count == 8 && buffer.preparedBytes <= 12) }
            buffer.cancelAll()
        }
        // Halt releases demand waiters. Old in-flight results cannot enter a restarted session.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let item = request(1)
            let cancelled = Task { do { _ = try await buffer.audio(for: item); return false } catch is CancellationError { return true } catch { return false } }
            try await wait { fake.active == 1 }; buffer.cancelAll()
            let wasCancelled = await cancelled.value; precondition(wasCancelled)
            _ = try await buffer.audio(for: item)
            precondition(fake.calls.count == 2 && fake.maxActive == 1 && buffer.preparedBytes == 0)
            buffer.cancelAll()
        }
        // Pending playback takes precedence over further speculative synthesis.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let ahead = [request(1), request(2)], current = request(9)
            buffer.updateAhead(ahead); try await wait { fake.active == 1 }
            _ = try await buffer.audio(for: current)
            precondition(fake.calls.prefix(2).elementsEqual([ahead[0], current]))
            buffer.cancelAll()
        }
        // Background errors are not silent successes, and are reported when that sentence is due.
        do {
            let fake = FakeSynth(), buffer = SpeechAudioBuffer(synthesize: { try await fake.make($0) })
            let bad = SpeechAudioRequest(id: UUID(), text: "fail", speaker: 2, speed: 1.2)
            buffer.updateAhead([bad]); try await wait { fake.calls.count == 1 && fake.active == 0 }
            var failed = false; do { _ = try await buffer.audio(for: bad) } catch { failed = true }
            precondition(failed && fake.calls.count == 1); buffer.cancelAll()
        }
        print("PASS: 8 asynchronous speech buffer checks")
    }
}
