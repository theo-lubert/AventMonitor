import CoreGraphics
import CoreMedia
import Foundation

/// Everything that happens to a stream's packets, from RTP to the display layer:
///
///     video RTP → H264Assembler → FrameDecoder → display
///                                      ├→ MotionDetector
///                                      └→ ThumbnailSampler
///     audio RTP → AudioOutput (speaker) and SoundMeter (level)
///
/// Confined to the stream's I/O queue: call every method there. Callbacks also
/// fire there, except `secondsSinceLastFrame`, which any thread may read.
final class MediaPipeline: @unchecked Sendable {
    /// A frame ready for the display layer.
    var onDisplay: ((CMSampleBuffer) -> Void)?
    /// The first frame since the last `reset()`.
    var onFirstFrame: (() -> Void)?
    var onDimensions: ((CMVideoDimensions) -> Void)?
    /// Room sound level 0…3, on every change.
    var onSoundLevel: ((Int) -> Void)?
    /// Sound or movement, at most once a second per kind.
    var onActivity: ((ActivityCenter.Kind) -> Void)?
    /// An occasional downscaled still, for the panel's thumbnail.
    var onThumbnail: ((CGImage) -> Void)?

    private let assembler = H264Assembler()
    private let decoder = FrameDecoder()
    private let motion = MotionDetector()
    private let thumbnails = ThumbnailSampler()
    private let audio = AudioOutput()
    private let meter = SoundMeter()
    private let clock = FrameClock()
    private var lastActivity: [ActivityCenter.Kind: Date] = [:]

    init() {
        assembler.onDimensions = { [unowned self] in onDimensions?($0) }
        assembler.onSample = { [unowned self] sample in
            decoder.push(sample)
            if clock.tick() { onFirstFrame?() }
        }
        // Motion and thumbnails need decoded pixels. In the rare case VideoToolbox cannot
        // decode the stream, FrameDecoder hands compressed samples to the layer and both stop.
        decoder.onImage = { [unowned self] image in
            motion.analyze(image)
            thumbnails.push(image)
        }
        decoder.onSample = { [unowned self] in onDisplay?($0) }
        motion.onMotion = { [unowned self] in report(.motion) }
        meter.onLoud = { [unowned self] in report(.sound) }
        meter.onLevel = { [unowned self] level in
            decoder.soundLevel = level
            onSoundLevel?(level)
        }
        thumbnails.onImage = { [unowned self] in onThumbnail?($0) }
    }

    /// Seconds since the last video frame (or the last reset). Safe from any thread.
    var secondsSinceLastFrame: TimeInterval { clock.secondsSinceLastFrame }

    /// Draws the sound level into the picture, for Picture in Picture where overlays are not shown.
    var drawsSoundBars: Bool {
        get { decoder.drawsSoundBars }
        set { decoder.drawsSoundBars = newValue }
    }

    var muted: Bool {
        get { audio.muted }
        set { audio.muted = newValue }
    }

    func push(_ media: RTSPClient.Media, _ data: Data) {
        guard let packet = RTPPacket(data) else { return }
        switch media {
        case .video:
            assembler.push(packet)
        case .audio:
            audio.push(packet.payload)
            meter.push(packet.payload)
        }
    }

    /// Forgets all stream state, for a new connection.
    func reset() {
        assembler.reset()
        decoder.reset()
        decoder.soundLevel = nil
        motion.reset()
        thumbnails.reset()
        meter.reset()
        clock.reset()
    }

    /// Resets and releases the audio device.
    func stop() {
        reset()
        audio.stop()
    }

    private func report(_ kind: ActivityCenter.Kind) {
        let now = Date()
        if let previous = lastActivity[kind], now.timeIntervalSince(previous) < 1 { return }
        lastActivity[kind] = now
        onActivity?(kind)
    }
}

/// When the last video frame arrived. Written on the I/O queue, read from the main thread.
private final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var sawFrame = false

    /// Records a frame; returns true for the first one since `reset()`.
    func tick() -> Bool {
        lock.withLock {
            last = Date()
            defer { sawFrame = true }
            return !sawFrame
        }
    }

    func reset() {
        lock.withLock {
            sawFrame = false
            last = Date()
        }
    }

    var secondsSinceLastFrame: TimeInterval {
        lock.withLock { Date().timeIntervalSince(last) }
    }
}
