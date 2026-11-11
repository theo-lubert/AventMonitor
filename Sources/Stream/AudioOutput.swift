import AVFoundation

/// Plays the monitor's 8 kHz G.711 μ-law audio. Output only: the microphone is never opened.
final class AudioOutput: @unchecked Sendable { // confined to the stream queue
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var attached = false
    private var running = false
    private var queuedFrames = 0
    private var failed = false

    /// Drop audio rather than let latency build past half a second.
    private let maxQueuedFrames = 4000

    var muted = false {
        didSet { player.volume = muted ? 0 : 1 }
    }

    static let table: [Float] = (0...255).map { value in
        let u = ~UInt8(value)
        let exponent = Int((u >> 4) & 0x07)
        let mantissa = Int(u & 0x0F)
        let magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Float(u & 0x80 != 0 ? -magnitude : magnitude) / 32768
    }

    /// Called from the stream queue with one RTP payload.
    func push(_ payload: Data) {
        guard !payload.isEmpty, !failed else { return }
        if !running { start() }
        guard running else { return }

        let frames = payload.count
        lock.lock()
        if queuedFrames + frames > maxQueuedFrames {
            lock.unlock()
            return
        }
        queuedFrames += frames
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        payload.withUnsafeBytes { raw in
            for (i, byte) in raw.bindMemory(to: UInt8.self).enumerated() { out[i] = Self.table[Int(byte)] }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames -= frames
            self.lock.unlock()
        }
    }

    private func start() {
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        do {
            try engine.start()
            player.volume = muted ? 0 : 1
            player.play()
            running = true
        } catch {
            failed = true
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
        lock.lock()
        queuedFrames = 0
        lock.unlock()
    }
}
