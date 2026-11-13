@preconcurrency import AVFoundation
import Foundation

/// G.711, the codec the monitor speaks both ways (8 kHz, one byte per sample).
enum G711 {
    enum Law: Equatable, Sendable {
        case mu, a

        /// The static RTP payload type (RFC 3551).
        var payloadType: UInt8 { self == .mu ? 0 : 8 }

        init?(codec: String) {
            let name = codec.uppercased()
            if name.hasPrefix("PCMU") { self = .mu } else if name.hasPrefix("PCMA") { self = .a } else { return nil }
        }
    }

    static func encode(_ samples: [Int16], law: Law) -> Data {
        Data(samples.map { law == .mu ? muLaw($0) : aLaw($0) })
    }

    /// ITU-T G.711 μ-law, the inverse of `AudioOutput.table`.
    static func muLaw(_ sample: Int16) -> UInt8 {
        let bias = 0x84
        let clip = 32635
        var value = Int(sample)
        let sign: UInt8 = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0 && value & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return ~(sign | UInt8(exponent << 4) | UInt8(mantissa))
    }

    /// ITU-T G.711 A-law.
    static func aLaw(_ sample: Int16) -> UInt8 {
        var value = Int(sample) >> 3 // 13-bit magnitude
        let sign: UInt8
        if value >= 0 {
            sign = 0x80
        } else {
            sign = 0
            value = -value - 1
        }
        let segmentEnds = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]
        let segment = segmentEnds.firstIndex { value <= $0 } ?? 8
        let code: Int
        if segment >= 8 {
            code = 0x7F
        } else {
            code = segment << 4 | ((value >> (segment < 2 ? 1 : segment)) & 0x0F)
        }
        return (sign | UInt8(code)) ^ 0x55
    }
}

/// Builds RTP packets (RFC 3550) for the talkback channel, 20 ms of G.711 each.
struct RTPPacketizer {
    let payloadType: UInt8
    private(set) var sequence = UInt16.random(in: .min ... .max)
    private(set) var timestamp = UInt32.random(in: .min ... .max)
    let ssrc = UInt32.random(in: .min ... .max)
    /// Set on the first packet after a silence, so the receiver resets its jitter buffer.
    private var startOfTalkspurt = true

    init(payloadType: UInt8) {
        self.payloadType = payloadType
    }

    mutating func packet(_ payload: Data) -> Data {
        var out = Data(capacity: 12 + payload.count)
        out.append(0x80)
        out.append((startOfTalkspurt ? 0x80 : 0) | payloadType)
        out.append(contentsOf: [UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
        out.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        out.append(payload)
        startOfTalkspurt = false
        sequence &+= 1
        timestamp &+= UInt32(payload.count) // one sample per byte at 8 kHz
        return out
    }

    /// Call when the user stops talking.
    mutating func endTalkspurt() { startOfTalkspurt = true }

    /// RTP over the RTSP connection (RFC 2326 §10.12): '$', channel, 16-bit length.
    static func interleave(_ packet: Data, channel: UInt8) -> Data {
        var out = Data([0x24, channel, UInt8(packet.count >> 8 & 0xFF), UInt8(packet.count & 0xFF)])
        out.append(packet)
        return out
    }
}

/// Reads the Mac's microphone and hands out 20 ms G.711 frames at 8 kHz.
/// The microphone is open only between `start` and `stop`.
final class MicrophoneCapture: @unchecked Sendable { // start/stop on the main thread; frames on `queue`
    static let samplesPerFrame = 160 // 20 ms at 8 kHz

    private let law: G711.Law
    private let queue: DispatchQueue
    private let onFrame: (Data) -> Void
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pending: [Int16] = [] // touched only on `queue`
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    init(law: G711.Law, queue: DispatchQueue, onFrame: @escaping (Data) -> Void) {
        self.law = law
        self.queue = queue
        self.onFrame = onFrame
    }

    enum Failure: LocalizedError {
        case noInput
        var errorDescription: String? { "Aucun micro disponible" }
    }

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target)
        else { throw Failure.noInput }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        queue.async { [self] in pending.removeAll() }
    }

    /// On the audio thread.
    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        queue.async { [self] in
            pending.append(contentsOf: samples)
            while pending.count >= Self.samplesPerFrame {
                onFrame(G711.encode(Array(pending.prefix(Self.samplesPerFrame)), law: law))
                pending.removeFirst(Self.samplesPerFrame)
            }
        }
    }
}
