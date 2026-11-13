import CoreMedia
import XCTest

final class RTPPacketTests: XCTestCase {
    private func header(marker: Bool = false, sequence: UInt16 = 7, timestamp: UInt32 = 0x0102_0304,
                        flags: UInt8 = 0) -> [UInt8] {
        [0x80 | flags, (marker ? 0x80 : 0) | 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
         UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xFF), UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
         0, 0, 0, 1]
    }

    func testParsesHeaderAndPayload() throws {
        let packet = try XCTUnwrap(RTPPacket(Data(header(marker: true) + [0xAA, 0xBB])))
        XCTAssertTrue(packet.marker)
        XCTAssertEqual(packet.sequence, 7)
        XCTAssertEqual(packet.timestamp, 0x0102_0304)
        XCTAssertEqual(packet.payload, Data([0xAA, 0xBB]))
    }

    func testSkipsCSRCsAndExtension() throws {
        // 1 CSRC, plus a header extension of one 32-bit word.
        let bytes = header(flags: 0x10 | 0x01) + [9, 9, 9, 9] + [0xBE, 0xDE, 0, 1, 5, 5, 5, 5] + [0xCC]
        XCTAssertEqual(try XCTUnwrap(RTPPacket(Data(bytes))).payload, Data([0xCC]))
    }

    func testStripsPadding() throws {
        let bytes = header(flags: 0x20) + [0xCC, 0, 0, 3]
        XCTAssertEqual(try XCTUnwrap(RTPPacket(Data(bytes))).payload, Data([0xCC]))
    }

    func testRejectsMalformedPackets() {
        XCTAssertNil(RTPPacket(Data([0x80, 0, 0])), "too short")
        XCTAssertNil(RTPPacket(Data([0x40] + header().dropFirst())), "wrong version")
        XCTAssertNil(RTPPacket(Data(header(flags: 0x20) + [0xCC, 200])), "padding longer than the packet")
        XCTAssertNil(RTPPacket(Data(header(flags: 0x10) + [0, 0])), "truncated extension")
    }

    func testPayloadIsZeroBased() throws {
        // Payloads are indexed from 0 even when the source Data is a slice.
        let data = Data([0xFF] + header() + [0xAA]).dropFirst()
        let payload = try XCTUnwrap(RTPPacket(data)).payload
        XCTAssertEqual(payload.startIndex, 0)
        XCTAssertEqual(payload.first, 0xAA)
    }
}

final class SDPTests: XCTestCase {
    func testParsesMediaCodecsAndControls() {
        let sdp = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=control:trackID=0\r
        m=audio 0 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=control:rtsp://127.0.0.1:38554/cam/trackID=1\r
        """
        let media = RTSPClient.parseSDP(sdp)
        XCTAssertEqual(media.map(\.kind), ["video", "audio"])
        XCTAssertEqual(media.map(\.codec), ["H264/90000", "PCMU/8000"])
        XCTAssertEqual(media.map(\.control), ["trackID=0", "rtsp://127.0.0.1:38554/cam/trackID=1"])
    }

    func testResolvesControlURLs() {
        let base = "rtsp://127.0.0.1:38554/cam"
        XCTAssertEqual(RTSPClient.resolve("trackID=0", base: base), base + "/trackID=0")
        XCTAssertEqual(RTSPClient.resolve("trackID=0", base: base + "/"), base + "/trackID=0")
        XCTAssertEqual(RTSPClient.resolve("*", base: base), base)
        XCTAssertEqual(RTSPClient.resolve("", base: base), base)
        XCTAssertEqual(RTSPClient.resolve("RTSP://other/x", base: base), "RTSP://other/x")
    }
}

final class H264AssemblerTests: XCTestCase {
    // A 64x48 baseline stream's parameter sets.
    private let sps = Data(hex: "6742c00ad9047b011000000300100000030020f1226480")
    private let pps = Data(hex: "68cb83cb20")
    private var sequence: UInt16 = 0

    private func packet(_ payload: Data, timestamp: UInt32, marker: Bool) -> RTPPacket {
        defer { sequence &+= 1 }
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
        bytes += [0, 0, 0, 1]
        return RTPPacket(Data(bytes) + payload)!
    }

    private func stapA(_ nals: Data...) -> Data {
        var out = Data([24])
        for nal in nals { out += [UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal }
        return out
    }

    /// Splits a NAL into FU-A fragments of `size` bytes.
    private func fuA(_ nal: Data, size: Int) -> [Data] {
        let indicator = (nal[0] & 0xE0) | 28
        let type = nal[0] & 0x1F
        let body = nal.dropFirst()
        return stride(from: body.startIndex, to: body.endIndex, by: size).map { start in
            let end = min(start + size, body.endIndex)
            let flags: UInt8 = (start == body.startIndex ? 0x80 : 0) | (end == body.endIndex ? 0x40 : 0)
            return Data([indicator, flags | type]) + body[start..<end]
        }
    }

    private func avcc(_ sample: CMSampleBuffer) -> Data {
        let block = CMSampleBufferGetDataBuffer(sample)!
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        return data
    }

    private func isSync(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    func testAssemblesKeyframeAndDeltaFrame() throws {
        let assembler = H264Assembler()
        var samples: [CMSampleBuffer] = []
        var dimensions: CMVideoDimensions?
        assembler.onSample = { samples.append($0) }
        assembler.onDimensions = { dimensions = $0 }

        // A delta frame before any keyframe is dropped.
        assembler.push(packet(Data([0x41, 1, 2, 3]), timestamp: 0, marker: true))
        XCTAssertTrue(samples.isEmpty)

        let idr = Data([0x65] + (0..<10).map { UInt8($0) })
        assembler.push(packet(stapA(sps, pps), timestamp: 3000, marker: false))
        for (i, fragment) in fuA(idr, size: 4).enumerated() {
            assembler.push(packet(fragment, timestamp: 3000, marker: i == 2))
        }
        assembler.push(packet(Data([0x41, 7, 8]), timestamp: 6000, marker: true))

        XCTAssertEqual(dimensions?.width, 64)
        XCTAssertEqual(dimensions?.height, 48)
        XCTAssertEqual(samples.count, 2)
        let key = try XCTUnwrap(samples.first)
        XCTAssertEqual(avcc(key), Data([0, 0, 0, UInt8(idr.count)]) + idr, "the IDR, length-prefixed, without SPS/PPS")
        XCTAssertTrue(isSync(key))
        XCTAssertFalse(isSync(samples[1]))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(samples[1]).value
                       - CMSampleBufferGetPresentationTimeStamp(key).value, 3000)
    }

    func testDropsFragmentAfterPacketLoss() {
        let assembler = H264Assembler()
        var samples: [CMSampleBuffer] = []
        assembler.onSample = { samples.append($0) }
        assembler.push(packet(stapA(sps, pps), timestamp: 0, marker: false))
        let fragments = fuA(Data([0x65] + (0..<12).map { UInt8($0) }), size: 4)
        assembler.push(packet(fragments[0], timestamp: 0, marker: false))
        sequence &+= 1 // lose fragments[1]
        assembler.push(packet(fragments[2], timestamp: 0, marker: true))
        XCTAssertTrue(samples.isEmpty, "a NAL with a missing fragment must not be emitted")
    }
}

final class AudioTests: XCTestCase {
    func testMuLawTable() {
        XCTAssertEqual(AudioOutput.table[0xFF], 0)
        XCTAssertEqual(AudioOutput.table[0x7F], 0)
        XCTAssertEqual(AudioOutput.table[0x80], 32124 / 32768, accuracy: 1e-6)
        XCTAssertEqual(AudioOutput.table[0x00], -32124 / 32768, accuracy: 1e-6)
    }

    func testSoundMeterLevels() {
        let meter = SoundMeter()
        var levels: [Int] = []
        var loud = 0
        meter.onLevel = { levels.append($0) }
        meter.onLoud = { loud += 1 }

        meter.push(Data(repeating: 0xFF, count: 800)) // 100 ms of silence
        XCTAssertEqual(levels, [0])
        meter.push(Data(repeating: 0x80, count: 800)) // 100 ms at full scale
        XCTAssertEqual(levels, [0, 3])
        XCTAssertEqual(loud, 0, "a single loud window is a click, not sound")

        // The level is held for 500 ms, then released one step at a time.
        meter.push(Data(repeating: 0xFF, count: 800 * 4))
        XCTAssertEqual(levels, [0, 3])
        meter.push(Data(repeating: 0xFF, count: 800))
        XCTAssertEqual(levels, [0, 3, 2])
    }

    func testSoundMeterNeedsSustainedSound() {
        let meter = SoundMeter()
        var loud = 0
        meter.onLoud = { loud += 1 }
        let window = 800 // 100 ms
        meter.push(Data(repeating: 0x80, count: window * (SoundMeter.loudWindowsNeeded - 1)))
        XCTAssertEqual(loud, 0)
        meter.push(Data(repeating: 0x80, count: window))
        XCTAssertEqual(loud, 1)
        // Silence resets the count.
        meter.push(Data(repeating: 0xFF, count: window))
        meter.push(Data(repeating: 0x80, count: window))
        XCTAssertEqual(loud, 1)
    }
}

final class MotionDetectorTests: XCTestCase {
    private func frame(brightness: UInt8, square: CGRect? = nil) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<180 {
            for x in 0..<320 {
                let lit = square?.contains(CGPoint(x: x, y: y)) == true
                let p = base + y * stride + x * 4
                p[0] = lit ? 255 : brightness; p[1] = p[0]; p[2] = p[0]; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    /// Feeds frames past the detector's rate limit.
    private func feed(_ detector: MotionDetector, _ frames: [CVPixelBuffer]) {
        for f in frames {
            detector.analyze(f)
            Thread.sleep(forTimeInterval: 0.26)
        }
    }

    func testMovingObjectIsMotion() {
        let detector = MotionDetector()
        var motion = 0
        detector.onMotion = { motion += 1 }
        feed(detector, [
            frame(brightness: 40),
            frame(brightness: 40, square: CGRect(x: 20, y: 20, width: 40, height: 40)),
            frame(brightness: 40, square: CGRect(x: 120, y: 60, width: 40, height: 40)),
        ])
        XCTAssertEqual(motion, 1, "two changed analyses in a row")
    }

    func testGlobalLightingChangeIsNotMotion() {
        let detector = MotionDetector()
        var motion = 0
        detector.onMotion = { motion += 1 }
        feed(detector, [frame(brightness: 40), frame(brightness: 90), frame(brightness: 160)])
        XCTAssertEqual(motion, 0)
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
