import SwiftUI
import AppKit
import Translation
import WebinarCore
import Combine

@main
struct WebinarApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("R翻訳", id: "main") {
            TimelineView(model: model)
        }.defaultLaunchBehavior(CommandLine.arguments.contains("--extension-service") ? .suppressed : .presented)
            .defaultPosition(.topTrailing).defaultSize(width: 400, height: 820)
            .windowResizability(.contentSize)
            .commands { AppCommands() }
        Window("翻訳タイムライン", id: "captions") {
            TimelineView(model: model)
        }.defaultPosition(.topTrailing).defaultSize(width: 400, height: 820)
            .windowResizability(.contentSize)
        Window("設定", id: "preferences") {
            AppSettings(model: model).frame(width: 660, height: 680)
                .translationTask(model.translationConfig) { session in await model.translationPrepared(session) }
        }.windowResizability(.contentSize)
        MenuBarExtra("R翻訳", systemImage: model.updates.hasUpdate ? "bell.badge" : model.running ? "captions.bubble.fill" : "captions.bubble") {
            MenuContent(model: model)
        }
    }
}
struct AppCommands: Commands {
    @Environment(\.openWindow) var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("設定…") { openWindow(id: "preferences"); NSApp.activate(ignoringOtherApps: true) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
struct TimelinePlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacementView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class PlacementView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !UserDefaults.standard.bool(forKey: "timelineLayoutV1") else { return }
            DispatchQueue.main.async {
                guard let screen = window.screen ?? NSScreen.main else { return }
                let area = screen.visibleFrame
                let height = min(820, area.height)
                window.setFrame(NSRect(x: area.maxX - 400, y: area.maxY - height, width: 400, height: height), display: true)
                UserDefaults.standard.set(true, forKey: "timelineLayoutV1")
            }
        }
    }
}
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.running ? (model.status.contains("音声未検出") ? "音声が届いていません" : "翻訳中") : "停止中")
        Button("タイムラインを表示") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("設定…") { openWindow(id: "preferences"); NSApp.activate(ignoringOtherApps: true) }
        Button("停止") { model.stop() }.disabled(!model.running && !model.busy)
        Divider()
        Button("終了") { model.stop(); model.persistHistory(); model.stopMeasurement(); model.localWorker.stop(); model.voice.voicevox.stop(); NSApp.terminate(nil) }
    }
}
final class TimelineState: ObservableObject {
    @Published var following = true
    @Published var showEnglish = false
    @Published var showingSlides = false
}
struct TimelineView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @StateObject private var viewState = TimelineState()
    private var latestID: UUID? { model.timelineLines.last(where: { $0.japanese != nil })?.id }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("R翻訳").font(.headline)
                    Label(model.running ? (model.status.contains("音声未検出") ? "音声が届いていません" : "翻訳中") : model.busy ? "準備・停止処理中" : "停止中",
                          systemImage: model.running ? "circle.fill" : "pause.circle")
                        .font(.caption).foregroundStyle(model.running ? Color.green : .secondary)
                }
                Spacer()
                Button { openWindow(id: "preferences"); NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "gearshape").font(.title3)
                }.buttonStyle(.plain).accessibilityLabel("設定")
                .contextMenu {
                    Toggle("英語原文を表示", isOn: $viewState.showEnglish)
                    Toggle("スライド訳を表示", isOn: $viewState.showingSlides)
                    Button("履歴を書き出す") { model.export() }
                    Button("以前の履歴を追加") { model.importHistory() }.disabled(model.running || model.busy || model.pendingCount > 0)
                    Button("未翻訳を再試行") { model.retryUntranslated() }
                    Button("設定…") { openWindow(id: "preferences"); NSApp.activate(ignoringOtherApps: true) }
                }
            }.padding(16)
            if model.updates.hasUpdate { Text("更新情報があります。設定で確認してください。").font(.caption).foregroundStyle(.orange).padding(8) }
            Divider()
            if viewState.showingSlides {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("スライド訳").font(.headline)
                        if model.slides.isEmpty { Text("設定でスライドOCRを有効にしてください").foregroundStyle(.secondary) }
                        ForEach(model.slides) { block in
                            Text("\(block.id). \(block.japanese ?? "翻訳待ち")")
                            if viewState.showEnglish { Text(block.english).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 190)
                Divider()
            }
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.timelineLines.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("英語ウェビナーを、\n日本語で読み返す。").font(.title2.bold())
                                Text("下のボタンでSafariのウィンドウを選び、翻訳を開始してください。会話はここに残ります。")
                                    .foregroundStyle(.secondary)
                            }.padding(.vertical, 40)
                        }
                        ForEach(model.timelineLines) { line in
                            TimelineRow(line: line, latest: false,
                                        speaking: false, showEnglish: viewState.showEnglish,
                                        replay: { model.readAgain(line) })
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(minHeight: max(0, geometry.size.height - 32), alignment: .bottom).padding(16)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { viewState.following = false }
                }
                .onAppear { if viewState.following { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.timelineLines.last?.id) { _, _ in if viewState.following { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.displaySessionID) { _, _ in viewState.following = true; proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: latestID) { _, _ in if viewState.following { proxy.scrollTo("bottom", anchor: .bottom) } }
                .safeAreaInset(edge: .bottom) {
                    if !viewState.following {
                        Button { viewState.following = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                            Label("最新へ", systemImage: "arrow.down")
                        }.buttonStyle(.borderedProminent).padding(8)
                    }
                }
                }
            }
            Divider()
            CurrentTranslation(model: model).frame(height: 176)
            Divider()
            TransportControls(model: model).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }.frame(minWidth: 350, idealWidth: 400, maxWidth: 520, minHeight: 560)
        .background(TimelinePlacement().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.persistHistory() }
    }
}
struct TimelineRow: View {
    let line: TranscriptLine
    let latest: Bool
    let speaking: Bool
    let showEnglish: Bool
    let replay: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if latest || speaking {
                Label(speaking ? "日本語を読み上げ中" : "最新の翻訳", systemImage: speaking ? "speaker.wave.2.fill" : "captions.bubble")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
            Text(line.japanese ?? (line.skipTranslation == true ? "（相づち・フィラーを省略）" : "翻訳待ち…")).font(.system(size: 17)).lineSpacing(5)
            if line.segmentationReason?.contains("可能性") == true {
                Text("上限で区切ったため、文の途中の可能性があります").font(.caption).foregroundStyle(.secondary)
            }
            if showEnglish { Text(line.english).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if line.japanese == nil || line.note.contains("失敗") { Text(line.note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if line.japanese != nil {
                    Button(action: replay) { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("この訳を読み上げる")
                }
            }
        }.textSelection(.enabled).padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background((latest || speaking) ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct TransportControls: View {
    @ObservedObject var model: AppModel
    private var active: Bool { model.running || model.busy }
    private var translationLabel: String {
        active ? "翻訳停止" : "翻訳開始"
    }
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if active { model.stop() }
                else if model.systemTargetSelected || model.selected != 0 { model.start() }
                else { model.chooseSystemTarget() }
            } label: {
                HStack(spacing: 10) {
                    Text(translationLabel).font(.system(size: 17, weight: .medium))
                    Image(systemName: active ? "pause.fill" : "play.fill")
                }.frame(maxWidth: .infinity, minHeight: 32)
            }.buttonStyle(.borderedProminent)
                .accessibilityLabel(translationLabel).help(translationLabel)
                .disabled(!active && (model.pendingCount > 0 || model.cropBusy))
            SpeechTransport(voice: model.voice, canToggle: active)
        }
    }
}
@MainActor
final class SpeechPanelState: ObservableObject {
    @Published var presented = false
    private var overButton = false
    private var overPanel = false
    private var dismissal: Task<Void, Never>?
    func hover(_ inside: Bool, panel: Bool = false) {
        if panel { overPanel = inside } else { overButton = inside }
        dismissal?.cancel()
        if inside { presented = true }
        else {
            dismissal = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, !overButton, !overPanel else { return }
                presented = false
            }
        }
    }
    func closed() {
        dismissal?.cancel(); overButton = false; overPanel = false
    }
}
struct SpeechTransport: View {
    @ObservedObject var voice: VoiceQueue
    var canToggle = true
    @StateObject private var panel = SpeechPanelState()
    var body: some View {
        Button { voice.enabled.toggle() } label: {
            Image(systemName: voice.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 17)).frame(width: 42, height: 42)
                .background(voice.enabled ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.2)))
        }.buttonStyle(.plain).disabled(!canToggle)
            .accessibilityLabel(voice.enabled ? "日本語読み上げを停止" : "日本語読み上げを開始")
            .help("日本語読み上げの開始・停止。ポインタを置くと音量と速度を調整できます。")
            .onHover { panel.hover($0) }
            .accessibilityAction(named: Text("音量と速度を調整")) { panel.presented = true }
            .contextMenu { Button("音量と速度…") { panel.presented = true } }
            .popover(isPresented: $panel.presented, arrowEdge: .bottom) {
                SpeechAdjustments(voice: voice).padding(16).frame(width: 270)
                    .onHover { panel.hover($0, panel: true) }
                    .onDisappear { panel.closed() }
            }
    }
}
struct SpeechAdjustments: View {
    @ObservedObject var voice: VoiceQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("音量")
                Slider(value: $voice.volume, in: 0...1).accessibilityLabel("日本語音量")
                TextField("%", value: Binding(get: { Int((voice.volume * 100).rounded()) }, set: { voice.volume = Float(min(100, max(0, $0))) / 100 }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 46).accessibilityLabel("日本語音量 0から100パーセント")
                Text("%")
            }
            Picker("速度", selection: $voice.speed) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                    Text(String(format: "×%g", value)).tag(value)
                }
            }
        }
    }
}
final class SettingsPageState: ObservableObject { @Published var page = 0 }
struct AppSettings: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = SettingsPageState()
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Array(["翻訳と音声", "スライド", "聞きやすさ", "モデル・更新・削除", "検証"].enumerated()), id: \.offset) { index, title in
                    Button { state.page = index } label: {
                        Text(title).font(.system(size: 12)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(state.page == index ? Color.white : Color.primary)
                            .background(state.page == index ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(state.page == index ? .isSelected : [])
                }
            }.frame(width: 636, height: 28)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .clipped()
            if state.page == 0 {
            Form {
                Section("翻訳") {
                    Picker("翻訳方式", selection: $model.backend) {
                        Text("Apple Translation").tag("Apple")
                        Text("PLaMo（ローカル）").tag("PLaMo")
                    }.disabled(model.running || model.busy || model.pendingCount > 0)
                    Button("Apple翻訳を準備") { model.prepareTranslation() }
                    LocalWorkerControls(worker: model.localWorker, locked: model.running || model.busy || model.pendingCount > 0)
                }
                Section("日本語音声") { VoiceSelection(voice: model.voice) }
                Section("このアプリ") {
                    Text("R翻訳 · 個人利用版")
                    Text("PLaMo 3 Translate 0.8Bと音声モデルは共通フォルダへ取得します。Built with PLaMo").font(.caption)
                    Button("導入手順・ライセンスを開く") {
                        if let resources = Bundle.main.resourceURL { NSWorkspace.shared.open(resources) }
                    }
                }
                Section("履歴と取得") {
                    Text("確定した原文と日本語訳をこのMacに3か月保存します。起動時と起動中は1時間ごとに期限切れを削除します。書き出したファイル・手動バックアップは対象外です。音声・映像は保存しません。")
                    Text(model.historyState).foregroundStyle(.secondary)
                    Button("履歴を書き出す") { model.export() }
                    Text("Safariの他のタブ・ウィンドウの音声も入ることがあります。ほかの再生は停止してください。原音量の制御は未実装です。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            }
            if state.page == 1 { SlideSettings(model: model) }
            if state.page == 2 { ListeningSettings(preferences: model.listening, locked: model.running || model.busy) }
            if state.page == 3 { MaintenanceSettings(model: model, assets: model.assets, updates: model.updates) }
            if state.page == 4 {
            Form {
                Text(model.status).textSelection(.enabled)
                Text("履歴 \(model.lines.count)件 · 翻訳待ち \(model.pendingCount)件").font(.caption)
                Text(model.targetName).font(.caption)
                Text(model.resourceStatus)
                Button("計測ログの保存先を選ぶ") { model.chooseMeasurementFile() }
                Button("計測保存を終了") { model.stopMeasurement() }
                Text(model.measurementState).font(.caption)
                TextField("翻訳テストの英文", text: $model.testText)
                Button("この英文を翻訳") { model.translateTest() }.disabled(model.running || model.busy)
                Button("未翻訳を再試行") { model.retryUntranslated() }
                Text("保存上限は50,000区間です。3か月以内の履歴は上限でも消さずに取得を停止します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            }
        }.frame(width: 636, height: 656, alignment: .top).padding(12)
    }
}
struct VoiceSelection: View {
    @ObservedObject var voice: VoiceQueue
    var body: some View {
        Picker("音声合成", selection: $voice.engine) {
            Text("VOICEVOX（ローカル）").tag("VOICEVOX")
            Text("macOS標準").tag("Apple")
        }
        if voice.engine == "VOICEVOX" { VoicevoxControls(voice: voice, service: voice.voicevox) }
        else {
            Picker("声", selection: $voice.voiceIdentifier) {
                Text("日本語の標準音声").tag("")
                ForEach(voice.japaneseVoices, id: \.identifier) { item in Text(item.name).tag(item.identifier) }
            }
        }
        Toggle("待ちが3件以上なら自動加速（最大×1.5）", isOn: $voice.autoSpeed)
        Button("選んだ声を試聴") { voice.preview() }
        if !voice.previewStatus.isEmpty { Text(voice.previewStatus).font(.caption) }
        if !voice.error.isEmpty { Text(voice.error).foregroundStyle(.red) }
    }
}
struct VoicevoxControls: View {
    @ObservedObject var voice: VoiceQueue
    @ObservedObject var service: VoicevoxService
    var body: some View {
        HStack {
            Button("VOICEVOXを準備") { service.chooseAndLoad() }
            Button("解放") { voice.halt(); service.stop() }
        }.disabled(voice.enabled)
        Text(service.state).font(.caption)
        if !service.voices.isEmpty {
            Picker("VOICEVOXの声", selection: $voice.speakerID) {
                ForEach(service.voices) { item in Text(item.name).tag(item.id) }
            }
        }
        Text(voice.credit).font(.caption)
        Text("ノーマル音声のみ。読み上げ時に必要なモデル1つだけを読み込みます。話者切替後の最初の発声には準備時間が加わります。")
            .font(.caption).foregroundStyle(.secondary)
    }
}
struct LocalWorkerControls: View {
    @ObservedObject var worker: LocalModelWorker
    var locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("PLaMoモデルを選択・準備") { worker.chooseAndLoad() }.disabled(locked)
                Button("モデルを解放") { worker.stop() }.disabled(locked)
            }
            Text(worker.state).font(.caption).textSelection(.enabled)
            Text("Built with PLaMo").font(.caption).foregroundStyle(.secondary)
        }
    }
}
