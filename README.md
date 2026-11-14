# R翻訳 / RTranslate

Safariで再生する英語ウェビナーを、日本語字幕と日本語音声で視聴するMacアプリとSafari Web Extensionです。Built with PLaMo.

## インストールについて

**GitHubの「Source code (zip)」「Source code (tar.gz)」は開発用ソースです。ダウンロードしてそのまま実行・インストールすることはできません。**

現時点では、このリポジトリ/Releaseでインストーラを一般配布していません。本人用に作成した `.pkg` インストーラは別途渡す形式です。今後、インストーラを公開するときはReleaseのAssetsに明示します。

本人用インストーラを使う場合は、旧版を終了して `.pkg` を開き、インストール後にアプリを起動します。初回はモデルのダウンロード完了を待ちます。Safari拡張はSafariの設定で有効にしてください。未署名の開発版では試験用の許可を本人が設定する必要があります。Airでの実用性は未検証です。

## 機能と状態

- メニューバーのMacアプリが英語音声認識・PLaMo翻訳・VOICEVOX読み上げを担当します。拡張単体では動きません。
- Mac版はScreenCaptureKit、Safari拡張はページ内メディア/HLSから取得します。サイトや保護コンテンツによって取得できないことがあります。
- 日本語タイムライン、読み上げ位置の強調、速度/音量調整、辞書、スライドOCRを備えます。
- 音声・映像は常時保存せず、確定原文と日本語訳をローカルで3か月保存します。取得開始ごとに表示タイムラインを分けます。
- LLM重み・音声モデルはアプリ外のApplication Support/RTranslate/Assetsへ取得します。
- 音声入力は現在英語に固定。動画URL/再生時刻と結び付けた過去訳の再利用と、Chrome接続は未実装です。
- Mac mini M1で開発。MacBook Air M2 8GBでの性能は未検証です。

## 開発

macOS 26以降・Apple Silicon・対応するSwift SDK/Xcodeが必要です。

```sh
swift build --product WebinarNihongo
swift run WebinarCoreChecks
node --experimental-vm-modules --test Tests/Extension/*.test.mjs
python3 Tests/Integration/asset_store_checks.py
```

上記はネイティブソースのビルドと独立テストです。Safari拡張のXcodeプロジェクトは `SafariExtension/Xcode` にあります。

**公開ソースにはモデル重み、Python/MLX/VOICEVOX/ONNXの実行バイナリ、個人用の完成アプリを含めません。** 完成アプリのパッケージ化には、対応するランタイムと各ライセンスを揃えたベースアプリが別途必要です。`scripts/build_safari_preview.sh` はその準備済みベースを要求し、ソースを取得しただけではインストーラを作れません。公開ソースから実行環境を一式構築する手順は整備中です。

未署名のSafari開発版は本人がSafariの試験用許可を有効にする必要があります。Developer ID署名・公証済みの一般配布版はまだありません。

## 更新通知

アプリの「設定 → モデル・更新・削除」の更新一覧URLに、GitHub Releases APIの `https://api.github.com/repos/haruketh/RTranslate/releases/latest` を設定できます。**コミットだけでは通知されず、通常版Releaseの公開が必要**です。起動時に版番号を比較し、更新時は配布ページへ案内します。自動インストールはしません。リリースがない場合は未確認になります。

モデルは別途公式重みの変更を確認し、動作確認前のモデルへ自動切替しません。更新確認で原文・訳文・履歴を送信しません。

## ライセンス

独自コードのライセンスはLICENSEを参照してください。サードパーティ製コード、モデル、音声ライブラリ、商標はそれぞれの権利者と利用条件に従います。アプリコードのライセンスによってモデルの利用制限がなくなることはありません。詳細はTHIRD_PARTY_NOTICES.md。

## プライバシー

このリポジトリには視聴履歴、実ウェビナーの字幕、録音、ログ、認証情報を含めません。取得対象は本人が権限と利用条件を確認したメディアを選んでください。
