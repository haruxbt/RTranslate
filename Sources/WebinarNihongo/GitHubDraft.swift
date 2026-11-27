import Foundation

enum GitHubDraft {
    static func shareableTerm(_ word: String) -> Bool {
        (1...64).contains(word.count)
            && word.range(of: #"\p{L}"#, options: .regularExpression) != nil
            && word.range(of: #"^[\p{L}\p{M}\p{N} ._+&@'-]+$"#, options: .regularExpression) != nil
            && word.range(of: #"[\w.+-]+@[\w.-]+\.[a-z]{2,}|(?:sk-|gh[pousr]_)[A-Za-z0-9]{20,}"#,
                          options: [.regularExpression, .caseInsensitive]) == nil
    }

    static func issue(repository: String, title: String, body: String) -> URL? {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "github.com"
        url.path = "/haruxbt/\(repository)/issues/new"
        url.queryItems = [.init(name: "title", value: title), .init(name: "body", value: body)]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = url.url, result.absoluteString.utf8.count <= 6000 else { return nil }
        return result
    }
}
