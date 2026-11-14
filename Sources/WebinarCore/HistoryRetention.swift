import Foundation

public enum HistoryRetention {
    public static let maximumLines = 50_000
    /// Legacy records have uptime timestamps, not wall-clock dates. Give them a full
    /// retention period on migration rather than guessing when they were created.
    public static func retained(_ lines: [TranscriptLine], now: Date = Date(),
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> [TranscriptLine] {
        lines.compactMap { line in
            var dated = line
            if dated.createdAt == nil { dated.createdAt = now }
            guard let created = dated.createdAt,
                  let expires = calendar.date(byAdding: .month, value: 3, to: created),
                  expires > now else { return nil }
            return dated
        }
    }
}
