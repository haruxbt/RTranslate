import Foundation
import AppKit
import Combine
import WebinarCore

struct VoicevoxVoice: Codable, Identifiable {
    let id: Int
    let name: String
    let credit: String
}
@MainActor
final class VoicevoxService: ObservableObject {
    @Published var ready = false
    @Published var state = "VOICEVOX未準備"
    @Published var voices: [VoicevoxVoice] = []
    private var process: Process?
    private var output = Data()
    func chooseAndLoad() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "dict・models・onnxruntimeの入ったVOICEVOXフォルダを選んでください"
        panel.title = "VOICEVOXを準備"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        UserDefaults.standard.set(true, forKey: "voicevoxExternalModel")
        load(root: root)
    }
    func load(root: URL) {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("models/vvms").path) else {
            state = "VOICEVOXのモデルフォルダがありません"; return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        stop()
        let process = Process(); self.process = process
        process.executableURL = resources.appendingPathComponent("Python/bin/python3.13")
        process.arguments = ["-B", "-u", resources.appendingPathComponent("voicevox_worker.py").path,
                             "--root", root.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        let runtime = AssetManager.root.appendingPathComponent("voicevox/onnxruntime/lib")
        if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("libvoicevox_onnxruntime.1.17.3.dylib").path) {
            process.arguments! += ["--runtime", runtime.path]
        }
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
                               "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        output = Data(); state = "VOICEVOXを読み込み中…"
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.process === process else { return }
                self.output.append(data)
                guard let end = self.output.firstIndex(of: 10) else { return }
                let line = self.output[..<end]
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   object["event"] as? String == "ready", let raw = object["voices"],
                   let json = try? JSONSerialization.data(withJSONObject: raw),
                   let voices = try? JSONDecoder().decode([VoicevoxVoice].self, from: json) {
                    self.voices = voices; self.ready = true; self.state = "VOICEVOX準備完了（CPU・ローカル）"
                    UserDefaults.standard.set(root.path, forKey: "voicevoxRoot")
                }
                self.output.removeSubrange(...end)
            }
        }
        process.terminationHandler = { [weak self] ended in Task { @MainActor in
            guard let self, self.process === ended else { return }
            self.process = nil; self.ready = false; self.state = "VOICEVOX終了（\(ended.terminationStatus)）。フォルダと使用中ポートを確認してください"
        } }
        do { try process.run() } catch { self.process = nil; state = "VOICEVOX起動失敗：\(error.localizedDescription)" }
    }
    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil; ready = false; state = "VOICEVOXを解放しました"
    }
    func synthesize(_ text: String, speaker: Int, speed: Double, pronunciations: [SpeechPronunciation] = []) async throws -> Data {
        guard ready else { throw AppError.message("設定でVOICEVOXを準備してください") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:50022/tts")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Input: Encodable {
            let text: String
            let speaker: Int
            let speed: Double
            let pronunciations: [SpeechPronunciation]
        }
        request.httpBody = try JSONEncoder().encode(Input(text: text, speaker: speaker, speed: speed, pronunciations: pronunciations))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("VOICEVOX音声合成に失敗しました") }
        return data
    }
}
