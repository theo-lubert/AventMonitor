import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// While the stream is down, keeps feeding the display layer: the last picture, dimmed,
/// and in Picture in Picture (where the window's overlays are not shown) a spinning
/// loader drawn into it. A layer that keeps receiving frames also keeps Picture in
/// Picture attached to it across reconnects.
final class OutagePlaceholder: @unchecked Sendable { // confined to the stream queue
    var onSample: ((CMSampleBuffer) -> Void)?
    /// Draws the loader into the picture, for Picture in Picture.
    var drawsLoader = false

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var background: CGImage?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var started = Date()

    private static let framesPerSecond = 15
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var isRunning: Bool { timer != nil }

    /// Starts showing `frame` (the last picture shown) as the outage background.
    func start(from frame: CVPixelBuffer) {
        guard timer == nil, let background = Self.dimmed(frame), let pool = Self.makePool(like: frame) else { return }
        self.background = background
        self.pool = pool
        format = nil
        started = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(Self.framesPerSecond))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        background = nil
        pool = nil
        format = nil
    }

    private func tick() {
        guard let background, let pool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out else { return }
        CVPixelBufferLockBaseAddress(out, [])
        let width = CVPixelBufferGetWidth(out)
        let height = CVPixelBufferGetHeight(out)
        if let base = CVPixelBufferGetBaseAddress(out),
           let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: Self.bitmapInfo) {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.draw(background, in: rect)
            if drawsLoader { Self.drawLoader(in: ctx, rect: rect, elapsed: Date().timeIntervalSince(started)) }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        if let sample = DisplaySample.make(out, format: &format) { onSample?(sample) }
    }

    /// A copy of the frame, darkened so the loader stands out and the picture reads as old.
    private static func dimmed(_ frame: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let source = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: space,
                                     bitmapInfo: bitmapInfo)?.makeImage(),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(source, in: rect)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(rect)
        return ctx.makeImage()
    }

    private static func makePool(like frame: CVPixelBuffer) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: CVPixelBufferGetWidth(frame),
            kCVPixelBufferHeightKey: CVPixelBufferGetHeight(frame),
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// A ring with a turning arc, and "Reconnexion…" under it. Sized from the picture
    /// height, so it scales with the PiP window like the video does.
    private static func drawLoader(in ctx: CGContext, rect: CGRect, elapsed: TimeInterval) {
        let h = rect.height
        let radius = h * 0.07
        let lineWidth = h * 0.014
        let center = CGPoint(x: rect.midX, y: rect.midY + h * 0.04)

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        // CoreGraphics angles turn counterclockwise: subtract to spin clockwise, once a second.
        let start = .pi / 2 - CGFloat(elapsed.truncatingRemainder(dividingBy: 1)) * .pi * 2
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - .pi / 2, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        let font = CTFontCreateUIFontForLanguage(.system, h * 0.05, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, h * 0.05, nil)
        let text = NSAttributedString(string: "Reconnexion…", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.9),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                   y: center.y - radius - lineWidth - h * 0.04 - bounds.height)
        CTLineDraw(line, ctx)
    }
}
