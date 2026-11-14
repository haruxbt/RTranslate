import SwiftUI
import AppKit
import Combine

@MainActor final class ModelStorageState: ObservableObject {
    @Published var translation = "確認中…"
    @Published var voice = "確認中…"
    static nonisolated func size(_ root: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL { if let value = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), value.isRegularFile == true { total += Int64(value.fileSize ?? 0) } }
        return total
    }
    func refresh() async {
        let root = AssetManager.root
        let sizes = await Task.detached { (Self.size(root.appendingPathComponent("plamo-3-translate-0.8b-MLX-4bit")), Self.size(root.appendingPathComponent("voicevox"))) }.value
        translation = ByteCountFormatter.string(fromByteCount: sizes.0, countStyle: .file)
        voice = ByteCountFormatter.string(fromByteCount: sizes.1, countStyle: .file)
    }
}
struct ModelManagementSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assets: AssetManager
    @ObservedObject var worker: LocalModelWorker
    @ObservedObject var voiceService: VoicevoxService
    @StateObject private var storage = ModelStorageState()
    private var locked: Bool { model.running || model.busy || model.pendingCount > 0 || model.voice.reading }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SettingsHeading(title: "モデル", subtitle: "Safari拡張と共有する翻訳・音声データを管理します。")
        modelCard("翻訳モデル", "PLaMo 3 Translate 0.8B / MLX 4bit", storage.translation, "plamo-3-translate-0.8b-MLX-4bit", worker.state)
        modelCard("音声モデル", "VOICEVOX / 日本語音声データ", storage.voice, "voicevox", voiceService.state)
        SettingsCard { VStack(alignment: .leading, spacing: 8) { Text("モデルはアプリの外に保存し、拡張と共用します。").font(.headline); Text("メモリ上の解放と、ディスク上のモデル削除は別です。保存済みの正常なデータは再確認で再利用します。").font(.caption).foregroundStyle(.secondary) } }
        Text(assets.message).font(.caption).foregroundStyle(.secondary)
        if model.backend == "Apple" { Button("Apple翻訳を準備") { model.prepareTranslation() }.disabled(locked) }
    }.padding(24) }.task { await storage.refresh() }.onChange(of: assets.ready) { _,_ in Task { await storage.refresh() } } }
    private func modelCard(_ title: String, _ detail: String, _ size: String, _ folder: String, _ memory: String) -> some View {
        SettingsCard { VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.headline); Spacer(); StatusPill(text: assets.ready ? "準備完了" : "準備が必要", good: assets.ready) }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            HStack { Text("保存量：\(size)").font(.caption).foregroundStyle(.secondary); Spacer(); Button(assets.ready ? "再確認" : "ダウンロード") { assets.prepare() }.disabled(locked) }
            DisclosureGroup("詳細") { VStack(alignment: .leading, spacing: 10) {
                Text(memory).font(.caption).foregroundStyle(.secondary)
                Text(AssetManager.root.appendingPathComponent(folder).path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack { Button("保存先を開く") { NSWorkspace.shared.open(AssetManager.root.appendingPathComponent(folder)) }; Button("再準備・修復") { assets.prepare() }.disabled(locked) }
                Text("再確認・修復は共通データ全体を確認します。").font(.caption).foregroundStyle(.secondary)
                Button("モデルの削除を管理") { model.settingsPage = .support }
            }.padding(.top, 10) }
        } }
    }
}
@MainActor final class SupportState: ObservableObject {
    @Published var deletion = false
    @Published var diagnostic = "モデル・拡張の状態を確認できます。"
    @Published var checking = false
}
struct SupportSettings: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = SupportState()
    @StateObject private var connection = OverviewState()
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SettingsHeading(title: "サポート", subtitle: "動作確認、導入手順、ライセンスを確認できます。")
        SettingsCard { VStack(alignment: .leading, spacing: 10) { Text("動作状態").font(.headline); Text(state.diagnostic).font(.callout).foregroundStyle(.secondary); Text(model.assets.ready ? "共通モデル：準備完了" : "共通モデル：準備が必要").font(.caption); Text("画面・音声の取得権限は翻訳開始時に確認します。").font(.caption).foregroundStyle(.secondary) } }
        HStack { Button(state.checking ? "確認中…" : "動作を確認") { diagnose() }.buttonStyle(.borderedProminent).disabled(state.checking); Button("導入手順") { NSWorkspace.shared.open(URL(string: "https://github.com/haruketh/RTranslate#readme")!) } }
        DisclosureGroup("ライセンス・クレジット") { VStack(alignment: .leading, spacing: 9) {
            Text("Built with PLaMo")
            Text(model.voice.credit)
            Text("独自コードはMIT。モデル・音声・ランタイムにはそれぞれの規約が適用されます。").foregroundStyle(.secondary)
            Button("同梱ライセンスを開く") { if let root = Bundle.main.resourceURL { NSWorkspace.shared.open(root) } }
        }.font(.caption).padding(.top, 10) }
        Divider()
        DisclosureGroup("詳細・開発者向け") { advanced.padding(.top, 12) }
        Divider()
        HStack { VStack(alignment: .leading, spacing: 6) { Text("アプリとデータの削除"); Text("対象と共有データへの影響を確認して削除します。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("削除の管理", role: .destructive) { state.deletion = true } }
        SettingsCard { VStack(alignment: .leading, spacing: 8) { Text("アップデート時の終了").font(.headline); Text("インストーラがR翻訳の通常終了を要求します。ウィンドウを閉じるだけでは終了しません。応答しない場合はインストールを止めるので、SafariとR翻訳を終了して再実行してください。自動で強制終了はしません。").font(.caption).foregroundStyle(.secondary); Button("R翻訳を終了") { NSApp.terminate(nil) } } }
    }.padding(24) }.sheet(isPresented: $state.deletion) { RemovalPanel(model: model) } }
    private func diagnose() { state.checking = true; Task { await connection.refresh(model); state.diagnostic = "Safari拡張：\(model.safariRecentlyConnected ? "接続済み" : connection.extensionText)\n\(model.assets.message)\n\(model.status)"; state.checking = false } }
    private var advanced: some View { VStack(alignment: .leading, spacing: 14) {
        Text(model.status).font(.caption).textSelection(.enabled)
        Text(model.resourceStatus).font(.caption)
        HStack { Button("計測ログの保存先を選ぶ") { model.chooseMeasurementFile() }; Button("計測保存を終了") { model.stopMeasurement() } }
        Text(model.measurementState).font(.caption).foregroundStyle(.secondary)
        TextField("翻訳テストの英文", text: $model.testText).textFieldStyle(.roundedBorder)
        HStack { Button("この英文を翻訳") { model.translateTest() }.disabled(model.running || model.busy); Button("未翻訳を再試行") { model.retryUntranslated() } }
        Text("アプリ単体の再生設定").font(.headline)
        Picker("翻訳方式", selection: $model.backend) { Text("PLaMo").tag("PLaMo"); Text("Apple Translation").tag("Apple") }.disabled(model.running || model.busy || model.pendingCount > 0)
        if model.backend == "Apple" { Button("Apple翻訳を準備") { model.prepareTranslation() } }
        VoiceSelection(voice: model.voice)
        LocalWorkerControls(worker: model.localWorker, locked: model.running || model.busy || model.pendingCount > 0)
        Button("モデルのメモリを解放") { model.voice.halt(); model.localWorker.stop(); model.voice.voicevox.stop() }.disabled(model.running || model.busy || model.pendingCount > 0)
        SettingsUpdateAdvanced(updates: model.updates)
    } }
}
struct SettingsUpdateAdvanced: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text("更新先の設定").font(.headline); TextField("HTTPSの更新一覧URL", text: $updates.manifestURL).textFieldStyle(.roundedBorder); Text(updates.appMessage).font(.caption); Text(updates.modelMessage).font(.caption); Button("更新を再確認") { updates.check() }.disabled(updates.checking) } }
}
