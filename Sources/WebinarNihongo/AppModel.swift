import AppKit
import SwiftUI
import Translation
import ScreenCaptureKit
import WebinarCore
import Combine
import SafariServices
import CoreImage

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "停止中：対象を選択してください"
    @Published var running = false
    @Published var busy = false
    @Published var windows: [SCWindow] = []
    @Published var selected: UInt32 = 0
    @Published var systemTargetSelected = false
    private var selectedFilter: SCContentFilter?
    private let sharingPicker = SharingPicker()
    private var extensionServer: ExtensionBridgeServer?
    let assets = AssetManager()
    let updates = UpdateChecker()
    private var updateObservation: AnyCancellable?
    private var browserLastSeen = Date.distantPast
    private var uninstallSelection: [String: Bool]?
    private var uninstallToken: String?
    private var browserSession: String?
    private var browserHistoryID: UUID?
    private var browserPageURL: String?
    private var browserAudio: AudioBridge?
    private var browserSequence = 0
    private var browserWatchdog = BrowserInputWatchdog(now: ProcessInfo.processInfo.systemUptime)

    @Published var partial = ""
    @Published var subtitle = "日本語字幕はここに表示されます"
    @Published var lines: [TranscriptLine] = [] { didSet { historyDirty = true } }
    // Display only this capture session. `lines` remains the complete retained archive.
    @Published private(set) var displaySessionID: UUID?
    var timelineLines: [TranscriptLine] {
        guard let displaySessionID else { return [] }
        return lines.filter { $0.sessionID == displaySessionID }
    }
    private func beginTimelineSession() {
        displaySessionID = sessionID
        activeSpeechID = nil; subtitle = "日本語字幕はここに表示されます"
    }
    @Published var historyState = "履歴はこのMacに保存されます"
    @Published var targetName = ""
    @Published var activeSpeechID: UUID?
    private var historyDirty = false
    private var historyTicks = 0
    private let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WebinarNihongo/history.json")
    @Published var backend = UserDefaults.standard.string(forKey: "translationBackend") ?? "PLaMo" {
        didSet { UserDefaults.standard.set(backend, forKey: "translationBackend") }
    }
    @Published var translationConfig: TranslationSession.Configuration?
    @Published var audioLevel: Float = 0
    @Published var pendingCount = 0
    @Published var bufferingEnglish = false
    @Published var ocrEnabled = false
    @Published var slides: [SlideBlock] = []
    @Published var regionX = 0.0
    @Published var regionY = 0.12
    @Published var regionWidth = 1.0
    @Published var regionHeight = 0.76
    @Published var cropPreview: NSImage?
    @Published var cropStatus = "Safariを選び、プレビュー上をドラッグしてください"
    @Published var cropBusy = false
    private var livePreviewRequest: UUID?
    private let previewContext = CIContext()
    @Published var testText = "Do not grant access unless MFA is enabled. The recovery time objective is 24 hours."
    @Published var resourceStatus = ""
    @Published var measurementState = "計測ログOFF（保存しません）"
    private var measurementFile: FileHandle?
    let voice = VoiceQueue()
    let localWorker = LocalModelWorker()
    let listening = ListeningPreferences()
    private var assembler = ListeningAssembler()
    private var sessionID = UUID()
    private var capture: Capture?
    private var speech: SpeechEngine?
    private let apple = AppleTranslator()
    private let plamo = PlamoTranslator()
    private let ocr = SlideOCR()
    private var gate = FinalRangeGate()
    private var generation = UUID()
    private var origin: Double?
    private var pending: [UUID] = []
    private var translateTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var timer: AnyCancellable?
    private var termination: AnyCancellable?
    private var frameBusy = false
    private var slideGeneration = UUID()
    private var slideTask: Task<Void, Never>?
    private var slideCache: [String: String] = [:]
    private var lastSound = ProcessInfo.processInfo.systemUptime
    init() {
        updateObservation = updates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        updates.check()
        voice.speechText = { [weak preferences = listening] text in preferences?.spoken(text) ?? text }
        let worker = localWorker
        plamo.endpointProvider = { [weak worker] in worker?.endpoint }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.assets.cancel(); self?.persistHistory(); self?.extensionServer?.stop(); self?.voice.voicevox.stop(); self?.localWorker.stop()
        }
        assets.onReady = { [weak self] in self?.loadPreparedAssets() }
        assets.prepare()
        voice.onBacklogLimit = { [weak self] in self?.stop(reason: "読み上げ待ちが120件を超えたため取得を停止。保存済みの訳は順に読み続けます。", finishVoice: true) }
        voice.onFailure = { [weak self] message in self?.stop(reason: "読み上げエラー：\(message)。未読は履歴に残しています。") }
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let saved = try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: historyURL))
                lines = HistoryRetention.retained(saved)
                if let latest = lines.last(where: { $0.japanese != nil }) { subtitle = latest.japanese! }
                historyDirty = saved.count != lines.count || saved.contains(where: { $0.createdAt == nil })
                historyState = "保存済みの履歴 \(lines.count)件 · 3か月保持"
                persistHistory()
            } catch { historyState = "履歴を読み込めません。既存ファイルを保護するため自動保存を停止しました"; historyWritable = false }
        }
        voice.onState = { [weak self] id, state, time, manual in
            guard let self, let index = self.lines.firstIndex(where: { $0.id == id }) else { return }
            self.lines[index].note = (manual ? "再読：" : "") + state
            if time != nil { self.activeSpeechID = id }
            else if self.activeSpeechID == id { self.activeSpeechID = nil }
            if let time {
                if manual { self.lines[index].replayedAt = time }
                else { self.lines[index].speechAt = time }
                self.logLine(manual ? "replay_started" : "speech_started", self.lines[index])
            }
        }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            if self.running {
                for unit in self.assembler.poll(at: ProcessInfo.processInfo.systemUptime, partial: self.partial) { self.addUnit(unit) }
                self.bufferingEnglish = self.assembler.snapshot != nil
            }
            self.historyTicks += 1
            if self.historyTicks % 3600 == 0 { self.pruneHistory() }
            if self.historyTicks % 3 == 0 { self.persistHistory() }
            self.writeMeasurement("checkpoint", ["running": self.running, "busy": self.busy, "lines": self.lines.count, "translationQueue": self.pendingCount, "speechQueue": self.voice.waiting, "speechLag": self.voice.lag, "speechPaused": self.voice.pausedForLag, "thermal": ProcessInfo.processInfo.thermalState.rawValue, "audioRMS": self.audioLevel, "status": self.status, "backend": self.backend, "voiceEnabled": self.voice.enabled, "ocrEnabled": self.ocrEnabled])
            self.voice.updateLag()
            if self.running, self.browserAudio != nil, self.browserWatchdog.timedOut(at: ProcessInfo.processInfo.systemUptime) {
                self.stop(reason: "タブからの音声転送が止まったため停止しました")
            }
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            self.resourceStatus = "翻訳待ち \(self.pendingCount)件 · 熱状態 \(thermal)（0=通常）"
            if self.running, self.browserAudio != nil, self.browserWatchdog.paused {
                self.status = "動画の再生を待っています"
            } else if self.running && ProcessInfo.processInfo.systemUptime - self.lastSound > 15 {
                self.status = "取得中・15秒以上音声未検出：一時停止／対象／権限を確認"
            }
        }
        extensionServer = ExtensionBridgeServer { [weak self] request in
            guard let self else { return ["ok": false, "error": "アプリが終了しました"] }
            return await self.extensionRequest(request)
        }
        do { try extensionServer?.start() }
        catch { status = "拡張との接続準備：\(error.localizedDescription)" }
    }
    private var historyWritable = true
    private func pruneHistory() {
        let retained = HistoryRetention.retained(lines)
        if retained.count != lines.count || lines.contains(where: { $0.createdAt == nil }) {
            lines = retained
            subtitle = lines.last(where: { $0.japanese != nil })?.japanese ?? "日本語字幕はここに表示されます"
        }
    }
    func persistHistory() {
        guard historyDirty, historyWritable else { return }
        do {
            var stored = lines
            if let buffered = assembler.snapshot {
                var line = makeLine(buffered)
                line.note = "確定英文をまとめ中に保存。再開後に未翻訳を再試行できます。"
                stored.append(line)
            }
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: historyURL, options: .atomic)
            historyDirty = false; historyState = "このMacに保存済み · \(lines.count)件"
        } catch { historyState = "履歴の保存に失敗しました。履歴を書き出してください：\(error.localizedDescription)" }
    }
    func importHistory() {
        guard !running, !busy, pendingCount == 0 else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "以前に書き出した文字履歴を追加します。現在の履歴は残ります。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = HistoryRetention.retained(try JSONDecoder().decode([TranscriptLine].self, from: Data(contentsOf: url)))
            pruneHistory()
            var ids = Set(lines.map(\.id))
            let additions = incoming.filter { ids.insert($0.id).inserted }
            guard lines.count + additions.count <= HistoryRetention.maximumLines else { status = "50,000区間の上限を超えるため読み込みませんでした"; return }
            lines.append(contentsOf: additions)
            if let last = lines.last(where: { $0.japanese != nil }) { subtitle = last.japanese! }
            persistHistory(); status = "履歴を\(additions.count)件追加しました"
        } catch { status = "履歴を読み込めませんでした：\(error.localizedDescription)" }
    }
    func refresh() async {
        guard !busy, !running else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.Safari" && $0.frame.width > 100 }
            if !windows.contains(where: { $0.windowID == selected }) { selected = windows.first?.windowID ?? 0 }
            status = windows.isEmpty ? "Safariの表示中ウィンドウがありません" : "Safari対象を選び、翻訳開始してください"
        } catch { status = "画面収録権限を確認：\(error.localizedDescription)" }
    }
    func chooseSystemTarget() {
        guard !running, !busy else { return }
        sharingPicker.onSelection = { [weak self] filter in
            guard let self, !self.running, !self.busy else { return }
            guard filter.includedWindows.count == 1, let window = filter.includedWindows.first,
                  window.owningApplication?.bundleIdentifier == "com.apple.Safari" else {
                self.selectedFilter = nil; self.systemTargetSelected = false
                self.status = "Safariのウィンドウを1つ選択してください"; return
            }
            self.selectedFilter = filter; self.systemTargetSelected = true
            self.cropPreview = nil
            self.targetName = window.title ?? "Safari"
            self.status = "対象：\(window.title ?? "Safari")。翻訳開始まで取得しません"
        }
        sharingPicker.onCancel = { [weak self] in self?.status = "対象選択をキャンセルしました" }
        sharingPicker.onError = { [weak self] message in self?.status = "対象選択：\(message)" }
        sharingPicker.present()
    }
    func prepareTranslation() { translationConfig = .init(source: .init(identifier: "en"), target: .init(identifier: "ja")) }
    func translationPrepared(_ session: TranslationSession) async {
        do { try await session.prepareTranslation(); status = "Apple英日翻訳の準備完了" }
        catch { status = "翻訳準備：\(error.localizedDescription)" }
        translationConfig = nil
    }
    func start() {
        guard !cropBusy else { status = "プレビュー取得の完了をお待ちください"; return }
        guard !running, !busy else { return }
        guard backend != "PLaMo" || localWorker.ready else { status = "設定でPLaMoモデルの準備を完了してください"; return }
        guard voice.engine != "VOICEVOX" || voice.voicevox.ready else { status = "設定でVOICEVOXの準備を完了してください"; return }
        let filter: SCContentFilter
        if let selectedFilter { filter = selectedFilter }
        else if let window = windows.first(where: { $0.windowID == selected }) { filter = SCContentFilter(desktopIndependentWindow: window) }
        else { return }
        voice.enabled = true
        browserSession = nil; browserHistoryID = nil; browserPageURL = nil
        busy = true; generation = UUID(); let token = generation
        gate = FinalRangeGate(); assembler = ListeningAssembler(); sessionID = UUID(); beginTimelineSession(); bufferingEnglish = false
        origin = nil; partial = ""; slides = []; slideGeneration = UUID()
        startTask = Task { [self] in
            let engine = SpeechEngine(); speech = engine
            do {
                status = "英語認識モデルを準備中（初回はダウンロードあり）"
                engine.onResult = { [weak self] result in
                    guard let self, self.generation == token else { return }; self.recognized(result)
                }
                engine.onError = { [weak self] message in self?.fail(message, token: token) }
                let bridge = try await engine.prepare(terms: listening.recognitionTerms)
                guard generation == token, !Task.isCancelled else { await engine.stop(); return }
                bridge.onOrigin = { [weak self] time in Task { @MainActor in
                    if self?.generation == token { self?.origin = time }
                } }
                bridge.onLevel = { [weak self] level in Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.audioLevel = level
                    if level > 0.002 { self.lastSound = ProcessInfo.processInfo.systemUptime; self.status = "取得中：Safari（タブ単位の音声分離は未保証）" }
                } }
                bridge.onError = { [weak self] message in Task { @MainActor in self?.fail(message, token: token) } }
                let capture = Capture(bridge: bridge); self.capture = capture
                capture.onError = { [weak self] message in Task { @MainActor in self?.fail(message, token: token) } }
                capture.onFrame = { [weak self] pixel in Task { @MainActor in
                    guard let self, self.generation == token else { return }; self.processFrame(pixel)
                } }
                status = "画面・システム音声収録の許可を確認中"
                try await capture.start(filter: filter)
                guard generation == token, !Task.isCancelled else { await capture.stop(); await engine.stop(); return }
                running = true; busy = false; lastSound = ProcessInfo.processInfo.systemUptime
                writeMeasurement("capture_started", ["backend": backend])
                status = "取得中：Safari（タブ単位の音声分離は未保証）"
            } catch {
                await engine.stop()
                if generation == token {
                    writeMeasurement("capture_start_failed", ["message": error.localizedDescription])
                    await capture?.stop(); capture = nil; speech = nil; busy = false; status = error.localizedDescription
                }
            }
        }
    }
    func stop(reason: String = "操作による停止", finishVoice: Bool = false) {
        guard !busy || startTask != nil else { return }
        for unit in assembler.flush(reason: "停止時の確定英文") { addUnit(unit, enqueue: false) }
        bufferingEnglish = false
        writeMeasurement("capture_stopping", ["reason": reason])
        generation = UUID(); slideGeneration = UUID()
        livePreviewRequest = nil; cropBusy = false
        sharingPicker.deactivate(); selectedFilter = nil; systemTargetSelected = false; selected = 0
        startTask?.cancel(); startTask = nil
        translateTask?.cancel(); translateTask = nil; slideTask?.cancel(); slideTask = nil
        apple.cancel(); if !finishVoice { voice.enabled = false }
        activeSpeechID = nil
        for id in pending {
            if let i = lines.firstIndex(where: { $0.id == id }), lines[i].japanese == nil { lines[i].note = "停止：未翻訳・履歴に保存" }
        }
        pending = []; pendingCount = 0; partial = ""; audioLevel = 0
        let oldCapture = capture, oldSpeech = speech
        capture = nil; speech = nil; browserAudio = nil; running = false; busy = true
        Task {
            await oldCapture?.stop(); await oldSpeech?.stop(); await ocr.reset()
            busy = false
            status = reason == "操作による停止" ? "停止しました（未確定の英語は保存しません）" : reason
            writeMeasurement("capture_stopped", ["reason": reason])
        }
    }
    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        writeMeasurement("pipeline_error", ["message": message])
        stop(reason: "エラー：\(message)")
    }
    private func recognized(_ result: RecognizedSpeech) {
        guard result.isFinal else { partial = result.text; return }
        guard gate.accept(start: result.start, duration: result.duration) else { return }
        partial = ""
        let end = origin.map { $0 + result.start + result.duration }
        let now = ProcessInfo.processInfo.systemUptime
        writeMeasurement("english_fragment", ["english": result.text, "audioEnd": end ?? now, "recognizedAt": now])
        for unit in assembler.append(result.text, audioEnd: end, at: now) { addUnit(unit) }
        bufferingEnglish = assembler.snapshot != nil; historyDirty = true
    }
    private func makeLine(_ unit: ListeningUnit) -> TranscriptLine {
        var line = TranscriptLine(id: unit.id, english: unit.english, audioEnd: unit.audioEnd, finalAt: ProcessInfo.processInfo.systemUptime)
        line.recognizedAt = unit.recognizedAt; line.segmentationReason = unit.reason; line.sessionID = sessionID
        line.translationInput = ListeningText.english(unit.english, smooth: listening.smooth, corrections: listening.parsedCorrections)
        line.skipTranslation = line.translationInput?.isEmpty == true
        return line
    }
    private func addUnit(_ unit: ListeningUnit, enqueue: Bool = true) {
        var line = makeLine(unit)
        if line.skipTranslation == true { line.note = "相づち・フィラーのみのため読み上げ省略（原文は保存）" }
        else if !enqueue { line.note = "停止：未翻訳・原文を保存" }
        lines.append(line)
        if enqueue && line.skipTranslation != true { pending.append(line.id) }
        pendingCount = pending.count
        logLine("english_final", line)
        if enqueue && (pending.count > 80 || lines.count >= HistoryRetention.maximumLines) {
            stop(reason: "処理待ち／履歴上限に達したため停止。履歴を書き出してください。"); return
        }
        if enqueue { pump() }
    }
    func translateTest() {
        guard !running, !busy else { return }
        sessionID = UUID(); beginTimelineSession()
        var test = ListeningAssembler()
        for unit in test.append(testText, audioEnd: nil, at: ProcessInfo.processInfo.systemUptime) { addUnit(unit) }
        for unit in test.flush(reason: "英文テスト") { addUnit(unit) }
    }
    func retryUntranslated() {
        guard translateTask == nil else { return }
        pending = lines.filter { $0.japanese == nil && $0.skipTranslation != true }.map(\.id)
        pendingCount = pending.count; pump()
    }
    private func pump() {
        guard translateTask == nil else { return }
        let token = generation
        translateTask = Task {
            while !pending.isEmpty, !Task.isCancelled, generation == token {
                let id = pending[0]
                guard let index = lines.firstIndex(where: { $0.id == id }) else { pending.removeFirst(); continue }
                let translator: TextTranslator = backend == "Apple" ? apple : plamo
                let recent = lines.prefix(index).filter { $0.sessionID == lines[index].sessionID }.suffix(2)
                let context = "Cybersecurity webinar. " + String(recent.map { $0.translationInput ?? $0.english }.joined(separator: " ").suffix(1200))
                let input = lines[index].translationInput ?? ListeningText.english(lines[index].english, smooth: listening.smooth, corrections: listening.parsedCorrections)
                plamo.glossary = listening.activeTerms(for: input + " " + context)
                do {
                    let rawJapanese = try await translator.translate(input, context: context)
                    guard generation == token, !Task.isCancelled else { return }
                    let polished = listening.displayed(ListeningText.japanese(rawJapanese, smooth: listening.smooth))
                    let japanese = polished.isEmpty ? rawJapanese : polished
                    lines[index].originalJapanese = rawJapanese == japanese ? nil : rawJapanese
                    lines[index].japanese = japanese; lines[index].translatedAt = ProcessInfo.processInfo.systemUptime
                    lines[index].note = "翻訳完了"; subtitle = japanese
                    logLine("japanese", lines[index])
                    pending.removeFirst(); pendingCount = pending.count
                    voice.enqueue(id: id, text: japanese)
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    lines[index].note = "翻訳失敗：\(error.localizedDescription)"
                    status = "翻訳停止：準備後「未翻訳を再試行」。取得は継続中なら英語を履歴に保存します。"
                    break
                }
            }
            if generation == token { translateTask = nil }
        }
    }
    func resetSlides() { slideGeneration = UUID(); slides = []; slideTask?.cancel(); Task { await ocr.reset() } }
    func captureCropPreview() {
        guard !cropBusy, !busy else { return }
        guard let filter = selectedFilter else {
            cropStatus = "先にSafariの対象ウィンドウを選択してください"; return
        }
        cropBusy = true; cropStatus = "対象ウィンドウの静止画を取得中…"
        if running {
            let request = UUID(); livePreviewRequest = request
            Task {
                try? await Task.sleep(for: .seconds(6))
                guard livePreviewRequest == request else { return }
                livePreviewRequest = nil; cropBusy = false
                cropStatus = "映像が届きませんでした。Safariの表示を確認して再試行してください。"
            }
            return
        }
        Task {
            defer { cropBusy = false }
            do {
                let image = try await CropFrameCapture().image(filter: filter)
                showCropPreview(image)
            } catch { cropStatus = "プレビュー取得：\(error.localizedDescription)" }
        }
    }
    private func showCropPreview(_ image: CGImage) {
        cropPreview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cropStatus = "スライド部分をドラッグして囲んでください。静止画は保存しません。"
    }
    func applyCrop(_ rect: CGRect) {
        guard rect.width >= 0.01, rect.height >= 0.01 else { return }
        regionX = rect.minX; regionY = 1 - rect.maxY; regionWidth = rect.width; regionHeight = rect.height
        resetSlides(); cropStatus = "選択範囲を反映しました（青枠内だけをOCRします）"
    }
    private func processFrame(_ pixel: CVPixelBuffer) {
        if livePreviewRequest != nil {
            let input = CIImage(cvPixelBuffer: pixel)
            if let image = previewContext.createCGImage(input, from: input.extent) {
                livePreviewRequest = nil; cropBusy = false; showCropPreview(image)
            }
        }
        guard running, ocrEnabled, !frameBusy else { return }
        frameBusy = true
        let token = generation
        let region = CGRect(x: regionX, y: regionY, width: min(regionWidth, 1 - regionX), height: min(regionHeight, 1 - regionY))
        Task {
            defer { frameBusy = false }
            do {
                guard let event = try await ocr.detect(pixel, region: region), generation == token, ocrEnabled else { return }
                if case .changed = event {
                    slideGeneration = UUID(); slideTask?.cancel(); slides = []; return
                }
                guard case let .ready(texts) = event else { return }
                slideGeneration = UUID(); let version = slideGeneration
                slideTask?.cancel()
                slides = texts.enumerated().map { SlideBlock(id: $0.offset + 1, english: $0.element) }
                slideTask = Task {
                    do {
                    for block in slides {
                        while pendingCount > 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
                        guard !Task.isCancelled, generation == token, slideGeneration == version, ocrEnabled else { return }
                        let key = backend + ":" + block.english
                        let translator: TextTranslator = backend == "Apple" ? apple : plamo
                        plamo.glossary = listening.activeTerms(for: block.english)
                        let translated: String
                        if let cached = slideCache[key] { translated = cached }
                        else { translated = try await translator.translate(block.english, context: "") }
                        guard !Task.isCancelled, slideGeneration == version else { return }
                        if slideCache.count > 1000 { slideCache = [:] }
                        slideCache[key] = translated
                        if let index = slides.firstIndex(where: { $0.id == block.id }) { slides[index].japanese = translated }
                    }
                    } catch { if !Task.isCancelled, slideGeneration == version { status = "スライド翻訳失敗：\(error.localizedDescription)" } }
                }
            } catch { status = "スライド認識：\(error.localizedDescription)" }
        }
    }
    func readAgain(_ line: TranscriptLine) {
        guard let text = line.japanese else { return }
        voice.enabled = true; voice.enqueue(id: line.id, text: text, manual: true)
    }
    func jumpLatest() {
        voice.halt(mark: "最新へ移動：未読・履歴に保存")
        if let line = lines.last(where: { $0.japanese != nil }) { readAgain(line) }
    }
    func chooseMeasurementFile() {
        guard measurementFile == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "webinar-measurement.jsonl"
        panel.message = "英語・日本語字幕、処理時刻、待ち件数をローカル保存します。音声と映像は保存しません。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw AppError.message("計測ファイルを作成できません") }
            measurementFile = try FileHandle(forWritingTo: url)
            measurementState = "計測ログ保存中：" + url.lastPathComponent
            writeMeasurement("measurement_started", ["backend": backend, "includesTranscripts": true])
        } catch { measurementState = "計測保存エラー：\(error.localizedDescription)" }
    }
    func stopMeasurement() {
        writeMeasurement("measurement_stopped", [:])
        try? measurementFile?.close(); measurementFile = nil
        measurementState = "計測ログOFF（保存を終了）"
    }
    private func logLine(_ event: String, _ line: TranscriptLine) {
        guard measurementFile != nil,
              let data = try? JSONEncoder().encode(line),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        writeMeasurement(event, object)
    }
    private func writeMeasurement(_ event: String, _ fields: [String: Any]) {
        guard let file = measurementFile else { return }
        var record = fields
        record["event"] = event; record["uptime"] = ProcessInfo.processInfo.systemUptime
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10); try file.write(contentsOf: data)
        } catch {
            try? file.close(); measurementFile = nil
            measurementState = "計測保存エラー：\(error.localizedDescription)"
        }
    }
    func export() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "webinar-history.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(lines).write(to: url, options: .atomic)
            status = "履歴と時刻を書き出しました（音声・映像は保存しません）"
        } catch { status = error.localizedDescription }
    }
    private func loadPreparedAssets() {
        if let root = BundledModels.resolve("voicevox", marker: "models/vvms", savedKey: "voicevoxRoot", overrideKey: "voicevoxExternalModel") { voice.voicevox.load(root: root) }
        if let root = BundledModels.resolve("plamo-3-translate-0.8b-MLX-4bit", marker: "config.json", savedKey: "plamoModelRoot", overrideKey: "plamoExternalModel") { localWorker.load(model: root) }
    }
    private func removalTargets(_ selection: [String: Bool]) throws -> [URL] {
        guard selection.keys.allSatisfy({ ["models", "history", "app"].contains($0) }), selection.values.contains(true) else { throw AppError.message("削除する項目を選んでください。") }
        var urls: [URL] = []
        if selection["models"] == true { urls.append(AssetManager.root) }
        if selection["history"] == true { urls.append(historyURL.deletingLastPathComponent()) }
        if selection["app"] == true { urls.append(Bundle.main.bundleURL) }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func managementRequest(_ command: String, selection: [String: Bool] = [:], token: String? = nil) async -> [String: Any] {
        guard ["assetsStatus", "assetsPrepare", "uninstallReview", "uninstall"].contains(command) else { return ["ok": false, "error": "操作が不明です"] }
        var value: [String: Any] = ["command": command, "selection": selection, "managementOrigin": "app"]
        if let token { value["token"] = token }
        return await extensionRequest(value)
    }
    private func safariExtensionEnabled() async -> Bool? {
        await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: "local.webinarnihongo.app.safari") { state, _ in continuation.resume(returning: state?.isEnabled) }
        }
    }
    private func extensionRequest(_ request: [String: Any]) async -> [String: Any] {
        do {
            guard let command = request["command"] as? String else { throw AppError.message("操作が不明です") }
            if request["managementOrigin"] as? String != "app" { browserLastSeen = Date() }
            if command == "assetsStatus" {
                let available = assets.ready && localWorker.ready && voice.voicevox.ready
                return ["ok": true, "ready": available, "diskReady": assets.ready, "message": assets.ready ? (available ? "利用可能（このMacの共通モデル）" : "モデルを読み込み中…") : assets.message]
            }
            if command == "assetsPrepare" {
                guard !running, !busy else { throw AppError.message("翻訳を停止してから準備してください。") }
                assets.prepare(); return ["ok": true]
            }
            if command == "uninstallReview" || command == "uninstall" {
                guard !running, !busy else { throw AppError.message("翻訳を停止してから削除してください。") }
                guard let selection = request["selection"] as? [String: Bool] else { throw AppError.message("削除内容を確認してください。") }
                let enabled = await safariExtensionEnabled()
                if request["managementOrigin"] as? String == "app", selection["models"] == true || selection["app"] == true {
                    guard enabled == false, Date().timeIntervalSince(browserLastSeen) > 300 else {
                        throw AppError.message("Safari拡張が有効、最近利用中、または状態を確認できません。拡張をOFFにしてしばらく待つか、拡張の歯車から共有データへの影響を確認して操作してください。")
                    }
                }
                let urls = try removalTargets(selection)
                if command == "uninstallReview" {
                    let bytes = urls.reduce(Int64(0)) { total, url in
                        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                        return total + (files?.allObjects as? [URL] ?? []).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                    }
                    let token = UUID().uuidString; uninstallSelection = selection; uninstallToken = token
                    return ["ok": true, "token": token, "message": "選択した項目（約\(bytes / 1_048_576) MB）をゴミ箱へ移します。共有モデルを削除すると他の拡張でも再取得が必要です。アプリ削除後はSafari設定で拡張が利用できなくなります。"]
                }
                guard selection == uninstallSelection, request["token"] as? String == uninstallToken else { throw AppError.message("削除内容をもう一度確認してください。") }
                uninstallToken = nil; uninstallSelection = nil
                try await assets.stopForRemoval(); localWorker.stop(); voice.voicevox.stop(); voice.halt()
                if selection["history"] == true, let domain = Bundle.main.bundleIdentifier,
                   let preferences = UserDefaults.standard.persistentDomain(forName: domain) {
                    let folder = historyURL.deletingLastPathComponent(); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
                    try data.write(to: folder.appendingPathComponent("settings-backup.plist"), options: .atomic)
                }
                let finalTargets = try removalTargets(selection)
                let _: Void = try await withCheckedThrowingContinuation { continuation in
                    NSWorkspace.shared.recycle(finalTargets) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
                    }
                }
                if selection["history"] == true {
                    historyWritable = false; lines = []; historyDirty = false
                    listening.glossary = ""; listening.readings = ""; listening.displayTerms = ""; listening.corrections = ""
                    voice.speed = 1.25; voice.volume = 0.6; voice.speakerID = 2; voice.autoSpeed = true
                    if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
                }
                if selection["app"] == true { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
                return ["ok": true, "message": "選択した項目をゴミ箱へ移しました。必要ならゴミ箱から戻せます。"]
            }
            if command == "dictionaryGet" {
                return ["ok": true, "dictionary": ["glossary": listening.glossary, "readings": listening.readings, "displayTerms": listening.displayTerms]]
            }
            if command == "dictionarySave" {
                guard let values = request["dictionary"] as? [String: String], Set(values.keys) == Set(["glossary", "readings", "displayTerms"]) else { throw AppError.message("辞書の内容を確認してください。") }
                for value in values.values {
                    let rows = value.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    guard value.count <= 15_000, rows.count <= 100, ListeningText.terms(value).count == rows.count else { throw AppError.message("辞書は各100件まで、用語64文字・変換先96文字以内で登録してください。") }
                }
                listening.glossary = values["glossary"]!; listening.readings = values["readings"]!; listening.displayTerms = values["displayTerms"]!
                voice.invalidatePrefetch()
                return ["ok": true]
            }
            if command == "preview" {
                guard !voice.reading else { throw AppError.message("読み上げ中です。読み上げをOFFにしてから試聴してください。") }
                applyBrowserSettings(request["settings"] as? [String: Any] ?? [:]); voice.engine = "VOICEVOX"
                if !voice.voicevox.ready, !voice.voicevox.state.contains("読み込み中"),
                   let root = BundledModels.resolve("voicevox", marker: "models/vvms", savedKey: "voicevoxRoot", overrideKey: "voicevoxExternalModel") { voice.voicevox.load(root: root) }
                let deadline = ProcessInfo.processInfo.systemUptime + 6
                while !voice.voicevox.ready {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("日本語音声の準備中です。少し待って試聴してください。") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                voice.preview(); return ["ok": true, "message": "試聴しています"]
            }
            if command == "timelineForPage" {
                guard let raw = request["url"] as? String, raw.count <= 8000,
                      let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                    throw AppError.message("表示するページを確認してください。")
                }
                guard browserPageURL == pageIdentity(url), browserHistoryID == displaySessionID, browserHistoryID != nil else {
                    return ["ok": true, "rows": [], "cursor": 0, "historySession": "", "pending": false,
                            "emptyMessage": running && browserAudio == nil ? "Macアプリ単体の翻訳です。ブラウザ内に表示する場合は、停止してSafari拡張から翻訳を開始してください。" : "このページの翻訳はまだありません。Safari拡張の翻訳開始を押してください。"]
                }
                return timelineResponse(request)
            }
            if command == "start" {
                guard assets.ready else { throw AppError.message("設定 → モデル管理で準備状況を確認してください。" ) }
                guard !running, !busy else { throw AppError.message("既に翻訳中です。停止してから開始してください。") }
                guard let key = request["session"] as? String, UUID(uuidString: key) != nil,
                      let raw = request["url"] as? String, raw.count <= 8000, let url = URL(string: raw),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AppError.message("対象タブを確認してください") }
                sharingPicker.deactivate(); selectedFilter = nil; systemTargetSelected = false; selected = 0
                browserSession = key; browserSequence = 0
                sessionID = UUID(); browserHistoryID = sessionID; browserPageURL = pageIdentity(url); beginTimelineSession()
                targetName = String((request["title"] as? String ?? url.host ?? "Safari").prefix(300))
                applyBrowserSettings(request["settings"] as? [String: Any] ?? [:])
                voice.engine = "VOICEVOX"; voice.enabled = true
                busy = true; generation = UUID(); let token = generation
                gate = FinalRangeGate(); assembler = ListeningAssembler(); pending = []; pendingCount = 0; partial = ""; bufferingEnglish = false
                backend = "PLaMo"
                if !localWorker.ready, !localWorker.state.contains("読み込み中"),
                   let root = BundledModels.resolve("plamo-3-translate-0.8b-MLX-4bit", marker: "config.json", savedKey: "plamoModelRoot", overrideKey: "plamoExternalModel") {
                    localWorker.load(model: root)
                }
                if !voice.voicevox.ready, !voice.voicevox.state.contains("読み込み中"),
                   let root = BundledModels.resolve("voicevox", marker: "models/vvms", savedKey: "voicevoxRoot", overrideKey: "voicevoxExternalModel") {
                    voice.voicevox.load(root: root)
                }
                status = "翻訳と日本語音声を準備中…"
                startTask = Task { [self] in
                    let engine = SpeechEngine(); speech = engine
                    do {
                        let deadline = ProcessInfo.processInfo.systemUptime + 120
                        while !localWorker.ready || !voice.voicevox.ready {
                            try Task.checkCancellation()
                            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("モデルを準備できませんでした。Macアプリの設定を確認してください") }
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        engine.onResult = { [weak self] result in
                            guard let self, self.generation == token else { return }; self.recognized(result)
                        }
                        engine.onError = { [weak self] message in self?.fail(message, token: token) }
                        let bridge = try await engine.prepare(terms: listening.recognitionTerms)
                        guard generation == token, !Task.isCancelled else { await engine.stop(); return }
                        bridge.onOrigin = { [weak self] time in Task { @MainActor in if self?.generation == token { self?.origin = time } } }
                        bridge.onError = { [weak self] message in Task { @MainActor in self?.fail(message, token: token) } }
                        bridge.onLevel = { [weak self] level in Task { @MainActor in
                            guard let self, self.generation == token else { return }; self.audioLevel = level
                            if level > 0.002 { self.lastSound = ProcessInfo.processInfo.systemUptime; self.status = "タブ音声を取得中" }
                        } }
                        browserAudio = bridge; browserWatchdog = BrowserInputWatchdog(now: ProcessInfo.processInfo.systemUptime)
                        running = true; busy = false; status = "タブ音声を待っています"
                    } catch {
                        await engine.stop()
                        if generation == token { browserAudio = nil; running = false; busy = false; status = error.localizedDescription }
                    }
                }
                return ["ok": true, "preparing": true, "voiceEnabled": true]
            }
            guard let key = request["session"] as? String, key == browserSession else {
                throw AppError.message("対象タブのセッションが終了しました。もう一度開始してください。")
            }
            switch command {
            case "stop": stop(); return ["ok": true, "running": false]
            case "status": return browserState()
            case "settings": applyBrowserSettings(request["settings"] as? [String: Any] ?? [:]); return ["ok": true]
            case "voice":
                if let enabled = request["enabled"] as? Bool { voice.enabled = enabled } else { voice.enabled.toggle() }
                return browserState()
            case "heartbeat":
                guard running, browserAudio != nil, let paused = request["paused"] as? Bool else { throw AppError.message("取得状態を確認してください") }
                browserWatchdog.heartbeat(paused: paused, at: ProcessInfo.processInfo.systemUptime)
                if paused { status = "動画の再生を待っています" }
                return ["ok": true]
            case "pcm":
                guard running, let browserAudio, let seq = request["sequence"] as? Int,
                      let encoded = request["pcm"] as? String, encoded.count <= 24000,
                      let data = Data(base64Encoded: encoded), data.count == 16000 else { throw AppError.message("音声データまたは取得状態を確認してください") }
                if seq < browserSequence { return ["ok": true] } // acknowledged retry, not duplicated input
                guard seq == browserSequence else { stop(reason: "音声区間が欠けたため停止しました"); throw AppError.message("音声転送の順序が一致しません") }
                browserSequence += 1; browserWatchdog.packet(at: ProcessInfo.processInfo.systemUptime)
                browserAudio.consumePCM16(data)
                return ["ok": true]
            case "timeline": return timelineResponse(request)
            default: throw AppError.message("未対応の操作です")
            }
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }
    private func pageIdentity(_ url: URL) -> String {
        var value = URLComponents(url: url, resolvingAgainstBaseURL: false)
        value?.fragment = nil
        return value?.string ?? url.absoluteString
    }
    private func timelineResponse(_ request: [String: Any]) -> [String: Any] {
        let entries = timelineLines.filter { $0.japanese != nil }
        let current = displaySessionID?.uuidString ?? ""
        let cursor = request["historySession"] as? String == current ? min(entries.count, max(0, request["cursor"] as? Int ?? 0)) : 0
        let page = entries.dropFirst(cursor).prefix(40)
        var result = browserState()
        result["rows"] = page.map { ["id": $0.id.uuidString, "japanese": $0.japanese ?? "", "receivedAt": $0.createdAt?.timeIntervalSince1970 ?? 0] as [String: Any] }
        result["cursor"] = cursor + page.count; result["historySession"] = current
        result["pending"] = pendingCount > 0 || bufferingEnglish
        result["speakingID"] = entries.first(where: { $0.id == activeSpeechID })?.id.uuidString ?? ""
        result["current"] = entries.first(where: { $0.id == activeSpeechID })?.japanese ?? entries.last?.japanese ?? ""
        result["emptyMessage"] = busy ? "音声認識と翻訳を準備しています…" : running ? (browserSequence == 0 ? "動画の音声を待っています…" : "音声を認識・翻訳しています…") : "この回の翻訳は停止しています。"
        return result
    }
    private func browserState() -> [String: Any] {
        ["ok": true, "running": running && browserAudio != nil, "preparing": busy && browserSession != nil,
         "voiceEnabled": voice.enabled, "effectiveSpeed": voice.reading ? voice.effectiveSpeed : voice.speed, "paused": browserWatchdog.paused, "message": status]
    }
    private func applyBrowserSettings(_ values: [String: Any]) {
        voice.invalidatePrefetch()
        if let volume = values["volume"] as? Double, volume.isFinite { voice.volume = Float(min(100, max(0, volume))) / 100 }
        if let speed = values["speed"] as? Double, [0.75, 1, 1.25, 1.5, 1.75, 2].contains(speed) { voice.speed = speed }
        if let speaker = values["speaker"] as? Int, [2, 3, 8, 10, 14, 52].contains(speaker) { voice.speakerID = speaker }
        if let automatic = values["autoSpeed"] as? Bool { voice.autoSpeed = automatic }
    }

}
