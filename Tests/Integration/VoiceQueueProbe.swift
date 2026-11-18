import Foundation
import AVFoundation

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
@main struct VoiceQueueProbe {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = ["voiceEngine", "voiceVolume", "voiceSpeed", "voicevoxSpeaker", "voiceIdentifier", "voiceAutoSpeed"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let voice = VoiceQueue()
        voice.engine = "VOICEVOX"; voice.voicevox.ready = true
        voice.volume = 0; voice.speed = 1.5; voice.enabled = true
        let ids = (0..<16).map { _ in UUID() }
        var started: [UUID] = [], finished: [UUID] = [], failure: String?
        var maxPace = 0.0, maxPrepared = 0, maxPreparedBytes = 0
        var startTimes: [Double] = [], finishTimes: [Double] = []
        voice.onFailure = { failure = $0 }
        voice.onState = { id, state, time, _ in
            if let time { started.append(id); startTimes.append(time); maxPace = max(maxPace, voice.effectiveSpeed) }
            if state == "読了" { finished.append(id); finishTimes.append(ProcessInfo.processInfo.systemUptime) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for (n, id) in ids.enumerated() {
            let text = n == 2 ? "ここでは情報セキュリティの責任について説明します。条件を確認し、数値や否定表現を変えず、長い文章も順番に最後まで読み上げます。次の文章を準備しながら再生し、短い文章から長い文章へ移る場合の待ち時間を測定します。" : "順番に読み上げます。番号は\(n + 1)です。"
            voice.enqueue(id: id, text: text)
        }
        var maxLag = 0.0
        while finished.count < ids.count && failure == nil && ProcessInfo.processInfo.systemUptime - start < 90 {
            try await Task.sleep(for: .milliseconds(200))
            maxPrepared = max(maxPrepared, voice.preparedCount); maxPreparedBytes = max(maxPreparedBytes, voice.preparedBytes)
            voice.updateLag(); maxLag = max(maxLag, voice.lag)
        }
        let result: [String: Any] = ["queued": ids.count, "started": started.count, "finished": finished.count,
                                   "order_preserved": started == ids && finished == ids,
                                   "seconds": ProcessInfo.processInfo.systemUptime - start,
                                   "maximum_speed": maxPace, "maximum_wait_seconds": maxLag,
                                   "prepared_max": maxPrepared, "prepared_bytes_max": maxPreparedBytes,
                                   "between_sentence_gaps": zip(startTimes.dropFirst(), finishTimes).map { max(0, $0 - $1) },
                                   "paused_for_lag": voice.pausedForLag, "error": failure ?? ""]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        voice.halt()
        guard started == ids, finished == ids, failure == nil else { exit(1) }
    }
}
