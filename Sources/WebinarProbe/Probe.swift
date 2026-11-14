import Foundation
import Speech
import AVFoundation
import Translation
import Darwin

@main struct Probe {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = CommandLine.arguments
            if args.count > 1, args[1] == "tap" {
                let requested = args.dropFirst(2).compactMap(UInt32.init)
                try await runTapProbe(mute: args.contains("--mute"), requested: requested)
                return
            }
            print("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
            print("English installed: \(await SpeechTranscriber.installedLocales.map(\.identifier).filter { $0.hasPrefix("en") })")
            let status = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "ja"))
            print("Apple English→Japanese model: \(status)")
            if args.count > 2, args[1] == "translate" {
                guard status == .installed else { print("BLOCKED: prepare Apple translation in app UI"); return }
                let session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "ja"))
                for text in args.dropFirst(2) {
                    let start = ProcessInfo.processInfo.systemUptime
                    let translated = try await session.translate(text).targetText
                    print("\(ProcessInfo.processInfo.systemUptime-start)s\t\(text)\t\(translated)")
                }
            }
            if args.count > 2, args[1] == "transcribe" {
                let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
                let preparation = ProcessInfo.processInfo.systemUptime
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
                print("ASR preparation: \(ProcessInfo.processInfo.systemUptime-preparation)s")
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let start = ProcessInfo.processInfo.systemUptime
                let task = Task {
                    for try await result in transcriber.results {
                        print("\(result.isFinal ? "FINAL" : "PARTIAL")\t\(result.range.start.seconds)\t\(result.range.duration.seconds)\t\(String(result.text.characters))")
                    }
                }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                try await task.value
                print("ASR processing: \(ProcessInfo.processInfo.systemUptime-start)s")
            }
        } catch { print("ERROR: \(error)"); exit(1) }
    }
}
