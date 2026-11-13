import XCTest

// Everything here runs against fakes: no test reaches the cloud or a camera.

final class RoomStateTests: XCTestCase {
    func testDecodesMixedDataPoints() throws {
        let json = #"{"online":true,"dps":{"138":true,"158":30,"203":"loop1","207":2150,"246":"playing","248":"{\"bizcode\":\"phi-no-bm\",\"id\":3542155,\"errcode\":0}","999":{"x":1},"998":1.5}}"#
        let snap = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(json.utf8))
        let state = RoomState(online: snap.online, dps: snap.dps)
        XCTAssertEqual(state.nightLight, true)
        XCTAssertEqual(state.brightness, 30)
        XCTAssertEqual(state.playMode, .loop1)
        XCTAssertEqual(try XCTUnwrap(state.temperature), 21.5, accuracy: 0.001)
        XCTAssertEqual(state.lullabyPlaying, true)
        XCTAssertEqual(state.currentTrack?.name, "Berceuse de Brahms")
        XCTAssertEqual(snap.dps["999"], .other)
        XCTAssertEqual(snap.dps["998"], .other)
    }

    func testUnknownFieldsStayNil() {
        let state = RoomState(online: true, dps: [:])
        XCTAssertNil(state.nightLight)
        XCTAssertNil(state.lullabyPlaying)
        XCTAssertNil(state.temperature)
        XCTAssertNil(state.currentTrack)
    }

    func testTimersNeedTheirSwitchAndIgnoreNegativeRemaining() {
        var state = RoomState(online: true, dps: [DP.lightTimer: .int(1800), DP.lightTimerOn: .bool(false),
                                                  DP.lightRemaining: .int(-1)])
        XCTAssertNil(state.lightTimer)
        XCTAssertNil(state.lightRemaining)
        state.dps[DP.lightTimerOn] = .bool(true)
        state.dps[DP.lightRemaining] = .int(1200)
        XCTAssertEqual(state.lightTimer, 1800)
        XCTAssertEqual(state.lightRemaining, 1200)
    }

    func testLullabyBlocks() throws {
        let brahms = Lullaby.catalogue[1]
        XCTAssertEqual(Lullaby.track(id: 3_542_155), brahms)
        XCTAssertEqual(Lullaby.track(id: 12_072_917), brahms)
        XCTAssertNil(Lullaby.track(id: 3_542_154 + 15))
        // Plays in the block the camera reported, the original one by default.
        XCTAssertEqual(Lullaby.id(of: brahms, current: nil), 3_542_155)
        XCTAssertEqual(Lullaby.id(of: brahms, current: 12_072_930), 12_072_917)
        XCTAssertEqual(Lullaby.id(of: brahms, current: 42), 3_542_155)
        XCTAssertEqual(Lullaby.playPayload(id: 3_542_155), #"{"bizcode":"phi-no-bm","id":3542155}"#)
        XCTAssertEqual(Lullaby.catalogue.count, 15)
    }

    func testEncodesCommandsAsPlainJSONValues() throws {
        let session = Session(sid: "s", ecode: "", partner: "", uid: "", email: "", nickname: "", apiHost: "",
                              deviceId: "", country: "")
        let params = SetDPSParams(session: session, id: "cam", dps: [DP.nightLight: .bool(true), DP.brightness: .int(30),
                                                                     DP.lullabyControl: .string("play")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        let dps = try XCTUnwrap(object["dps"] as? [String: Any])
        XCTAssertEqual(dps["138"] as? Bool, true)
        XCTAssertEqual(dps["158"] as? Int, 30)
        XCTAssertEqual(dps["201"] as? String, "play")
    }

    func testTimerLabels() {
        XCTAssertEqual(RoomTimer.choices.map(RoomTimer.label), ["15 min", "30 min", "1 h", "1 h 30"])
        XCTAssertEqual(RoomTimer.remaining(30), "< 1 min")
        XCTAssertEqual(RoomTimer.remaining(17 * 60 + 1), "18 min")
        XCTAssertEqual(RoomTimer.remaining(3900), "1 h 05")
    }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "refusé" }
}

@MainActor
final class RoomControlsTests: XCTestCase {
    /// A camera that lives in memory. `delivered` is what the cloud "sees" on the next read.
    final class FakeCamera {
        var dps: [String: DPValue]
        var sent: [[String: DPValue]] = []
        var fetches = 0
        var failSends = false
        var applySends = false

        init(_ dps: [String: DPValue]) { self.dps = dps }

        var transport: RoomTransport {
            RoomTransport(
                fetch: { [unowned self] _ in
                    fetches += 1
                    return DeviceSnapshot(online: true, dps: dps)
                },
                send: { [unowned self] _, dps in
                    sent.append(dps)
                    if failSends { throw Refused() }
                    if applySends { self.dps.merge(dps) { _, new in new } }
                })
        }
    }

    private func controls(_ camera: FakeCamera) -> RoomControls {
        let room = RoomControls(cameraID: "cam", transport: camera.transport)
        room.settleDelay = 3600 // tests read explicitly
        return room
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    func testCommandShowsAtOnceAndWinsOverStaleReads() async {
        let camera = FakeCamera([DP.nightLight: .bool(false)])
        let room = controls(camera)
        await room.refresh()
        XCTAssertEqual(room.state?.nightLight, false)

        room.setNightLight(true)
        XCTAssertEqual(room.state?.nightLight, true, "shown before the cloud answers")
        await waitUntil { camera.sent.count == 1 }
        XCTAssertEqual(camera.sent.first, [DP.nightLight: .bool(true)])

        await room.refresh() // the cloud still reports the old value
        XCTAssertEqual(room.state?.nightLight, true)

        room.holdDuration = 0
        room.setNightLight(false)
        await waitUntil { camera.sent.count == 2 }
        camera.dps[DP.nightLight] = .bool(true) // someone turned it on from the phone
        await room.refresh()
        XCTAssertEqual(room.state?.nightLight, true, "once the hold ends, the camera's state wins")
    }

    func testFailedCommandShowsTheRealStateAgain() async {
        let camera = FakeCamera([DP.nightLight: .bool(false)])
        camera.failSends = true
        let room = controls(camera)
        await room.refresh()
        room.setNightLight(true)
        await waitUntil { room.error != nil && room.state?.nightLight == false }
        XCTAssertEqual(room.error, "refusé")
    }

    func testBrightnessTurnsTheLightOn() async {
        let camera = FakeCamera([DP.nightLight: .bool(false), DP.brightness: .int(50)])
        let room = controls(camera)
        await room.refresh()
        room.setBrightness(250)
        await waitUntil { camera.sent.count == 1 }
        XCTAssertEqual(camera.sent.first, [DP.brightness: .int(100), DP.nightLight: .bool(true)])
    }

    func testPlayingATrackUsesTheCamerasBlock() async {
        let camera = FakeCamera([DP.lullabyState: .string("stopping"),
                                 DP.lullabyCurrent: .string(#"{"bizcode":"phi-no-bm","id":12072916,"errcode":0}"#)])
        let room = controls(camera)
        await room.refresh()
        let rain = Lullaby.catalogue[14]
        room.play(rain)
        XCTAssertEqual(room.state?.lullabyPlaying, true)
        XCTAssertEqual(room.state?.currentTrack, rain)
        await waitUntil { camera.sent.count == 1 }
        XCTAssertEqual(camera.sent.first, [DP.lullabyTrack: .string(#"{"bizcode":"phi-no-bm","id":12072930}"#),
                                           DP.lullabyControl: .string("play")])
    }

    func testPlayPauseAndTimers() async {
        let camera = FakeCamera([DP.lullabyState: .string("playing")])
        let room = controls(camera)
        await room.refresh()
        room.playPause()
        XCTAssertEqual(room.state?.lullabyPlaying, false)
        room.setLullabyTimer(1800)
        room.setLightTimer(nil)
        await waitUntil { camera.sent.count == 3 }
        XCTAssertEqual(camera.sent[0], [DP.lullabyControl: .string("pause")])
        XCTAssertEqual(camera.sent[1], [DP.lullabyTimerOn: .bool(true), DP.lullabyTimer: .int(1800)])
        XCTAssertEqual(camera.sent[2], [DP.lightTimerOn: .bool(false)])
        XCTAssertEqual(room.state?.lullabyTimer, 1800)
        XCTAssertEqual(room.state?.lullabyRemaining, 1800)
    }

    func testReadsOnlyWhileWatched() async throws {
        let camera = FakeCamera([:])
        let room = controls(camera)
        room.pollInterval = 0.05
        room.watch()
        room.watch()
        await waitUntil { camera.fetches >= 2 }
        room.unwatch()
        XCTAssertTrue(room.isWatched, "still watched by the second view")
        room.unwatch()
        XCTAssertFalse(room.isWatched)
        try await Task.sleep(for: .milliseconds(100))
        let count = camera.fetches
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(camera.fetches, count, "no reads once nobody watches")
    }
}

final class TalkbackTests: XCTestCase {
    /// ITU-T G.711 A-law decoder, to check the encoder against.
    private func aLawDecode(_ byte: UInt8) -> Int {
        let a = Int(byte ^ 0x55)
        var t = (a & 0x0F) << 4
        let seg = (a & 0x70) >> 4
        switch seg {
        case 0: t += 8
        case 1: t += 0x108
        default: t = (t + 0x108) << (seg - 1)
        }
        return a & 0x80 != 0 ? t : -t
    }

    func testMuLawRoundTrips() {
        XCTAssertEqual(G711.muLaw(0), 0xFF)
        for sample in stride(from: -32768, through: 32767, by: 97) {
            let decoded = Int(AudioOutput.table[Int(G711.muLaw(Int16(sample)))] * 32768)
            // μ-law keeps about 4 bits of mantissa: the error grows with the magnitude.
            XCTAssertLessThanOrEqual(abs(decoded - sample), max(8, abs(sample) / 16 + 132), "sample \(sample)")
        }
    }

    func testALawRoundTrips() {
        XCTAssertEqual(G711.aLaw(0), 0xD5)
        for sample in stride(from: -32768, through: 32767, by: 97) {
            let decoded = aLawDecode(G711.aLaw(Int16(sample)))
            XCTAssertLessThanOrEqual(abs(decoded - sample), max(16, abs(sample) / 16 + 16), "sample \(sample)")
        }
    }

    func testCodecNames() {
        XCTAssertEqual(G711.Law(codec: "PCMU/8000"), .mu)
        XCTAssertEqual(G711.Law(codec: "pcma/8000"), .a)
        XCTAssertNil(G711.Law(codec: "opus/48000/2"))
        XCTAssertEqual(G711.Law.mu.payloadType, 0)
        XCTAssertEqual(G711.Law.a.payloadType, 8)
    }

    func testPacketizerBuildsValidRTP() throws {
        var p = RTPPacketizer(payloadType: 8)
        let frame = Data(repeating: 0xD5, count: 160)
        let first = try XCTUnwrap(RTPPacket(p.packet(frame)))
        let second = try XCTUnwrap(RTPPacket(p.packet(frame)))
        XCTAssertTrue(first.marker, "a talkspurt starts with the marker bit")
        XCTAssertFalse(second.marker)
        XCTAssertEqual(second.sequence, first.sequence &+ 1)
        XCTAssertEqual(second.timestamp, first.timestamp &+ 160)
        XCTAssertEqual(first.payload, frame)
        p.endTalkspurt()
        XCTAssertTrue(try XCTUnwrap(RTPPacket(p.packet(frame))).marker)
        let raw = p.packet(frame)
        XCTAssertEqual(raw[1] & 0x7F, 8, "payload type")
    }

    func testInterleavedFraming() {
        let packet = Data(repeating: 1, count: 300)
        let framed = RTPPacketizer.interleave(packet, channel: 4)
        XCTAssertEqual(Array(framed.prefix(4)), [0x24, 4, 0x01, 0x2C])
        XCTAssertEqual(framed.dropFirst(4), packet)
    }

    func testFindsTheBridgesBackchannel() {
        // As aventproxy's RTSP server describes a stream with talkback on.
        let sdp = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=control:rtsp://127.0.0.1:38554/cam/video\r
        a=recvonly\r
        m=audio 0 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=control:rtsp://127.0.0.1:38554/cam/audio\r
        a=recvonly\r
        m=audio 0 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=control:rtsp://127.0.0.1:38554/cam/backchannel\r
        a=sendonly\r
        """
        let media = RTSPClient.parseSDP(sdp)
        XCTAssertEqual(media.map(\.isBackchannel), [false, false, true])
        XCTAssertEqual(media[2].direction, "sendonly")
        XCTAssertEqual(G711.Law(codec: media[2].codec), .mu)
    }
}
