import SwiftUI
import AppKit
import Combine
import WebinarCore

struct DictionarySettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shared: SharedPronunciations
    @StateObject private var draft = Draft()
    @FocusState private var readingFocused: Bool

    private final class Draft: ObservableObject {
        @Published var word = ""
        @Published var reading = ""
        @Published var accent = 0
        @Published var editingWord: String?
        @Published var message = ""
        @Published var shareURL: URL?
        @Published var review = false
        @Published var personalOnly = false
    }

    private var accentLimit: Int {
        let kana = draft.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            .applyingTransform(.hiraganaToKatakana, reverse: false) ?? draft.reading
        return kana.filter { !"ァィゥェォャュョヮ".contains($0) }.count
    }

    private var rows: [SpeechPronunciation] {
        let query = draft.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = draft.personalOnly ? shared.personal : shared.entries
        return entries.filter { query.isEmpty || $0.word.localizedCaseInsensitiveContains(query)
            || $0.reading.localizedCaseInsensitiveContains(query) }
            .sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        let shareable = Set(shared.unpublished)
        let personal = Set(shared.personal)
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeading(title: "辞書", subtitle: "RSpeechと共有する読み方を編集します。")
            HStack(spacing: 8) {
                TextField("単語を検索・入力", text: $draft.word).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 115).disabled(draft.editingWord != nil)
                TextField("読み方", text: $draft.reading).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 85).focused($readingFocused).onSubmit(saveWord)
                Stepper(value: $draft.accent, in: 0...accentLimit) {
                    Text("アクセント \(draft.accent)").monospacedDigit()
                }.fixedSize(horizontal: true, vertical: false)
                .help("0は平板。数字は音が下がる位置を表します。")
                Button(draft.editingWord == nil ? "追加" : "保存", action: saveWord).buttonStyle(.borderedProminent)
                    .disabled(draft.word.isEmpty || draft.reading.isEmpty)
            }
            if draft.editingWord != nil {
                Button("編集をキャンセル") { resetForm(); draft.message = "" }.buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor).font(.caption)
            }
            if !draft.message.isEmpty { Text(draft.message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Toggle("個人登録のみ", isOn: $draft.personalOnly)
                Spacer()
                if !shareable.isEmpty {
                    Button("共有候補 \(shareable.count)件") { draft.review = true }
                }
            }.font(.caption)
            tableRow("単語", "読み方", "アクセント", entry: nil)
                .font(.caption).foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("一致する単語がありません。").foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(rows, id: \.word) { row in
                        tableRow(row.word, row.reading, String(row.accent), entry: row, personal: personal.contains(row))
                            .contextMenu {
                                if shareable.contains(row), let url = SharedPronunciations.issueURL(for: [row]) {
                                    Button("共通辞書に共有…") { draft.shareURL = url }
                                }
                            }
                        Divider()
                    }
                }
            }
            HStack {
                Text(shared.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(shared.updating ? "更新中…" : "共通辞書を更新") {
                    Task {
                        if await shared.refresh(), !shared.unpublished.isEmpty { draft.review = true }
                    }
                }.disabled(shared.updating)
            }
        }
        .padding(24)
        .onAppear { shared.refreshPersonal(); openRequestedWord() }
        .onChange(of: model.dictionaryRequest) { _, _ in openRequestedWord() }
        .sheet(isPresented: $draft.review) {
            DictionarySharing(candidates: shared.unpublished)
        }
        .onChange(of: accentLimit) { _, limit in draft.accent = min(draft.accent, limit) }
        .confirmationDialog("この単語の読み方を公開共有しますか？", isPresented: Binding(
            get: { draft.shareURL != nil }, set: { if !$0 { draft.shareURL = nil } }
        ), titleVisibility: .visible) {
            Button("GitHubの投稿画面を開く") {
                if let url = draft.shareURL { NSWorkspace.shared.open(url) }
                draft.shareURL = nil
            }
        } message: {
            Text("単語・読み方・アクセントが投稿の下書きに入ります。公開する前にGitHubで内容を確認できます。")
        }
    }

    private func tableRow(_ word: String, _ reading: String, _ accent: String, entry: SpeechPronunciation?, personal: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 6) {
                Text(word).textSelection(.enabled)
                if personal {
                    Text("個人").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(reading).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text(accent).monospacedDigit().frame(width: 82, alignment: .leading)
            Group {
                if let entry {
                    Button("編集") { edit(entry) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("\(entry.word)を編集")
                } else {
                    Color.clear.frame(height: 0)
                }
            }.frame(width: 40, alignment: .trailing)
        }.padding(10)
    }

    private func openRequestedWord() {
        guard let word = model.dictionaryRequest else { return }
        model.dictionaryRequest = nil
        if let row = shared.entries.first(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            edit(row)
        } else {
            resetForm()
            draft.word = word
            readingFocused = true
        }
    }

    private func edit(_ row: SpeechPronunciation) {
        draft.editingWord = row.word
        draft.message = ""
        draft.word = row.word
        draft.reading = row.reading
        draft.accent = row.accent
        readingFocused = true
    }

    private func resetForm() {
        draft.editingWord = nil
        draft.word = ""
        draft.reading = ""
        draft.accent = 0
    }

    private func saveWord() {
        do {
            try shared.addPersonal(word: draft.editingWord ?? draft.word, reading: draft.reading, accent: draft.accent)
            model.voice.invalidatePrefetch()
            let edited = draft.editingWord != nil
            resetForm()
            draft.message = edited ? "読み方とアクセントを保存しました。" : "RSpeechの個人辞書に登録しました。"
        } catch { draft.message = error.localizedDescription }
    }
}
