import AVFoundation
import Combine
import WebinarCore

@MainActor
final class VoiceQueue: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var enabled = false { didSet { if !enabled { halt(mark: "読み上げOFF・履歴に保存") } } }
    @Published var volume: Float = 0.8 { didSet { UserDefaults.standard.set(volume, forKey: "voiceVolume"); player?.volume = volume } }
    @Published var rate: Float = 0.50
    @Published var speed: Double = 1.25 { didSet { UserDefaults.standard.set(speed, forKey: "voiceSpeed") } }
    @Published var autoSpeed = true
    @Published var effectiveSpeed: Double = 1.5
    @Published var engine = "VOICEVOX" { didSet { UserDefaults.standard.set(engine, forKey: "voiceEngine") } }
    @Published var speakerID = 2 { didSet { UserDefaults.standard.set(speakerID, forKey: "voicevoxSpeaker") } }
    @Published var voiceIdentifier = "" { didSet { UserDefaults.standard.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var waiting = 0
    @Published var lag: Double = 0
    @Published var pausedForLag = false // Kept in measurement schema; backlog no longer pauses playback.
    @Published var error = ""
    @Published var previewStatus = ""
    let voicevox = VoicevoxService()
    var japaneseVoices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") } }
    private struct Job { let id: UUID; let text: String; let enqueuedAt: Double; let manual: Bool }
    private let synthesizer = AVSpeechSynthesizer()
    private let previewSynthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [Job] = []
    private var current: Job?
    private var currentUtterance: AVSpeechUtterance?
    private var synthesisTask: Task<Void, Never>?
    private var prefetchTask: Task<(Data, Double), Error>?
    private var prefetchID: UUID?
    private var prefetchSpeaker: Int?
    private var generation = UUID()
    var onState: ((UUID, String, Double?, Bool) -> Void)?
    var onBacklogLimit: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var speechText: (String) -> String = { $0 }
    func invalidatePrefetch() { prefetchTask?.cancel(); prefetchTask = nil; prefetchID = nil; prefetchSpeaker = nil }
    override init() {
        super.init(); synthesizer.delegate = self
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "voiceVolume") != nil { volume = min(1, max(0, defaults.float(forKey: "voiceVolume"))) }
        if defaults.object(forKey: "voiceSpeed") != nil {
            let saved = defaults.double(forKey: "voiceSpeed")
            speed = [0.75, 1, 1.25, 1.5, 1.75, 2].contains(saved) ? saved : 1.25
        }
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        engine = defaults.string(forKey: "voiceEngine") ?? "VOICEVOX"
        if defaults.object(forKey: "voicevoxSpeaker") != nil {
            let saved = defaults.integer(forKey: "voicevoxSpeaker")
            speakerID = [2, 3, 8, 10, 14, 52].contains(saved) ? saved : 2
        }
    }
    var credit: String { voicevox.voices.first(where: { $0.id == speakerID })?.credit ?? "VOICEVOX" }
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
    func enqueue(id: UUID, text: String, manual: Bool = false) {
        guard enabled else { onState?(id, "読み上げOFF・履歴に保存", nil, manual); return }
        queue.append(Job(id: id, text: text, enqueuedAt: ProcessInfo.processInfo.systemUptime, manual: manual))
        waiting = queue.count
        if queue.count > 120 { onBacklogLimit?() }
        playNext()
        prefetchNext()
    }
    func updateLag() {
        lag = queue.first.map { ProcessInfo.processInfo.systemUptime - $0.enqueuedAt } ?? 0
        pausedForLag = false
    }
    func resume() { playNext() }
    func halt(mark: String = "停止：未読・履歴に保存") {
        generation = UUID(); synthesisTask?.cancel(); synthesisTask = nil
        prefetchTask?.cancel(); prefetchTask = nil; prefetchID = nil
        player?.stop(); player = nil
        previewSynthesizer.stopSpeaking(at: .immediate); synthesizer.stopSpeaking(at: .immediate)
        if let current { onState?(current.id, mark, nil, current.manual) }
        for item in queue { onState?(item.id, mark, nil, item.manual) }
        queue = []; current = nil; currentUtterance = nil; waiting = 0; lag = 0; pausedForLag = false
    }
    private func playNext() {
        guard enabled, current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst(); current = job; waiting = queue.count
        effectiveSpeed = SpeechPacing.speed(base: speed, backlog: queue.count, automatic: autoSpeed)
        let spoken = speechText(job.text)
        player?.stop(); player = nil; previewSynthesizer.stopSpeaking(at: .immediate)
        onState?(job.id, "音声を準備中", nil, job.manual)
        if engine == "VOICEVOX" {
            let token = generation
            let prepared = prefetchID == job.id && prefetchSpeaker == speakerID ? prefetchTask : nil
            if prepared == nil { prefetchTask?.cancel() }
            prefetchTask = nil; prefetchID = nil
            synthesisTask?.cancel()
            synthesisTask = Task {
                do {
                    let data: Data
                    if let prepared {
                        let result = try await prepared.value
                        if result.1 == effectiveSpeed { data = result.0 }
                        else { data = try await voicevox.synthesize(spoken, speaker: speakerID, speed: effectiveSpeed) }
                    } else { data = try await voicevox.synthesize(spoken, speaker: speakerID, speed: effectiveSpeed) }
                    guard !Task.isCancelled, generation == token else { return }
                    let audio = try AVAudioPlayer(data: data); audio.volume = volume; audio.delegate = self; player = audio
                    guard audio.play() else { throw AppError.message("VOICEVOX音声を再生できません") }
                    self.error = ""
                    onState?(job.id, "読み上げ中", ProcessInfo.processInfo.systemUptime, job.manual)
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
        guard engine == "VOICEVOX", enabled, player?.isPlaying == true, let job = queue.first,
              prefetchTask == nil else { return }
        let pace = SpeechPacing.speed(base: speed, backlog: max(0, queue.count - 1), automatic: autoSpeed)
        let speaker = speakerID
        let spoken = speechText(job.text)
        prefetchID = job.id; prefetchSpeaker = speaker
        prefetchTask = Task { [voicevox] in
            let data = try await voicevox.synthesize(spoken, speaker: speaker, speed: pace)
            return (data, pace)
        }
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
