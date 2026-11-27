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

            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.disabled(locked)
    }
}
