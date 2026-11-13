import Foundation

/// How `RoomControls` reaches a camera. The app goes through the cloud via AventCore;
/// tests pass fakes, so they never touch a real camera.
struct RoomTransport {
    var fetch: @MainActor (_ cameraID: String) async throws -> DeviceSnapshot
    var send: @MainActor (_ cameraID: String, _ dps: [String: DPValue]) async throws -> Void
}

/// Night light, lullabies and temperature of one camera.
///
/// The state is read from the cloud while someone looks at it (the panel or the camera
/// window), never in the background. Commands update the state at once and hold the
/// values they set for a few seconds, because the cloud reports the old value for a
/// moment after a command.
@MainActor
final class RoomControls: ObservableObject {
    let cameraID: String
    @Published private(set) var state: RoomState?
    @Published private(set) var error: String?
    /// When `state` was read, for counting timers down between reads.
    @Published private(set) var readAt = Date.distantPast

    private let transport: RoomTransport
    private var watchers = 0
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var held: [String: (value: DPValue, until: Date)] = [:]

    /// Between reads while watched. The Home Assistant integration polls every 30 s.
    var pollInterval: TimeInterval = 15
    /// How long a value we set wins over what the cloud reports.
    var holdDuration: TimeInterval = 8
    /// The cloud takes a moment to see a command's effect; read again after it.
    var settleDelay: TimeInterval = 3

    init(cameraID: String, transport: RoomTransport) {
        self.cameraID = cameraID
        self.transport = transport
    }

    // MARK: Reading

    /// Starts reading the state while at least one view shows it.
    func watch() {
        watchers += 1
        guard watchers == 1 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    var isWatched: Bool { watchers > 0 }

    /// Stops every read and pending refresh (on logout).
    func shutdown() {
        watchers = 0
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        do {
            let snapshot = try await transport.fetch(cameraID)
            apply(snapshot)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ snapshot: DeviceSnapshot) {
        var dps = state?.dps ?? [:]
        dps.merge(snapshot.dps) { _, new in new }
        let now = Date()
        held = held.filter { $0.value.until > now }
        for (key, hold) in held { dps[key] = hold.value }
        state = RoomState(online: snapshot.online, dps: dps)
        readAt = now
    }

    // MARK: Commands

    func setNightLight(_ on: Bool) { send([DP.nightLight: .bool(on)]) }

    /// 1…100. Turns the light on, as moving the slider of a light that is off would suggest.
    func setBrightness(_ percent: Int) {
        var dps: [String: DPValue] = [DP.brightness: .int(min(100, max(1, percent)))]
        if state?.nightLight != true { dps[DP.nightLight] = .bool(true) }
        send(dps)
    }

    /// Seconds before the light turns off by itself; nil for never.
    func setLightTimer(_ seconds: Int?) {
        if let seconds {
            send([DP.lightTimerOn: .bool(true), DP.lightTimer: .int(seconds)], also: [DP.lightRemaining: .int(seconds)])
        } else {
            send([DP.lightTimerOn: .bool(false)], also: [DP.lightRemaining: .int(-1)])
        }
    }

    func playPause() {
        if state?.lullabyPlaying == true { pause() } else { play() }
    }

    func play() { send([DP.lullabyControl: .string("play")], also: [DP.lullabyState: .string("playing")]) }
    func pause() { send([DP.lullabyControl: .string("pause")], also: [DP.lullabyState: .string("stopping")]) }

    func play(_ track: Lullaby.Track) {
        let id = Lullaby.id(of: track, current: state?.currentTrackID)
        send([DP.lullabyTrack: .string(Lullaby.playPayload(id: id)), DP.lullabyControl: .string("play")],
             also: [DP.lullabyState: .string("playing"),
                    DP.lullabyCurrent: .string(#"{"bizcode":"phi-no-bm","id":\#(id),"errcode":0}"#)])
    }

    /// Next and previous are relative: the new track is only known on the next read.
    func next() { send([DP.lullabyControl: .string("next")], also: [DP.lullabyState: .string("playing")]) }
    func previous() { send([DP.lullabyControl: .string("prev")], also: [DP.lullabyState: .string("playing")]) }

    func setVolume(_ percent: Int) { send([DP.volume: .int(min(100, max(1, percent)))]) }

    func setPlayMode(_ mode: PlayMode) { send([DP.lullabyMode: .string(mode.rawValue)]) }

    /// Seconds before the lullaby stops by itself; nil for never.
    func setLullabyTimer(_ seconds: Int?) {
        if let seconds {
            send([DP.lullabyTimerOn: .bool(true), DP.lullabyTimer: .int(seconds)], also: [DP.lullabyRemaining: .int(seconds)])
        } else {
            send([DP.lullabyTimerOn: .bool(false)], also: [DP.lullabyRemaining: .int(-1)])
        }
    }

    /// Sends `dps`, shows them (and the `also` values they imply) right away, and holds both
    /// against stale reads. Control commands (201) are actions, not state, so they are not held.
    private func send(_ dps: [String: DPValue], also implied: [String: DPValue] = [:]) {
        let until = Date().addingTimeInterval(holdDuration)
        var shown = state?.dps ?? [:]
        for (key, value) in dps.merging(implied, uniquingKeysWith: { a, _ in a }) where key != DP.lullabyControl {
            held[key] = (value, until)
            shown[key] = value
        }
        state = RoomState(online: state?.online ?? true, dps: shown)
        error = nil
        let transport = transport
        let cameraID = cameraID
        Task { [weak self] in
            do {
                try await transport.send(cameraID, dps)
            } catch {
                guard let self else { return }
                // Show the camera's real state again rather than what we hoped for.
                for key in dps.keys { self.held[key] = nil }
                for key in implied.keys { self.held[key] = nil }
                await self.refresh()
                self.error = error.localizedDescription
                return
            }
            self?.scheduleSettleRefresh()
        }
    }

    private func scheduleSettleRefresh() {
        refreshTask?.cancel()
        let delay = settleDelay
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}
