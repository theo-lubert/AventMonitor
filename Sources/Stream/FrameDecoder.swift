import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes the H.264 stream to BGRA frames ready for AVSampleBufferDisplayLayer.
/// Decoding ourselves lets the motion detector read the pixels and lets us draw
/// the sound bars into the picture while in Picture in Picture, where AppKit
/// overlays are not shown.
final class FrameDecoder: @unchecked Sendable { // confined to the stream queue
    /// Each decoded frame, before anything is drawn on it.
    var onImage: ((CVPixelBuffer) -> Void)?
    /// The frame to display, decoded, or the compressed sample when decoding is unavailable.
    var onSample: ((CMSampleBuffer) -> Void)?

    /// Draws the sound bars into the picture. Set from the main thread through the stream queue.
    var drawsSoundBars = false
    /// Room sound level 0…3, nil when the camera sends no audio.
    var soundLevel: Int?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var outputFormat: CMVideoFormatDescription?
    private var failedFormat: CMVideoFormatDescription?

    func push(_ sample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        if failedFormat.map({ CMFormatDescriptionEqual($0, otherFormatDescription: desc) }) == true {
            onSample?(sample) // decoder unavailable for this stream: let the layer decode
            return
        }
        if session == nil || !CMFormatDescriptionEqual(desc, otherFormatDescription: format) {
            guard makeSession(desc) else {
                failedFormat = desc
                onSample?(sample)
                return
            }
        }
        guard let session else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.decoded(image, pts: pts)
        }
        // Keep frames in order and on this queue's timeline.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status == kVTInvalidSessionErr { invalidate() }
    }

    func reset() {
        invalidate()
        failedFormat = nil
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        outputFormat = nil
    }

    private func makeSession(_ desc: CMVideoFormatDescription) -> Bool {
        invalidate()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var out: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc,
                                                  decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &out)
        guard status == noErr, let out else { return false }
        VTSessionSetProperty(out, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = out
        format = desc
        return true
    }

    private func decoded(_ image: CVImageBuffer, pts: CMTime) {
        onImage?(image)
        if drawsSoundBars, let level = soundLevel { SoundBarsPainter.draw(level: level, on: image) }
        guard let sample = wrap(image, pts: pts) else { return }
        onSample?(sample)
    }

    private func wrap(_ image: CVImageBuffer, pts: CMTime) -> CMSampleBuffer? {
        if outputFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) != true {
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                               formatDescriptionOut: &desc) == noErr else { return nil }
            outputFormat = desc
        }
        guard let outputFormat else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                       formatDescription: outputFormat, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        sample.setAttachment(kCMSampleAttachmentKey_DisplayImmediately)
        return sample
    }
}

/// The window's three sound bars, drawn into a BGRA frame for Picture in Picture.
/// Sized from the picture height, so they scale with the PiP window like the video does.
enum SoundBarsPainter {
    static func draw(level: Int, on image: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(image),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo) else { return }

        // A PiP window is much smaller than the video, so the bars are thicker than in the window.
        let h = CGFloat(height)
        let barWidth = h * 0.028
        let barHeight = h * 0.11
        let gap = h * 0.018
        let x = h * 0.04
        let total = barHeight * 3 + gap * 2
        var y = (h - total) / 2 // CoreGraphics origin is bottom left: level 1 is drawn first, at the bottom

        for bar in 1...3 {
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            ctx.saveGState()
            if bar <= level {
                ctx.setShadow(offset: .zero, blur: barWidth * 1.2, color: CGColor(gray: 1, alpha: 0.55))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            } else {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
            }
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
            y += barHeight + gap
        }
    }
}
