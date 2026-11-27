import SwiftUI
import AppKit
import WebinarCore

struct DictionarySharing: View {
    let candidates: [SpeechPronunciation]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<SpeechPronunciation> = []

    var body: some View {
        let selected = candidates.filter(selection.contains)
        let url = SharedPronunciations.issueURL(for: selected)
        VStack(alignment: .leading, spacing: 14) {
            Text("共通辞書への追加候補").font(.title2.bold())
            Text("公開してよい語を選んでください。1回に最大8語を送れます。")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(candidates, id: \.self) { row in
                        Toggle(isOn: Binding(
                            get: { selection.contains(row) },
                            set: { if $0 { selection.insert(row) } else { selection.remove(row) } }
                        )) {
                            LabeledContent(row.word, value: "\(row.reading) · アクセント \(row.accent)")
                        }
                        .disabled(!selection.contains(row) && selected.count >= SharedPronunciations.batchLimit)
                        Divider()
                    }
                }
            }.frame(minHeight: 140, maxHeight: 300)
            if !selected.isEmpty && url == nil {
                Text("投稿が長すぎます。選択する語数を減らしてください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("選択 \(selected.count)件").foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("GitHubの投稿画面を開く") {
                    if let url, NSWorkspace.shared.open(url) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(url == nil)
            }
        }.padding(24).frame(width: 490)
    }
}

struct RecognitionReport: View {
    @Environment(\.dismiss) private var dismiss
    @State private var actual = ""
    @State private var expected = ""

    var body: some View {
        let from = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = GitHubDraft.shareableTerm(from) && GitHubDraft.shareableTerm(to) && from != to
            ? GitHubDraft.issue(repository: "RTranslate", title: "音声認識の誤り",
                                body: "認識された語句　\(from)\n正しい語句　\(to)")
            : nil
        VStack(alignment: .leading, spacing: 14) {
            Text("音声認識の誤りを報告").font(.title2.bold())
            TextField("認識された語句（例 Phydo）", text: $actual).textFieldStyle(.roundedBorder)
            TextField("正しい語句（例 FIDO）", text: $expected).textFieldStyle(.roundedBorder)
            Text("単語や短い語句を入力してください。公開前にGitHubで確認や追記ができます。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("GitHubの投稿画面を開く") {
                    if let url, NSWorkspace.shared.open(url) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(url == nil)
            }
        }.padding(24).frame(width: 470)
    }
}
