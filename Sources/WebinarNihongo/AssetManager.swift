import Foundation
import Combine

@MainActor final class AssetManager: ObservableObject {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RTranslate/Assets") }
    @Published var ready = false
    @Published var message = "モデルを確認しています"
    var onReady: (() -> Void)?
    private var process: Process?
    private var output = Data()
    func prepare() {
        guard process == nil, let resources = Bundle.main.resourceURL else { return }
        ready = false; message = "モデルを確認しています"
        let child = Process(); process = child
        child.executableURL = resources.appendingPathComponent("Python/bin/python3.13")
        child.arguments = ["-B", "-u", resources.appendingPathComponent("asset_worker.py").path, "--catalog", resources.appendingPathComponent("AssetCatalog/catalog.json").path, "--support", resources.appendingPathComponent("AssetSupport").path, "--root", Self.root.path]
        child.environment = ["PATH":"/usr/bin:/bin", "HOME":NSHomeDirectory(), "TMPDIR":NSTemporaryDirectory(), "PYTHONNOUSERSITE":"1", "PYTHONDONTWRITEBYTECODE":"1"]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice; output = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.output.append(data)
                while let end = self.output.firstIndex(of: 10) {
                    let line = Data(self.output[..<end]); self.output.removeSubrange(...end)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    self.message = obj["message"] as? String ?? self.message
                    if obj["event"] as? String == "ready" { self.ready = true; self.onReady?() }
                }
            }
        }
        child.terminationHandler = { [weak self] ended in Task { @MainActor in
            guard let self, self.process === ended else { return }; self.process = nil
            if ended.terminationStatus != 0 { self.ready = false; self.message = "モデルの準備に失敗：\(self.message)" }
        } }
        do { try child.run() } catch { process = nil; message = error.localizedDescription }
    }
    func stopForRemoval() async throws {
        let child = process; cancel(); let deadline = ProcessInfo.processInfo.systemUptime + 3
        while child?.isRunning == true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("ダウンロードの終了を待って、もう一度実行してください。") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func cancel() { process?.terminate(); process = nil; ready = false; message = "モデル未準備" }
}
