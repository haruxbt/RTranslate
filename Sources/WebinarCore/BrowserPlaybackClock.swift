/// A snapshot of the media clock from the selected Safari frame.
/// Never extrapolate past the reported playhead: buffering and pause stop the clock.
public struct BrowserPlaybackClock {
    public private(set) var position: Double?
    public private(set) var paused = true
    private var receivedAt: Double = 0
    private var serial = -1

    public init() {}

    @discardableResult
    public mutating func update(serial: Int, position: Double, paused: Bool, at now: Double) -> Bool {
        guard serial > self.serial, position.isFinite, position >= 0, now.isFinite else { return false }
        self.serial = serial
        self.position = position
        self.paused = paused
        receivedAt = now
        return true
    }

    public func playingPosition(at now: Double) -> Double? {
        guard !paused, now >= receivedAt, now - receivedAt <= 2 else { return nil }
        return position
    }

    public static func isDue(_ mediaStart: Double?, at position: Double?) -> Bool {
        guard let mediaStart else { return true }
        return position.map { $0 >= mediaStart } ?? false
    }
}
