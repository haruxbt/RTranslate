import SwiftUI

struct ListeningSettings: View {
    @ObservedObject var preferences: ListeningPreferences
    let locked: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("意味の通る日本語で聴く").font(.title2.bold())
                Text("文末や発話の区切りを待ってから翻訳します。22語ごとの分割はしません。文をまとめる待ちは最大14秒で、翻訳や読み上げの待ち時間は別です。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Toggle("フィラー・相づち・単純な重複を減らす", isOn: $preferences.smooth)
                Text("元の英文は履歴に残します。否定や数字、条件は消しません。短いOkay? / Right?などは読み上げを省略することがあります。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("用語辞書").font(.headline)
                Text("1行に「英語 = 日本語」。聞き取りの参考語とPLaMoの用語集に使います。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $preferences.glossary).font(.system(.body, design: .monospaced)).frame(height: 145)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("聞き間違いの補正").font(.headline)
                Text("1行に「誤認識された表記 = 正しい表記」。単語全体が一致した箇所に適用します。広すぎる置き換えは避けてください。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $preferences.corrections).font(.system(.body, design: .monospaced)).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                if preferences.invalidLines > 0 { Text("読み込めない行が\(preferences.invalidLines)件あります。=の左右と長さを確認してください。").font(.caption).foregroundStyle(.orange) }
                Text(locked ? "変更する場合は、翻訳を停止してください。" : "自動保存します。聞き取り用語は次の取得開始から反映します。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.disabled(locked)
    }
}
