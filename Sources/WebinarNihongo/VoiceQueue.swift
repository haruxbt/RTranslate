import AVFoundation
import Combine
import WebinarCore

@MainActor
final class VoiceQueue: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var enabled = false { didSet { if !enabled { halt(mark: "読み上げOFF・履歴に保存") } } }
    @Published var volume: Float = 0.8 { didSet { UserDefaults.standard.set(volume, forKey: "voiceVolume"); player?.volume = volume } }
    @Published var rate: Float = 0.50
    @Published var speed: Double = SpeechPacing.defaultSpeed {
        didSet {
            UserDefaults.standard.set(speed, forKey: "voiceSpeed")
            if speed != oldValue { prefetchNext() }
        }
    }
    @Published var autoSpeed = UserDefaults.standard.object(forKey: "voiceAutoSpeed") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSpeed, forKey: "voiceAutoSpeed")
            if autoSpeed != oldValue { prefetchNext() }
        }
    }
    @Published var effectiveSpeed = SpeechPacing.defaultSpeed
    @Published var engine = "VOICEVOX" { didSet { UserDefaults.standard.set(engine, forKey: "voiceEngine"); if engine != oldValue { invalidatePrefetch() } } }
    @Published var speakerID = 2 { didSet { UserDefaults.standard.set(speakerID, forKey: "voicevoxSpeaker"); if speakerID != oldValue { invalidatePrefetch() } } }
    @Published var voiceIdentifier = "" { didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var waiting = 0
    @Published var lag: Double = 0
    @Published var pausedForLag = false // Kept in measurement schema; backlog no longer pauses playback.
    @Published var error = ""
    @Published var previewStatus = ""
    let voicevox = VoicevoxService()
    var japaneseVoices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") } }
    private struct Job { let id: UUID; let text: String; let enqueuedAt: Double; let manual: Bool; let mediaStart: Double? }
    private let synthesizer = AVSpeechSynthesizer()
    private let previewSynthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var videoPosition: Double?
    private var announcedPlayback = false
    private var queue: [Job] = []
    private var current: Job?
    private var currentUtterance: AVSpeechUtterance?
    private var synthesisTask: Task<Void, Never>?
    private lazy var audioBuffer = SpeechAudioBuffer { [voicevox] request in
        try await voicevox.synthesize(request.text, speaker: request.speaker, speed: request.speed, pronunciations: request.pronunciations)
    }
    var preparedCount: Int { audioBuffer.preparedCount }
    var preparedBytes: Int { audioBuffer.preparedBytes }
    private var accelerated = false
    private var generation = UUID()
    var onState: ((UUID, String, Double?, Bool) -> Void)?
    var onBacklogLimit: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var speechText: (String) -> String = { $0 }
    var localSpeech: (String, Int) -> (text: String, pronunciations: [SpeechPronunciation]) = { text, _ in (text, []) }
    private func request(for job: Job, speed: Double) -> SpeechAudioRequest {
        let speech = localSpeech(job.text, speakerID)
        return SpeechAudioRequest(id: job.id, text: speech.text, speaker: speakerID, speed: speed,
                                  pronunciations: speech.pronunciations)
    }
    func invalidatePrefetch() { audioBuffer.invalidateAhead(); prefetchNext() }
    override init() {
        super.init(); synthesizer.delegate = self
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "voiceVolume") != nil { volume = min(1, max(0, defaults.float(forKey: "voiceVolume"))) }
        if defaults.object(forKey: "voiceSpeed") != nil {
            let saved = defaults.double(forKey: "voiceSpeed")
            speed = SpeechPacing.normalized(saved)
        }
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        engine = defaults.string(forKey: "voiceEngine") ?? "VOICEVOX"
        if defaults.object(forKey: "voicevoxSpeaker") != nil {
            let saved = defaults.integer(forKey: "voicevoxSpeaker")
            speakerID = Self.canSelectSpeaker(saved) ? saved : 2
        }
    }
    static func canSelectSpeaker(_ id: Int) -> Bool {
        [2, 3, 8, 10, 14, 52].contains(id)
    }
    var credit: String {
        return voicevox.voices.first(where: { $0.id == speakerID })?.credit ?? "VOICEVOX" }
    var reading: Bool { current != nil }
    func preview() {
        guard current == nil else { return }
        let text = "こんにちは。情報セキュリティのウェビナーを日本語で読み上げます。"
        if engine == "VOICEVOX" {
            previewStatus = "試聴用の音声を準備中…"
            synthesisTask?.cancel(); let token = generation
            synthesisTask = Task {
                do {
                    let data = try await voicevox.synthesize(text, speaker: speakerID, speed: speed)
                    guard !Task.isCancelled, generation == token, current == nil else { return }
                    let audio = try AVAudioPlayer(data: data); player = audio; audio.volume = volume; audio.delegate = self
                    guard audio.play() else { throw AppError.message("音声を再生できません") }
                    error = ""; previewStatus = "VOICEVOXを試聴中"
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; self.previewStatus = "試聴に失敗しました" } }
            }
        } else {
            previewSynthesizer.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "ja-JP")
            utterance.volume = volume; utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, rate * Float(speed))
            previewSynthesizer.speak(utterance)
        }
    }
    func enqueue(id: UUID, text: String, manual: Bool = false, mediaStart: Double? = nil) {
        guard enabled else { onState?(id, "読み上げOFF・履歴に保存", nil, manual); return }
        queue.append(Job(id: id, text: text, enqueuedAt: ProcessInfo.processInfo.systemUptime, manual: manual, mediaStart: mediaStart))
        waiting = queue.count
        if queue.count > 120 { onBacklogLimit?() }
        playNext()
        prefetchNext()
    }
    func updateLag() {
        if let due = (announcedPlayback ? nil : current?.mediaStart) ?? queue.first?.mediaStart {
            lag = max(0, (videoPosition ?? due) - due)
        } else {
            lag = queue.first.map { ProcessInfo.processInfo.systemUptime - $0.enqueuedAt } ?? 0
        }
        pausedForLag = false
    }
    func resume() { playNext() }
    func setVideoPosition(_ position: Double?) {
        videoPosition = position
        if let current, current.mediaStart != nil { syncPlayer(for: current) }
        else { playNext() }
    }
    private func syncPlayer(for job: Job) {
        guard let player else { return }
        guard BrowserPlaybackClock.isDue(job.mediaStart, at: videoPosition) else {
            player.pause()
            return
        }
        guard !player.isPlaying else { return }
        guard player.play() else {
            onFailure?("VOICEVOX音声を再生できません")
            return
        }
        if !announcedPlayback {
            announcedPlayback = true
            error = ""
            onState?(job.id, "読み上げ中", ProcessInfo.processInfo.systemUptime, job.manual)
        }
    }
    func halt(mark: String = "停止：未読・履歴に保存") {
        generation = UUID(); synthesisTask?.cancel(); synthesisTask = nil
        audioBuffer.cancelAll()
        player?.stop(); player = nil
        previewSynthesizer.stopSpeaking(at: .immediate); synthesizer.stopSpeaking(at: .immediate)
        if let current { onState?(current.id, mark, nil, current.manual) }
        for item in queue { onState?(item.id, mark, nil, item.manual) }
        queue = []; current = nil; currentUtterance = nil; waiting = 0; lag = 0; pausedForLag = false; accelerated = false
    }
    private func playNext() {
        guard enabled, current == nil, let first = queue.first,
              BrowserPlaybackClock.isDue(first.mediaStart, at: videoPosition) else { return }
        let job = queue.removeFirst(); current = job; waiting = queue.count
        let queuedSeconds = queue.reduce(0.0) { $0 + SpeechPacing.estimatedSeconds(speechText($1.text), base: speed) }
        effectiveSpeed = job.mediaStart == nil
            ? SpeechPacing.speed(base: speed, queuedSeconds: queuedSeconds, automatic: autoSpeed, accelerated: &accelerated)
            : speed
        announcedPlayback = false
        let spoken = speechText(job.text)
        player?.stop(); player = nil; previewSynthesizer.stopSpeaking(at: .immediate)
        onState?(job.id, "音声を準備中", nil, job.manual)
        if engine == "VOICEVOX" {
            let token = generation
            synthesisTask?.cancel()
            let request = request(for: job, speed: effectiveSpeed)
            // Claim a prepared clip now, before an enqueue can replace the prefetch list.
            let prepared = audioBuffer.takePreparedAudio(for: request)
            synthesisTask = Task {
                do {
                    let data: Data
                    if let prepared { data = prepared }
                    else { data = try await audioBuffer.audio(for: request) }
                    guard !Task.isCancelled, generation == token else { return }
                    let audio = try AVAudioPlayer(data: data)
                    audio.volume = volume; audio.delegate = self; player = audio
                    syncPlayer(for: job)
                    prefetchNext()
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    self.error = error.localizedDescription
                    onState?(job.id, "読み上げ失敗・履歴に保存", nil, job.manual)
                    onFailure?(error.localizedDescription)
                }
            }
        } else {
            guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "ja-JP") else {
                onFailure?("日本語音声がありません"); return
            }
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = voice; utterance.volume = volume
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, rate * Float(effectiveSpeed))
            currentUtterance = utterance; synthesizer.speak(utterance)
        }
    }
    private func prefetchNext() {
        guard engine == "VOICEVOX", enabled, current != nil || queue.first?.mediaStart != nil else { return }
        var predictedAcceleration = accelerated
        let spoken = queue.map { speechText($0.text) }
        let durations = spoken.map { SpeechPacing.estimatedSeconds($0, base: speed) }
        var remaining = durations.reduce(0, +)
        let requests = queue.prefix(5).enumerated().map { index, job in
            remaining -= durations[index]
            let pace = job.mediaStart == nil
                ? SpeechPacing.speed(base: speed, queuedSeconds: remaining, automatic: autoSpeed, accelerated: &predictedAcceleration)
                : speed
            return request(for: job, speed: pace)
        }
        audioBuffer.updateAhead(requests)
    }
    private func finished() {
        if let job = current { onState?(job.id, "読了", nil, job.manual) }
        current = nil; currentUtterance = nil; player = nil; playNext()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if self.current == nil { self.previewStatus = flag ? "試聴を終了しました" : "試聴に失敗しました"; self.player = nil; return }
            if flag { self.finished() } else { self.onFailure?("音声再生に失敗しました") }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentUtterance === utterance, let job = self.current else { return }
            self.onState?(job.id, "読み上げ中", ProcessInfo.processInfo.systemUptime, job.manual)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.currentUtterance === utterance else { return }; self.finished() }
    }
}
