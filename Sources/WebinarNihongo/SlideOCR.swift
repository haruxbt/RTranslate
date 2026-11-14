import Vision
import CoreImage
import WebinarCore

struct SlideBlock: Identifiable {
    let id: Int
    let english: String
    var japanese: String?
}
enum SlideEvent { case changed; case ready([String]) }
actor SlideOCR {
    private var stability = SlideStability()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    func reset() { stability = SlideStability() }
    // Unit rectangle in Vision coordinates: origin bottom-left.
    func detect(_ pixel: CVPixelBuffer, region: CGRect) throws -> SlideEvent? {
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region.minX >= 0, region.minY >= 0, region.width > 0, region.height > 0,
              region.maxX <= 1, region.maxY <= 1 else { throw AppError.message("OCR領域は0〜1の範囲で指定してください") }
        let image = CIImage(cvPixelBuffer: pixel)
        let rect = CGRect(x: image.extent.width * region.minX, y: image.extent.height * region.minY,
                          width: image.extent.width * region.width, height: image.extent.height * region.height)
        guard let cropped = ci.createCGImage(image.cropped(to: rect), from: rect) else { return nil }
        var fingerprint = [UInt8](repeating: 0, count: 64 * 36)
        let ready = fingerprint.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 36, bitsPerComponent: 8,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 64, height: 36)); return true
        }
        guard ready else { return nil }
        let previousRevision = stability.revision
        let stable = stability.observe(fingerprint)
        if stability.revision != previousRevision { return .changed }
        guard stable else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cropped).perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return .ready(observations.compactMap { $0.topCandidates(1).first?.string })
    }
}
