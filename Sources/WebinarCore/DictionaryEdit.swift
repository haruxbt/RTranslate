import Foundation

public enum DictionaryEditError: Error { case invalidEntry, tooManyEntries }
public enum DictionaryEdit {
    /// Preserve unparseable rows instead of deleting them while editing a valid entry.
    public static func applying(to text: String, original: String?, source: String, target: String, deleting: Bool = false) throws -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines), target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deleting {
            guard !source.isEmpty, !target.isEmpty, source.count <= 64, target.count <= 96, !source.contains("="), source.rangeOfCharacter(from: .newlines) == nil, target.rangeOfCharacter(from: .newlines) == nil else { throw DictionaryEditError.invalidEntry }
        }
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        rows.removeAll { row in
            guard let parsed = ListeningText.terms(row).first else { return false }
            return (original != nil && parsed.source == original) || (!deleting && parsed.source.caseInsensitiveCompare(source) == .orderedSame)
        }
        if !deleting { guard ListeningText.terms(rows.joined(separator: "\n")).count < 100 else { throw DictionaryEditError.tooManyEntries }; rows.append(source+" = "+target) }
        return rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
}
