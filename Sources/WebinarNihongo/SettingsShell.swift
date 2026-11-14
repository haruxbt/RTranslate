import SwiftUI
import AppKit
import Combine
import SafariServices

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, dictionary, slides, models, history, support
    var id: String { rawValue }
    var title: String { switch self { case .overview: "概要"; case .dictionary: "辞書"; case .slides: "スライド"; case .models: "モデル"; case .history: "履歴"; case .support: "サポート" } }
}
private let settingsAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.56, green: 0.62, blue: 1, alpha: 1) : NSColor(srgbRed: 0.102, green: 0.153, blue: 0.573, alpha: 1)
})
extension Notification.Name { static let rTranslateOpenSettings = Notification.Name("RTranslate.openSettings") }
struct BrandStatusIcon: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private var image: NSImage? {
        guard let root = Bundle.main.resourceURL, let icon = NSImage(contentsOf: root.appendingPathComponent("MenuBarTemplate.png")) else { return nil }
        icon.isTemplate = true; return icon
    }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "waveform") }
        }.frame(width: 20, height: 18)
            .overlay(alignment: .topTrailing) { if model.updates.hasUpdate || model.updates.checkFailed || model.updates.modelCheckFailed || model.updates.appState == "unconfigured" || !model.assets.ready { Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 5, y: -3) } }
            .padding(.trailing, 6).padding(.top, 3)
            .accessibilityLabel("R翻訳")
            .onReceive(NotificationCenter.default.publisher(for: .rTranslateOpenSettings)) { _ in openWindow(id: "preferences"); NSApp.activate(ignoringOtherApps: true) }
    }
}
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18))) }
}
struct SettingsHeading: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 26, weight: .semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8) }
}
struct StatusPill: View {
    let text: String
    var good = true
    var body: some View { Text(text).font(.caption).padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(good ? Color.teal : Color.orange).background((good ? Color.teal : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 7)) }
}
struct AppSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32); Text("R翻訳").font(.headline) }.padding(.bottom, 22)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.settingsPage = page } label: { Text(page.title).font(.system(size: 14)).padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 39, alignment: .leading).background(model.settingsPage == page ? settingsAccent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(model.settingsPage == page ? settingsAccent : Color.secondary) }.buttonStyle(.plain).accessibilityAddTraits(model.settingsPage == page ? .isSelected : [])
                }
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(width: 152).frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch model.settingsPage {
                case .overview: OverviewSettings(model: model, updates: model.updates, assets: model.assets)
                case .dictionary: DictionarySettings(model: model, preferences: model.listening)
                case .slides: SlideSettings(model: model)
                case .models: ModelManagementSettings(model: model, assets: model.assets, worker: model.localWorker, voiceService: model.voice.voicevox)
                case .history: HistorySettings(model: model)
                case .support: SupportSettings(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .textBackgroundColor))
        }.frame(width: 780, height: 740).tint(settingsAccent)
    }
}
@MainActor final class OverviewState: ObservableObject {
    @Published var extensionText = "確認中…"
    @Published var extensionGood = false
    func refresh(_ model: AppModel) async {
        if model.safariRecentlyConnected { extensionText = "有効・接続待ち"; extensionGood = true; return }
        let enabled: Bool? = await withCheckedContinuation { c in SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: "local.webinarnihongo.app.safari") { state,_ in c.resume(returning: state?.isEnabled) } }
        extensionGood = enabled == true
        extensionText = enabled == true ? "有効・接続待ち" : enabled == false ? "有効化が必要" : "未確認"
    }
}
struct OverviewSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var assets: AssetManager
    @StateObject private var state = OverviewState()
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeading(title: "概要", subtitle: "更新と、翻訳を使うための準備状態を確認します。")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46); VStack(alignment: .leading, spacing: 5) { Text("R翻訳").font(.title3.weight(.semibold)); Text("現在のバージョン：\(version)") }; Spacer(); StatusPill(text: updates.appBadge, good: ["current", "ahead"].contains(updates.appState)) }
                        if let date = updates.checkedAt { Text("確認日時：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        HStack { Button(updates.checking ? "確認中…" : "更新を確認") { updates.check() }.disabled(updates.checking); Button("更新履歴") { NSWorkspace.shared.open(URL(string: "https://github.com/haruketh/RTranslate/releases")!) } }
                    }
                }
                SettingsCard {
                    HStack(alignment: .top, spacing: 20) {
                        readiness("Safari拡張", model.safariRecentlyConnected ? "接続済み" : state.extensionText, model.safariRecentlyConnected || state.extensionGood)
                        readiness("翻訳モデル", !assets.ready ? "準備が必要" : model.backend == "Apple" ? "Apple翻訳" : model.localWorker.ready ? "準備完了" : "読み込み待ち", assets.ready)
                        readiness("音声モデル", !assets.ready ? "準備が必要" : model.voice.engine == "Apple" ? "macOS標準" : model.voice.voicevox.ready ? "準備完了" : "読み込み待ち", assets.ready)
                    }
                }
                if updates.appAvailable { notice("新しいバージョンがあります", "変更点と更新方法を確認できます。", "更新内容を見る") { if let url = updates.downloadURL { NSWorkspace.shared.open(url) } } }
                if !assets.ready { notice("モデルの準備が必要です", assets.message, "モデルを準備") { model.settingsPage = .models } }
                if updates.checkFailed { notice("更新を確認できませんでした", "現在のアプリと準備済みモデルは引き続き使えます。", "再確認") { updates.check() } }
                if updates.modelCheckFailed { notice("モデルの更新を確認できませんでした", "準備済みのモデルはそのまま使えます。", "再確認") { updates.check() } }
                if updates.appState == "unconfigured" { notice("更新確認先が未設定です", "サポートの詳細で更新先を設定できます。", "設定を確認") { model.settingsPage = .support } }
                if updates.modelAvailable { notice("翻訳モデルの変更があります", "公式の重みに変更があります。動作確認前のモデルへ自動では切り替えません。", "モデルを管理") { model.settingsPage = .models } }
                HStack { Button("モデルを管理") { model.settingsPage = .models }; Button("Safariを開く") { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) } } }
                if assets.ready && !updates.hasUpdate && !updates.checkFailed && !updates.modelCheckFailed && updates.appState != "unconfigured" { Text("対応が必要な更新・モデルのお知らせはありません。").font(.caption).foregroundStyle(.secondary) }
                if !state.extensionGood { Text("Safariの設定 → 機能拡張でR翻訳を有効にしてください。開発版では試験用未署名許可も必要です。").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }.task { await state.refresh(model) }
    }
    private func readiness(_ title: String, _ value: String, _ good: Bool) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption).foregroundStyle(.secondary); Label(value, systemImage: good ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(good ? Color.teal : .orange) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func notice(_ title: String, _ detail: String, _ action: String, perform: @escaping () -> Void) -> some View { SettingsCard { VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline).foregroundStyle(.orange); Text(detail).font(.caption).foregroundStyle(.secondary); Button(action, action: perform).buttonStyle(.borderedProminent) } } }
}
struct HistorySettings: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        SettingsHeading(title: "履歴", subtitle: "このMacに保存した原文と日本語訳を管理します。")
        SettingsCard { HStack(spacing: 28) { statistic("保存済み", "\(model.lines.count)件"); statistic("保存期間", "3か月"); statistic("保存する内容", "原文・日本語訳") } }
        SettingsCard { VStack(alignment: .leading, spacing: 10) { Text("音声・映像は保存しません。").font(.headline); Text("期間を過ぎた履歴は自動削除します。書き出したファイルや手動バックアップは対象外です。").font(.caption).foregroundStyle(.secondary) } }
        Button("履歴を書き出す") { model.export() }.buttonStyle(.borderedProminent)
        Text(model.historyState).font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("保存の詳しいルール") { VStack(alignment: .leading, spacing: 10) { Text("保存上限は50,000区間です。3か月以内の履歴は上限でも消さず、取得を停止します。起動時と1時間ごとに期限切れを削除します。未確定の英語は保存しません。"); Text("URL・動画時刻に同期した過去訳の再利用は未実装です。"); Button("以前の履歴を追加") { model.importHistory() }.disabled(model.running || model.busy || model.pendingCount > 0) }.font(.caption).padding(.top, 8) }
    }.padding(24) } }
    private func statistic(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: title == "保存する内容" ? 15 : 23, weight: .medium)) }.frame(maxWidth: .infinity, alignment: .leading) }
}
