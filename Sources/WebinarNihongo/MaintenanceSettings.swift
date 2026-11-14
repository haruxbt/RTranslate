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
struct RemovalPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = MaintenanceState()
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("アプリとデータの削除").font(.title3.bold()); Spacer(); Button("閉じる") { dismiss() } }.padding()
            Form {
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
        }.frame(width: 580, height: 560)
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
