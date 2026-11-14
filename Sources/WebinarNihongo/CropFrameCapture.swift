import AppKit
import ScreenCaptureKit
import CoreImage

/// A picker-authorized, video-only stream. SCScreenshotManager requires global TCC access.
@MainActor
final class CropFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var timeout: Task<Void, Never>?
    private var stream: SCStream?
    private let context = CIContext()

    func image(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = 1200
        config.height = max(2, Int(1200 * filter.contentRect.height / max(1, filter.contentRect.width)))
        config.capturesAudio = false
        config.captureMicrophone = false
        config.showsCursor = false
        config.queueDepth = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        do {
            let image: CGImage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    timeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(6))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(NSError(domain: "CropPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "映像を取得できませんでした。Safariを選び直してお試しください。"])))
                    }
                    Task {
                        do { try await stream.startCapture() }
                        catch { finish(.failure(error)) }
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(.failure(CancellationError())) }
            }
            try? await stream.stopCapture()
            self.stream = nil
            return image
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            throw error
        }
    }
    private func finish(_ result: Result<CGImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixel = sampleBuffer.imageBuffer else { return }
        Task { @MainActor in
            guard continuation != nil else { return }
            let input = CIImage(cvPixelBuffer: pixel)
            if let image = context.createCGImage(input, from: input.extent) { finish(.success(image)) }
        }
    }
}
