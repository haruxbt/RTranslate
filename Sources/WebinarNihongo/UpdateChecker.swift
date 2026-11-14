import Foundation
import Combine
import WebinarCore

@MainActor final class UpdateChecker: ObservableObject {
    @Published var manifestURL = UserDefaults.standard.string(forKey: "appUpdateManifestURL") ?? (Bundle.main.object(forInfoDictionaryKey: "RTranslateUpdateURL") as? String ?? "") {
        didSet { UserDefaults.standard.set(manifestURL, forKey: "appUpdateManifestURL") }
    }
    @Published var appState = "unchecked"
    @Published var modelCheckFailed = false
    var checkFailed: Bool { appState == "failed" }
    var appBadge: String { switch appState { case "checking": "確認中"; case "current": "最新版です"; case "ahead": "開発版"; case "available": "更新あり"; case "unconfigured": "更新先未設定"; case "failed": "確認できません"; default: "未確認" } }
    @Published var appMessage = "アプリ：配布先未設定"
    @Published var modelMessage = "PLaMo：未確認"
    @Published var appAvailable = false
    @Published var modelAvailable = false
    @Published var checking = false
    @Published var checkedAt: Date?
    @Published var downloadURL: URL?
    var hasUpdate: Bool { appAvailable || modelAvailable }
    func check() {
        guard !checking else { return }; checking = true
        Task {
            async let app: Void = checkApp(); async let llm: Void = checkModel()
            _ = await (app, llm); checkedAt = Date(); checking = false
        }
    }
    private func fetch(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https", data.count < 2_000_000 else { throw AppError.message("更新情報を取得できません") }
        return data
    }
    private func checkApp() async {
        appAvailable = false; downloadURL = nil; appState = "checking"
        guard !manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { appState = "unconfigured"; appMessage = "アプリ：配布先未設定"; return }
        guard let url = URL(string: manifestURL), url.scheme == "https", url.user == nil, url.password == nil else { appState = "failed"; appMessage = "アプリ：HTTPSの更新一覧URLを設定してください"; return }
        do {
            let data = try await fetch(url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let update = AppUpdateInfo(json: obj) else { throw AppError.message("更新情報の形式を確認してください") }
            let version = update.version
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            appAvailable = update.isNewer(than: current); downloadURL = update.page
            appState = appAvailable ? "available" : version.compare(current, options: .numeric) == .orderedAscending ? "ahead" : "current"
            appMessage = appAvailable ? "アプリ：v\(version)へ更新できます" : "アプリ：配布先の最新版です（\(current)）"
        } catch { appState = "failed"; appMessage = "アプリ：更新を確認できません。既存版は利用できます。" }
    }
    private func checkModel() async {
        modelAvailable = false; modelCheckFailed = false
        do {
            let url = URL(string: "https://huggingface.co/api/models/pfnet/plamo-3-translate-0.8b-MLX-4bit?blobs=true")!
            let data = try await fetch(url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let siblings = obj["siblings"] as? [[String: Any]],
                  let file = siblings.first(where: { $0["rfilename"] as? String == "model.safetensors" }),
                  let lfs = file["lfs"] as? [String: Any], let remote = lfs["sha256"] as? String,
                  let catalogURL = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "AssetCatalog"),
                  let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any],
                  let files = catalog["files"] as? [[String: Any]], let local = files.first(where: { ($0["path"] as? String)?.hasSuffix("model.safetensors") == true })?["sha256"] as? String else { throw AppError.message("モデル情報が不足しています") }
            modelAvailable = remote != local
            modelMessage = modelAvailable ? "PLaMo：公式の重みに変更があります（動作確認前）" : "PLaMo：公式の重みと一致しています"
        } catch { modelCheckFailed = true; modelMessage = "PLaMo：更新を確認できません。現在のモデルは利用できます。" }
    }
}
