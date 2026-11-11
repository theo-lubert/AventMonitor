import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Account, cameras and the embedded bridge.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case starting, loggedOut, loggedIn }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var session: Session?
    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var bridge: BridgeInfo?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var coreFailure: String?

    // Login flow
    @Published private(set) var awaitingCode = false
    @Published private(set) var codeSentTo = ""
    private var pendingLogin: LoginParams?

    // Appearance
    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            if !showDockIcon && !showMenuBarIcon { showMenuBarIcon = true }
            UserDefaults.standard.set(showDockIcon, forKey: DefaultsKey.dock)
            applyActivationPolicy()
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            if !showMenuBarIcon && !showDockIcon { showDockIcon = true }
            UserDefaults.standard.set(showMenuBarIcon, forKey: DefaultsKey.menuBar)
        }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Ouverture au démarrage : \(error.localizedDescription)"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Sound and movement detected on open streams.
    let activity = ActivityCenter()
    /// Last still of each camera, shown in the panel.
    let thumbnails = ThumbnailStore()
    private var activityObserver: AnyCancellable?
    private var liveObservers: [String: AnyCancellable] = [:]

    private var streams: [String: CameraStream] = [:]

    enum DefaultsKey {
        static let dock = "showDockIcon"
        static let menuBar = "showMenuBarIcon"
        static let country = "country"
        static let email = "lastEmail"
    }

    private init() {
        UserDefaults.standard.register(defaults: [DefaultsKey.dock: true, DefaultsKey.menuBar: true])
        showDockIcon = UserDefaults.standard.bool(forKey: DefaultsKey.dock)
        showMenuBarIcon = UserDefaults.standard.bool(forKey: DefaultsKey.menuBar)
        activityObserver = activity.$last
            .map(ActivityCenter.kinds(in:))
            .removeDuplicates()
            .sink { ActivityBadge.updateDock($0) }
    }

    var lastEmail: String { UserDefaults.standard.string(forKey: DefaultsKey.email) ?? "" }
    var lastCountry: String { UserDefaults.standard.string(forKey: DefaultsKey.country) ?? "France" }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if !showDockIcon { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Startup

    func start() async {
        guard phase == .starting else { return }
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("AventMonitor", isDirectory: true)
            try AventCore.initialize(dataDirectory: dir)
        } catch {
            coreFailure = "Le pont aventproxy n'a pas démarré : \(error.localizedDescription)"
        }
        if let saved = SessionStore.load() {
            session = saved
            phase = .loggedIn
            await refresh()
        } else {
            phase = .loggedOut
        }
    }

    // MARK: Login

    func sendCode(email: String, password: String, country: Country) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        let params = LoginParams(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                                 country: country.code, apiHost: country.apiHost, deviceId: SessionStore.deviceID)
        UserDefaults.standard.set(params.email, forKey: DefaultsKey.email)
        UserDefaults.standard.set(country.name, forKey: DefaultsKey.country)
        do {
            let step: LoginStep = try await AventCore.call("sendCode", params)
            if let s = step.session {
                await finishLogin(s)
            } else {
                pendingLogin = params
                codeSentTo = params.email
                awaitingCode = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verify(code: String) async {
        guard var params = pendingLogin else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        params.code = code.filter(\.isNumber)
        do {
            let step: LoginStep = try await AventCore.call("verify", params)
            guard let s = step.session else { throw CoreError(code: "", message: "Réponse de connexion inattendue") }
            await finishLogin(s)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelLogin() {
        pendingLogin = nil
        awaitingCode = false
        errorMessage = nil
    }

    private func finishLogin(_ s: Session) async {
        pendingLogin = nil // drops the password from memory
        awaitingCode = false
        SessionStore.save(s)
        session = s
        phase = .loggedIn
        await refresh()
    }

    func logout() {
        for stream in streams.values { stream.stop() }
        streams.removeAll()
        liveObservers.removeAll()
        thumbnails.removeAll()
        activity.clearAll()
        AventCore.stopBridgeNow()
        SessionStore.clear()
        session = nil
        cameras = []
        bridge = nil
        errorMessage = nil
        phase = .loggedOut
        NotificationCenter.default.post(name: .closeCameraWindows, object: nil)
    }

    // MARK: Cameras & bridge

    func refresh() async {
        guard var s = session else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let info: UserInfo = try await AventCore.call("userInfo", s)
            guard isCurrent(s) else { return }
            if info.nickname != s.nickname || info.email != s.email {
                s.nickname = info.nickname
                s.email = info.email.isEmpty ? s.email : info.email
                session = s
                SessionStore.save(s)
            }
            let found: [Camera] = try await AventCore.call("cameras", s)
            guard isCurrent(s) else { return }
            let changed = found.map(\.id) != cameras.map(\.id) || found.map(\.name) != cameras.map(\.name)
            cameras = found
            for cam in found { streams[cam.id]?.name = cam.name }
            if bridge == nil || changed { try await startBridge() }
            errorMessage = nil
        } catch let e as CoreError where e.isSessionExpired {
            guard isCurrent(s) else { return }
            logout()
            errorMessage = e.localizedDescription
        } catch {
            guard isCurrent(s) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// False once the user logged out (or in again) while a call was in flight.
    private func isCurrent(_ s: Session) -> Bool { session?.sid == s.sid }

    private func startBridge() async throws {
        guard let s = session, !cameras.isEmpty else {
            bridge = nil
            return
        }
        let info: BridgeInfo = try await AventCore.call(
            "startBridge", StartBridgeParams(session: s, cameras: cameras, port: Self.preferredBridgePort))
        guard isCurrent(s) else {
            AventCore.stopBridgeNow() // logged out meanwhile: don't leave it serving
            return
        }
        bridge = info
        for stream in streams.values { stream.restart() }
    }

    /// The bridge's RTSP port when free, so stream URLs stay stable across launches.
    private static let preferredBridgePort = 38554

    func streamURL(for cameraID: String) -> URL? {
        bridge?.cameras.first { $0.id == cameraID }.flatMap { URL(string: $0.url) }
    }

    func camera(_ id: String) -> Camera? { cameras.first { $0.id == id } }

    // MARK: Streams

    func stream(for cameraID: String) -> CameraStream {
        if let s = streams[cameraID] { return s }
        let s = CameraStream(cameraID: cameraID, name: camera(cameraID)?.name ?? "Caméra")
        s.urlProvider = { [weak self] in self?.streamURL(for: cameraID) }
        s.onPiPDismissed = { [weak self] in self?.closeWindow(cameraID) }
        s.onActivity = { [weak self] kind in self?.activity.report(kind, camera: cameraID) }
        s.onThumbnail = { [weak self] image in self?.thumbnails.store(image, for: cameraID) }
        liveObservers[cameraID] = s.$status
            .map { $0 == .live }
            .removeDuplicates()
            .sink { [weak self] isLive in self?.thumbnails.setLive(isLive, for: cameraID) }
        streams[cameraID] = s
        return s
    }

    func streamIfOpen(_ cameraID: String) -> CameraStream? { streams[cameraID] }

    func closeStream(_ cameraID: String) {
        guard let s = streams[cameraID], !s.pipActive else { return }
        s.stop()
        streams[cameraID] = nil
        liveObservers[cameraID] = nil
        thumbnails.setLive(false, for: cameraID)
    }

    private func closeWindow(_ cameraID: String) {
        NotificationCenter.default.post(name: .closeCameraWindow, object: cameraID)
    }

    func shutdown() {
        for stream in streams.values { stream.stop() }
        AventCore.stopBridgeNow()
    }
}

extension Notification.Name {
    static let closeCameraWindow = Notification.Name("closeCameraWindow")
    static let closeCameraWindows = Notification.Name("closeCameraWindows")
}
