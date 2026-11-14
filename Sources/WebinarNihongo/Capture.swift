import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreImage

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.webinar.capture", qos: .userInitiated)
    private var stream: SCStream?
    let bridge: AudioBridge
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?
    init(bridge: AudioBridge) { self.bridge = bridge }
    func start(window: SCWindow) async throws {
        try await start(filter: SCContentFilter(desktopIndependentWindow: window))
    }
    func start(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.sampleRate = 48000; config.channelCount = 2
        config.width = 1280
        config.height = max(2, Int(1280 * filter.contentRect.height / max(filter.contentRect.width, 1)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3; config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }
    func stop() async {
        let old = stream; stream = nil
        try? await old?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: bridge.consume(sampleBuffer)
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pixel = sampleBuffer.imageBuffer else { return }
            onFrame?(pixel)
        default: break
        }
    }
}
