import SwiftUI
import Combine
import WebinarCore

enum DictionaryKind: String, CaseIterable, Identifiable {
    case glossary, corrections, readings, displayTerms
    var id: String { rawValue }
    var title: String { switch self { case .glossary: "用語辞書"; case .corrections: "誤認識の補正"; case .readings: "読み"; case .displayTerms: "表記" } }
    @MainActor var key: ReferenceWritableKeyPath<ListeningPreferences, String> { switch self { case .glossary: \.glossary; case .corrections: \.corrections; case .readings: \.readings; case .displayTerms: \.displayTerms } }
    var left: String { self == .glossary ? "英語・原語" : self == .corrections ? "誤認識された表記" : "用語" }
    var right: String { self == .glossary ? "日本語・訳語" : self == .readings ? "読み" : "正しい表記" }
}
@MainActor final class DictionaryEditorState: ObservableObject {
    @Published var kind: DictionaryKind = .glossary
    @Published var source = ""
    @Published var target = ""
    @Published var original: String?
    @Published var editing = false
    @Published var message = "保存済み"
    @Published var validation = ""
    @Published var raw = false
}
struct DictionarySettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ListeningPreferences
    @StateObject private var state = DictionaryEditorState()
    private var terms: [GlossaryTerm] { ListeningText.terms(preferences[keyPath: state.kind.key]) }
    private var locked: Bool { model.running || model.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeading(title: "辞書", subtitle: "専門用語の訳し方や、聞き間違い・読みを整えます。")
            HStack {
                Picker("辞書の種類", selection: $state.kind) { ForEach(DictionaryKind.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented)
                Button("追加") { edit(nil) }.buttonStyle(.borderedProminent).disabled(locked)
            }
            HStack { Text(state.kind.left).frame(maxWidth: .infinity, alignment: .leading); Text(state.kind.right).frame(maxWidth: .infinity, alignment: .leading); Color.clear.frame(width: 58, height: 1) }.font(.caption).foregroundStyle(.secondary).padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            ScrollView {
                LazyVStack(spacing: 0) {
                    if terms.isEmpty { Text("まだ登録されていません。").foregroundStyle(.secondary).padding(30) }
                    ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                        HStack(alignment: .top, spacing: 12) {
                            Text(term.source).frame(maxWidth: .infinity, alignment: .leading)
                            Text(term.target).frame(maxWidth: .infinity, alignment: .leading)
                            Button("編集") { edit(term) }.buttonStyle(.plain).foregroundStyle(Color.accentColor).frame(width: 44).disabled(locked)
                        }.padding(.vertical, 13).padding(.horizontal, 12)
                        Divider()
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack { Label(state.message, systemImage: "checkmark.circle.fill").foregroundStyle(.teal); Spacer() }.font(.caption)
            Text(locked ? "翻訳を停止すると編集できます。" : "聞き取りへの反映は、次の翻訳開始から。").font(.caption).foregroundStyle(.secondary)
            HStack { Text("用語辞書は認識の参考語と翻訳に使用します。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("詳細編集") { state.raw = true }.font(.caption).disabled(locked) }
        }.padding(24)
            .sheet(isPresented: $state.editing) { editor }
            .sheet(isPresented: $state.raw) { VStack(alignment: .leading, spacing: 12) { Text("\(state.kind.title)・詳細編集").font(.headline); Text("1行に「用語 = 変換先」。入力した内容をそのまま保存します。").font(.caption); TextEditor(text: Binding(get: { preferences[keyPath: state.kind.key] }, set: { preferences[keyPath: state.kind.key] = $0; model.voice.invalidatePrefetch() })).font(.system(.body, design: .monospaced)); Button("閉じる") { state.raw = false } }.padding(24).frame(width: 500, height: 380) }
            .onChange(of: state.kind) { _,_ in state.message = "保存済み" }
    }
    private func edit(_ term: GlossaryTerm?) { state.original = term?.source; state.source = term?.source ?? ""; state.target = term?.target ?? ""; state.validation = ""; state.editing = true }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.original == nil ? "\(state.kind.title)に追加" : "用語を編集").font(.title3.bold())
            TextField(state.kind.left, text: $state.source).textFieldStyle(.roundedBorder)
            TextField(state.kind.right, text: $state.target).textFieldStyle(.roundedBorder)
            if !state.validation.isEmpty { Text(state.validation).font(.caption).foregroundStyle(.orange) }
            HStack {
                if state.original != nil { Button("削除", role: .destructive) { save(remove: true) } }
                Spacer(); Button("キャンセル") { state.editing = false }; Button("保存") { save(remove: false) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 470)
    }
    private func save(remove: Bool) {
        guard !locked else { return }
        do {
            preferences[keyPath: state.kind.key] = try DictionaryEdit.applying(to: preferences[keyPath: state.kind.key], original: state.original, source: state.source, target: state.target, deleting: remove)
            model.voice.invalidatePrefetch(); state.editing = false; state.message = "保存済み"
        } catch DictionaryEditError.tooManyEntries { state.validation = "各辞書は100件まで登録できます。" }
        catch { state.validation = "用語は64文字、変換先は96文字まで。改行や用語内の=は使えません。" }
    }
}
