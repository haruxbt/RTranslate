import Foundation
import CoreAudio

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func uintProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
    var a = address(selector), value: UInt32 = 0, size: UInt32 = 4
    _ = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value); return value
}
func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector), value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    _ = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value); return value as String
}
func safariAudioProcesses() throws -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
    try checkAudio(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size))
    var objects = [AudioObjectID](repeating: 0, count: Int(size)/4)
    try checkAudio(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &objects))
    return objects.filter {
        let bundle = stringProperty($0, kAudioProcessPropertyBundleID)
        let isSafari = bundle == "com.apple.Safari" || bundle.hasPrefix("com.apple.WebKit")
        if isSafari { print("audioObject=\($0) pid=\(uintProperty($0,kAudioProcessPropertyPID)) bundle=\(bundle) playing=\(uintProperty($0,kAudioProcessPropertyIsRunningOutput))") }
        return isSafari
    }
}
func checkAudio(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: "CoreAudio", code: Int(status)) }
}
final class TapMeter: @unchecked Sendable {
    let lock = NSLock()
    var buffers = 0
    var peak: Float = 0
    func consume(_ list: UnsafePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        buffers += 1
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<(Int(buffer.mDataByteSize)/4) { peak = max(peak, abs(data[i])) }
        }
    }
}
func runTapProbe(mute: Bool, requested: [AudioObjectID]) async throws {
    let available = try safariAudioProcesses()
    guard !requested.isEmpty, requested.allSatisfy(available.contains) else {
        print("Supply explicit Safari audio object IDs: tap [--mute] <ID> ... . No tap created."); return
    }
    let description = CATapDescription(stereoMixdownOfProcesses: requested)
    description.name = "Webinar Nihongo diagnostic (10 sec)"
    description.isPrivate = true
    description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
    var tap: AudioObjectID = 0
    print("Creating private process tap...")
    try checkAudio(AudioHardwareCreateProcessTap(description, &tap))
    print("Created tap object \(tap)")
    defer { AudioHardwareDestroyProcessTap(tap) }
    let uid = stringProperty(tap, kAudioTapPropertyUID)
    var aggregate: AudioObjectID = 0
    let config: [String: Any] = [kAudioAggregateDeviceNameKey: "Webinar diagnostic",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]]]
    print("Creating aggregate device...")
    try checkAudio(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
    print("Created aggregate \(aggregate)")
    defer { AudioHardwareDestroyAggregateDevice(aggregate) }
    let meter = TapMeter()
    var io: AudioDeviceIOProcID?
    try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, DispatchQueue(label: "tap.meter")) { _, input, _, _, _ in meter.consume(input) })
    defer { if let io { AudioDeviceDestroyIOProcID(aggregate, io) } }
    print("Starting tap device...")
    try checkAudio(AudioDeviceStart(aggregate, io))
    defer { AudioDeviceStop(aggregate, io) }
    print("Tap started: mutedWhenTapped=\(mute); duration 10 sec; raw audio not saved")
    try await Task.sleep(for: .seconds(10))
    print("Tap completed: buffers=\(meter.buffers), peak=\(meter.peak). Restoring original output.")
}
