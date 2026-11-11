import CoreMedia
import Foundation

/// Turns H.264 RTP packets (RFC 6184: single NAL, STAP-A, FU-A) into
/// AVCC CMSampleBuffers ready for AVSampleBufferDisplayLayer.
final class H264Assembler: @unchecked Sendable { // confined to the stream queue
    var onSample: ((CMSampleBuffer) -> Void)?
    var onDimensions: ((CMVideoDimensions) -> Void)?

    private var nals: [Data] = []
    private var currentTimestamp: UInt32?
    private var fragment: Data?
    private var lastSequence: UInt16?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var haveKeyframe = false
    private var lastRaw: UInt32?
    private var unwrapped: Int64 = 0

    func reset() {
        nals.removeAll()
        currentTimestamp = nil
        fragment = nil
        lastSequence = nil
        haveKeyframe = false
        lastRaw = nil
        unwrapped = 0
    }

    func push(_ packet: RTPPacket) {
        if let last = lastSequence, packet.sequence != last &+ 1 { fragment = nil }
        lastSequence = packet.sequence
        if let ts = currentTimestamp, ts != packet.timestamp { flush() }
        currentTimestamp = packet.timestamp

        let p = packet.payload
        guard let first = p.first else { return }
        let start = p.startIndex
        switch first & 0x1F {
        case 1...23:
            nals.append(p)
        case 24: // STAP-A
            var i = start + 1
            while i + 2 <= p.endIndex {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.endIndex else { break }
                nals.append(p.subdata(in: i..<(i + size)))
                i += size
            }
        case 28: // FU-A
            guard p.count > 2 else { return }
            let header = p[start + 1]
            let body = p.subdata(in: (start + 2)..<p.endIndex)
            if header & 0x80 != 0 {
                var nal = Data([(first & 0xE0) | (header & 0x1F)])
                nal.append(body)
                fragment = nal
            } else if fragment != nil {
                fragment?.append(body)
            }
            if header & 0x40 != 0, let nal = fragment {
                nals.append(nal)
                fragment = nil
            }
        default:
            break
        }
        if packet.marker { flush() }
    }

    private func flush() {
        defer { nals.removeAll(keepingCapacity: true) }
        guard !nals.isEmpty, let ts = currentTimestamp else { return }

        var frame: [Data] = []
        var isKeyframe = false
        var parametersChanged = false
        for nal in nals {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7: if sps != nal { sps = nal; parametersChanged = true }
            case 8: if pps != nal { pps = nal; parametersChanged = true }
            case 9: continue // access unit delimiter
            case 5: isKeyframe = true; frame.append(nal)
            default: frame.append(nal)
            }
        }
        if parametersChanged || format == nil { makeFormat() }
        guard let format, !frame.isEmpty else { return }
        if !haveKeyframe {
            guard isKeyframe else { return }
            haveKeyframe = true
        }
        if let sample = makeSample(frame, format: format, pts: unwrap(ts), keyframe: isKeyframe) {
            onSample?(sample)
        }
    }

    private func unwrap(_ ts: UInt32) -> Int64 {
        if let last = lastRaw {
            unwrapped += Int64(Int32(bitPattern: ts &- last))
        }
        lastRaw = ts
        return unwrapped
    }

    private func makeFormat() {
        guard let sps, let pps else { return }
        var out: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        guard status == noErr, let out else { return }
        format = out
        onDimensions?(CMVideoFormatDescriptionGetDimensions(out))
    }

    private func makeSample(_ frame: [Data], format: CMVideoFormatDescription, pts: Int64, keyframe: Bool) -> CMSampleBuffer? {
        var avcc = Data(capacity: frame.reduce(0) { $0 + $1.count + 4 })
        for nal in frame {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        let count = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        sample.setAttachment(kCMSampleAttachmentKey_DisplayImmediately)
        if !keyframe { sample.setAttachment(kCMSampleAttachmentKey_NotSync) }
        return sample
    }
}
