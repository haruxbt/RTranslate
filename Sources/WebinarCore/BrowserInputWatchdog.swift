/// Paused media emits no PCM. It must still send a liveness notification, so a
/// closed or unresponsive tab cannot keep a native capture session alive forever.
public struct BrowserInputWatchdog {
    public private(set) var paused = false
    private var lastPacket: Double
    private var lastHeartbeat: Double?
    private var receivedPacket = false
    public init(now: Double) { lastPacket = now }
    public mutating func packet(at now: Double) { lastPacket = now; receivedPacket = true }
    public mutating func heartbeat(paused next: Bool, at now: Double) {
        if paused && !next { lastPacket = now }
        paused = next; lastHeartbeat = now
    }
    public func timedOut(at now: Double) -> Bool {
        if let lastHeartbeat, now - lastHeartbeat > 12 { return true }
        if paused { return false }
        return now - lastPacket > (receivedPacket ? 12 : 90)
    }
}
