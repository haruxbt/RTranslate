import Foundation

/// Supports a small update manifest or GitHub's latest published release response.
public struct AppUpdateInfo {
    public let version: String
    public let page: URL?
    public init?(json: [String: Any]) {
        guard json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let raw = (json["version"] ?? json["tag_name"]) as? String else { return nil }
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        version = value
        if let rawURL = (json["downloadURL"] ?? json["html_url"]) as? String,
           let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil { page = url } else { page = nil }
    }
    public func isNewer(than current: String) -> Bool { version.compare(current, options: .numeric) == .orderedDescending }
}
