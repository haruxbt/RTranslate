import Foundation
import AppKit
import Combine

@MainActor
final class LocalModelWorker: ObservableObject {
    @Published var state = "PLaMoモデル未選択"
    @Published var ready = false
    private(set) var endpoint: URL?
    private var process: Process?
    private var output = Data()
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }
    func chooseAndLoad() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "公式PLaMo 3 Translate MLX 4bitのモデルフォルダを選択してください"
        panel.title = "PLaMoモデルを選択"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let model = panel.url else { return }
            Task { @MainActor in
                UserDefaults.standard.set(true, forKey: "plamoExternalModel")
                self?.load(model: model)
            }
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    func load(model: URL) {
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path) else {
            state = "config.jsonのあるモデルフォルダを選択してください"; return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let python = resources.appendingPathComponent("Python/bin/python3.13")
        let script = resources.appendingPathComponent("plamo_worker.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            state = "MLX同梱版が必要です。開発時はREADMEのworker手順を使用。"; return
        }
        stop()
        let process = Process(); self.process = process
        process.executableURL = python
        process.arguments = ["-B", "-u", script.path, "--model", model.path, "--port", "0", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        // Avoid inheriting account credentials or user Python configuration.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
                               "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
                               "HF_HOME": NSHomeDirectory() + "/Library/Caches/WebinarNihongo/huggingface", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "HF_HUB_OFFLINE": "1"]
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        output = Data(); state = "PLaMo読み込み中（初回は時間がかかります）"; ready = false
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.process === process else { return }
                self.output.append(data)
                while let newline = self.output.firstIndex(of: 10) {
                    let line = Data(self.output[..<newline])
                    self.output.removeSubrange(...newline)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          value["event"] as? String == "ready", let port = value["port"] as? Int,
                          (1024...65535).contains(port) else { continue }
                    self.endpoint = URL(string: "http://127.0.0.1:\(port)/translate")
                    self.ready = true; self.state = "PLaMo準備完了：\(model.lastPathComponent)"
                    UserDefaults.standard.set(model.path, forKey: "plamoModelRoot")
                }
                if self.output.count > 8192 { self.output = Data() }
            }
        }
        process.terminationHandler = { [weak self] ended in Task { @MainActor in
            guard let self, self.process === ended else { return }
            self.ready = false; self.endpoint = nil; self.state = "PLaMo終了（code \(ended.terminationStatus)）。モデル／使用中ポートを確認。"; self.process = nil
        } }
        do { try process.run() }
        catch { self.process = nil; state = "PLaMo起動失敗：\(error.localizedDescription)" }
    }
    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil; endpoint = nil; ready = false; state = "PLaMoを解放しました"
    }
}
