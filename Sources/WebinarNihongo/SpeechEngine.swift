import AVFoundation
import Speech
import CoreMedia

struct RecognizedSpeech {
    let text: String
    let start: Double
    let duration: Double
    let isFinal: Bool
}

/// Used only on the capture's serial audio queue. Analyzer input has bounded buffering.
final class AudioBridge: @unchecked Sendable {
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
    var firstPTS: CMTime?
    private var nextTime = CMTime.zero
    var onOrigin: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    private var buffers = 0
    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format; self.continuation = continuation
    }
    func consume(_ sample: CMSampleBuffer) {
        guard sample.isValid, let desc = sample.formatDescription else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
        input.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard status == noErr else { onError?("音声バッファ変換失敗: \(status)"); return }
        consumeBuffer(input, pts: sample.presentationTimeStamp)
    }
    private var pcmFrames: Int64 = 0
    func consumePCM16(_ bytes: Data) {
        guard !bytes.isEmpty, bytes.count % 2 == 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count / 2)),
              let destination = input.int16ChannelData?[0] else { return }
        input.frameLength = input.frameCapacity
        bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: bytes.count))
        let pts = CMTime(value: pcmFrames, timescale: 16000); pcmFrames += Int64(input.frameLength)
        consumeBuffer(input, pts: pts)
    }
    private func consumeBuffer(_ input: AVAudioPCMBuffer, pts: CMTime) {
        let inputFormat = input.format, frames = input.frameLength
        if firstPTS == nil {
            firstPTS = pts
            onOrigin?(ProcessInfo.processInfo.systemUptime - Double(frames) / inputFormat.sampleRate)
        }
        if sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
        guard let converter else { onError?("認識用音声形式へ変換できません"); return }
        let count = AVAudioFrameCount(ceil(Double(frames) * format.sampleRate / inputFormat.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { onError?(error.localizedDescription); return }
        guard output.frameLength > 0 else { return }
        buffers += 1
        if buffers % 20 == 0 {
            let n = Int(output.frameLength)
            var sum: Float = 0
            if let data = output.floatChannelData?[0] {
                for i in 0..<n { sum += data[i] * data[i] }
            } else if let data = output.int16ChannelData?[0] {
                for i in 0..<n { let value = Float(data[i]) / 32768; sum += value * value }
            } else if let data = output.int32ChannelData?[0] {
                for i in 0..<n { let value = Float(data[i]) / 2147483648; sum += value * value }
            }
            onLevel?(sqrt(sum / Float(n)))
        }
        let sourceTime = CMTimeSubtract(pts, firstPTS!)
        // Resampling may add a frame relative to SCK PTS rounding. Never overlap analyzer ranges.
        let time = CMTimeMaximum(sourceTime, nextTime)
        nextTime = CMTimeAdd(time, CMTime(value: Int64(output.frameLength), timescale: Int32(format.sampleRate)))
        switch continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
        case .dropped: onError?("音声認識が取得に追いつきません。取得を停止します（音声欠落）。")
        default: break
        }
    }
}

@MainActor
final class SpeechEngine {
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    var onResult: ((RecognizedSpeech) -> Void)?
    var onError: ((String) -> Void)?
    func prepare(terms: [String] = []) async throws -> AudioBridge {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw AppError.message("このMacでは英語SpeechTranscriberが利用できません。")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError.message("対応音声形式が見つかりません")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        self.analyzer = analyzer
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(Set(["CISSP", "ISC2", "CIA triad", "confidentiality", "integrity", "availability", "zero trust", "least privilege", "MFA", "RTO", "RPO", "NIST"] + terms)).sorted()
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        self.continuation = continuation
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { break }
                    self?.onResult?(.init(text: String(result.text.characters), start: result.range.start.seconds,
                                         duration: result.range.duration.seconds, isFinal: result.isFinal))
                }
            } catch { if !Task.isCancelled { self?.onError?(error.localizedDescription) } }
        }
        inputTask = Task { [weak self] in
            do { try await analyzer.start(inputSequence: stream) }
            catch { if !Task.isCancelled { self?.onError?(error.localizedDescription) } }
        }
        return AudioBridge(format: format, continuation: continuation)
    }
    func stop() async {
        continuation?.finish(); continuation = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel(); inputTask?.cancel()
        resultTask = nil; inputTask = nil; analyzer = nil
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
