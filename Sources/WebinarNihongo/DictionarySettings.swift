import SwiftUI
import AppKit
import Combine
import WebinarCore

struct DictionarySettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ListeningPreferences
    @StateObject private var state = EditorState()
    private var mode: Int { state.mode }
    private final class EditorState: ObservableObject {
        @Published var mode = 0
        @Published var draft: Draft?
        @Published var error = ""
        @Published var search = ""
    }
    private var locked: Bool { model.running || model.busy || model.pageReading }

    private struct Draft: Identifiable {
        let id = UUID()
        var original: String?
        var term = ""
        var translation = ""
        var pronunciation = ""
    }

    private var rows: [Draft] {
        let primary = mode == 0 ? preferences.glossary : mode == 1 ? preferences.corrections : preferences.displayTerms
        var result: [Draft] = []
        var indices: [String: Int] = [:]
        for (entries, isReading) in [(ListeningText.terms(primary), false),
                                     (mode == 0 ? ListeningText.terms(preferences.readings) : [], true)] {
            for entry in entries {
                let key = entry.source.lowercased()
                let i = indices[key] ?? result.count
                if i == result.count {
                    indices[key] = i
                    result.append(Draft(original: entry.source, term: entry.source))
                }
                if isReading { result[i].pronunciation = entry.target }
                else { result[i].translation = entry.target }
            }
        }
        return result.sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeading(title: "辞書", subtitle: "用語の訳し方と読み方をまとめて編集します。")
            HStack {
                Picker("辞書の種類", selection: $state.mode) {
                    Text("用語と読み方").tag(0)
                    Text("誤認識の補正").tag(1)
                    Text("表記").tag(2)
                    Text("RSpeech").tag(3)
                }.labelsHidden().pickerStyle(.segmented)
                if mode != 3 { Button("追加") { open(Draft()) }.buttonStyle(.borderedProminent).disabled(locked) }
            }
            if mode == 3 {
                SharedReadingList(shared: preferences.shared, search: $state.search)
            } else {
                tableRow(mode == 1 ? "誤認識された語" : "原語", mode == 0 ? "訳語" : "正しい表記", "読み方") {
                    Color.clear.frame(width: 40, height: 1)
                }.font(.caption).foregroundStyle(.secondary).padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if rows.isEmpty { Text("まだ登録されていません。").foregroundStyle(.secondary).padding(30) }
                        ForEach(rows, id: \.term) { row in
                            tableRow(row.term, row.translation.isEmpty ? "—" : row.translation,
                                     row.pronunciation.isEmpty ? "—" : row.pronunciation) {
                                Button("編集") { open(row) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                    .frame(width: 40).disabled(locked)
                            }.padding(10)
                            Divider()
                        }
                    }
                }
                Text(locked ? "翻訳と読み上げを停止すると編集できます。" : "訳語と読み方は片方だけでも登録できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
            .sheet(item: $state.draft) { value in
                editor(value)
            }
            .onAppear(perform: openRequestedWord)
            .onChange(of: model.dictionaryRequest) { _, _ in openRequestedWord() }
    }

    private func tableRow<Accessory: View>(_ left: String, _ middle: String, _ right: String,
                                            @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(left).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text(middle).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if mode == 0 { Text(right).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            accessory()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openRequestedWord() {
        guard let word = model.dictionaryRequest else { return }
        model.dictionaryRequest = nil
        guard !locked else { return }
        state.mode = 0
        open(rows.first { $0.term.caseInsensitiveCompare(word) == .orderedSame } ?? Draft(term: word))
    }

    private func open(_ value: Draft) { state.error = ""; state.draft = value }

    private func editor(_ value: Draft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(value.original == nil ? "用語を追加" : "用語を編集").font(.title3.bold())
            TextField(mode == 1 ? "誤認識された語" : "原語", text: draftField(\.term)).textFieldStyle(.roundedBorder)
            TextField(mode == 0 ? "訳語" : "正しい表記", text: draftField(\.translation)).textFieldStyle(.roundedBorder)
            if mode == 0 { TextField("読み方", text: draftField(\.pronunciation)).textFieldStyle(.roundedBorder) }
            if mode == 0, let draft = state.draft, !draft.pronunciation.isEmpty {
                Button("共通辞書に共有…") { save(delete: false, share: true) }
                    .disabled(locked)
                Text("共有すると、原語と読み方が公開GitHubに送られます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.error.isEmpty { Text(state.error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if value.original != nil { Button("削除", role: .destructive) { save(delete: true) } }
                Spacer()
                Button("キャンセル") { state.draft = nil }
                Button("保存") { save(delete: false) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 440)
    }

    private func draftField(_ path: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(get: { state.draft?[keyPath: path] ?? "" }, set: { state.draft?[keyPath: path] = $0 })
    }

    private func save(delete: Bool, share: Bool = false) {
        guard !locked, let draft = state.draft else { return }
        let term = draft.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = draft.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let pronunciation = draft.pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        let shareURL = share ? SharedPronunciations.issueURL(word: term, reading: pronunciation) : nil
        if share && shareURL == nil {
            state.error = "共有する原語は64文字以内で、読み方はかなで入力してください。"
            return
        }
        do {
            func update(_ current: String, _ target: String) throws -> String {
                try DictionaryEdit.applying(to: current, original: draft.original, source: term,
                                            target: target, deleting: delete || target.isEmpty)
            }
            guard delete || !translation.isEmpty || (mode == 0 && !pronunciation.isEmpty) else {
                throw DictionaryEditError.invalidEntry
            }
            switch mode {
            case 0:
                let glossary = try update(preferences.glossary, translation)
                let readings = try update(preferences.readings, pronunciation)
                preferences.glossary = glossary
                preferences.readings = readings
            case 1: preferences.corrections = try update(preferences.corrections, translation)
            default: preferences.displayTerms = try update(preferences.displayTerms, translation)
            }
            model.voice.invalidatePrefetch()
            state.draft = nil
            if let shareURL { NSWorkspace.shared.open(shareURL) }
        } catch DictionaryEditError.tooManyEntries {
            state.error = "訳語と読み方は各100件まで登録できます。"
        } catch {
            state.error = "原語と変換先を確認してください。原語は64文字、変換先は96文字までです。"
        }
    }
}

private struct SharedReadingList: View {
    @ObservedObject var shared: SharedPronunciations
    @Binding var search: String

    private var rows: [SpeechPronunciation] {
        let entries = Dictionary((shared.common + shared.personal).map { ($0.word.lowercased(), $0) },
                                 uniquingKeysWith: { _, personal in personal })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.values.filter { query.isEmpty || $0.word.localizedCaseInsensitiveContains(query) ||
                                        $0.reading.localizedCaseInsensitiveContains(query) }
            .sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        HStack {
            TextField("原語・読み方を検索", text: $search).textFieldStyle(.roundedBorder)
            Button(shared.updating ? "更新中…" : "今すぐ更新") { Task { await shared.refresh() } }.disabled(shared.updating)
        }
        HStack {
            Text("原語").frame(maxWidth: .infinity, alignment: .leading)
            Text("読み方").frame(maxWidth: .infinity, alignment: .leading)
            Text("アクセント / 優先度").frame(width: 125, alignment: .leading)
        }.font(.caption).foregroundStyle(.secondary).padding(10)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.word) { row in
                    HStack(alignment: .top) {
                        Text(row.word).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.reading).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(row.accent) / \(row.priority)").frame(width: 125, alignment: .leading)
                    }.padding(10)
                    Divider()
                }
            }
        }
        Text(shared.message.isEmpty ? "RSpeechの共通辞書と、このMacのRSpeech個人辞書を使用します。" : shared.message)
            .font(.caption).foregroundStyle(.secondary)
    }
}
