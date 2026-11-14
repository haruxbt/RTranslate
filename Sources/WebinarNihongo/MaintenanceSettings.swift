import SwiftUI
import AppKit
import Combine

@MainActor final class MaintenanceState: ObservableObject {
    @Published var models = false
    @Published var history = false
    @Published var app = false
    @Published var message = ""
    @Published var review = ""
    @Published var token = ""
    @Published var busy = false
    var selection: [String: Bool] { ["models": models, "history": history, "app": app] }
    var reviewedSelection: [String: Bool] = [:]
}
struct MaintenanceSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assets: AssetManager
    @ObservedObject var updates: UpdateChecker
    @StateObject private var state = MaintenanceState()
    var body: some View {
        Form {
            Section("共通モデル") {
                Text(assets.message).textSelection(.enabled)
                Text("PLaMoとVOICEVOXの音声データはアプリの外に保存し、Safari拡張と共用します。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("準備・再確認") { assets.prepare() }.disabled(model.running || model.busy || state.busy)
                Button("保存先を開く") { NSWorkspace.shared.open(AssetManager.root.deletingLastPathComponent()) }
            }
            Section("更新") {
                Text(updates.appMessage)
                Text(updates.modelMessage)
                if let date = updates.checkedAt { Text("確認日時：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                Text("起動時に確認します。モデルの変更は通知だけ行い、確認前の重みに自動で切り替えません。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("アプリ更新一覧URL（未設定でも利用できます）", text: $updates.manifestURL)
                Button(updates.checking ? "確認中…" : "更新を確認") { updates.check() }.disabled(updates.checking)
                if updates.appAvailable, let url = updates.downloadURL {
                    Button("配布ページを開く") { NSWorkspace.shared.open(url) }
                }
            }
            Section("アンインストール") {
                Text("削除したい項目を選び、内容を確認してからゴミ箱へ移します。Safari拡張が有効な間は、ここから共通モデル・アプリを削除できません。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("共通のLLM・音声モデル", isOn: $state.models)
                Toggle("翻訳履歴・アプリの設定", isOn: $state.history)
                Toggle("このアプリ（Safari拡張を含む）", isOn: $state.app)
                Button("削除内容を確認") { requestReview() }
                    .disabled(state.busy || model.running || model.busy || !state.selection.values.contains(true))
                if !state.review.isEmpty {
                    Text(state.review).textSelection(.enabled)
                    HStack {
                        Button("キャンセル") { state.review = ""; state.token = "" }
                        Button("選択した項目をゴミ箱へ移す", role: .destructive) { removeReviewed() }
                            .disabled(state.busy || state.selection != state.reviewedSelection)
                    }
                }
                if !state.message.isEmpty { Text(state.message).textSelection(.enabled) }
            }.disabled(state.busy)
        }.formStyle(.grouped)
    }
    private func requestReview() {
        state.busy = true; state.review = ""; state.message = ""
        let selection = state.selection
        Task {
            let result = await model.managementRequest("uninstallReview", selection: selection)
            if result["ok"] as? Bool == true {
                state.reviewedSelection = selection; state.token = result["token"] as? String ?? ""
                state.review = result["message"] as? String ?? ""
            } else { state.message = result["error"] as? String ?? "確認できませんでした" }
            state.busy = false
        }
    }
    private func removeReviewed() {
        guard state.selection == state.reviewedSelection, !state.token.isEmpty else { return }
        state.busy = true
        Task {
            let result = await model.managementRequest("uninstall", selection: state.reviewedSelection, token: state.token)
            state.message = (result["message"] ?? result["error"]) as? String ?? "処理を確認してください"
            state.review = ""; state.token = ""; state.busy = false
        }
    }
}
