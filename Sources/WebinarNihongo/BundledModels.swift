import Foundation

/// Personal builds use models inside the current app bundle, so moving the app
/// between Macs never depends on paths saved on the development machine.
@MainActor enum BundledModels {
    static func resolve(_ folder: String, marker: String, savedKey: String, overrideKey: String) -> URL? {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: savedKey).map { URL(fileURLWithPath: $0) }
        func valid(_ url: URL?) -> Bool {
            guard let url else { return false }
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path)
        }
        let external = AssetManager.root.appendingPathComponent(folder)
        if FileManager.default.fileExists(atPath: AssetManager.root.appendingPathComponent("ready.json").path), valid(external) { return external }
        if defaults.bool(forKey: overrideKey), valid(saved),
           saved?.path.contains(".app/Contents/Resources/Models/") != true { return saved }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models/" + folder)
        if valid(bundled) { return bundled }
        return valid(saved) ? saved : nil
    }
}
