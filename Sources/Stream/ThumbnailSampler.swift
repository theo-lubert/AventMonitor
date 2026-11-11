import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// Keeps one decoded frame every `interval` as a small still, the camera's thumbnail.
/// Confined to the stream's I/O queue.
final class ThumbnailSampler: @unchecked Sendable {
    /// Called on the I/O queue with a downscaled copy of the frame.
    var onImage: ((CGImage) -> Void)?

    private let interval: TimeInterval
    private let maxWidth: Int
    private var lastSample = Date.distantPast

    init(interval: TimeInterval = 30, maxWidth: Int = 640) {
        self.interval = interval
        self.maxWidth = maxWidth
    }

    /// Takes the next frame, so a fresh thumbnail follows each (re)connect.
    func reset() {
        lastSample = .distantPast
    }

    /// `frame` must not have been drawn on yet.
    func push(_ frame: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= interval else { return }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image) == noErr, let image,
              let copy = Self.downscaledCopy(of: image, maxWidth: maxWidth)
        else { return }
        lastSample = now
        onImage?(copy)
    }

    /// Always draws into new memory: the source may share the decoder's pixel buffer, which gets reused.
    private static func downscaledCopy(of image: CGImage, maxWidth: Int) -> CGImage? {
        let width = min(image.width, maxWidth)
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
