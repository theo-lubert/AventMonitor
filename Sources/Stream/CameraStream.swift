import AppKit
import AVFoundation
import AVKit
import Combine

/// One live camera: RTSP from the embedded bridge, through a `MediaPipeline`, to a
/// display layer shown in a native window or in system Picture in Picture.
@MainActor
final class CameraStream: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle, waitingForBridge, connecting, live
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Arrêté"
            case .waitingForBridge: return "Démarrage du pont…"
            case .connecting: return "Connexion à la caméra…"
            case .live: return "En direct"
            case .failed(let message): return message
            }
        }
    }

    let cameraID: String
    @Published var name: String
    @Published private(set) var status: Status = .idle
    @Published private(set) var videoSize = CGSize(width: 16, height: 9) {
        didSet { if videoSize != oldValue { applyAspectRatio() } }
    }
    @Published private(set) var pipActive = false {
        didSet {
            // PiP shows only the video layer, so the sound bars go into the picture itself.
            let active = pipActive
            onPipeline { $0.drawsSoundBars = active }
        }
    }
    @Published private(set) var pipPossible = false
    /// Room sound level 0…3, nil until the camera sends audio.
    @Published private(set) var soundLevel: Int?
    @Published var muted = UserDefaults.standard.bool(forKey: DefaultsKey.muted) {
        didSet {
            let muted = muted
            onPipeline { $0.muted = muted }
            UserDefaults.standard.set(muted, forKey: DefaultsKey.muted)
        }
    }
    @Published var pinned = UserDefaults.standard.bool(forKey: DefaultsKey.pinned) {
        didSet {
            applyPin()
            UserDefaults.standard.set(pinned, forKey: DefaultsKey.pinned)
        }
    }

    let layer = AVSampleBufferDisplayLayer()
    var urlProvider: () -> URL? = { nil }
    /// Called when the user closes PiP without asking to restore the window.
    var onPiPDismissed: (() -> Void)?
    /// Called when sound or movement is detected, at most once a second per kind.
    var onActivity: ((ActivityCenter.Kind) -> Void)?
    /// Called with an occasional still, for the panel's thumbnail.
    var onThumbnail: ((CGImage) -> Void)?

    /// Time since the last video frame, for display.
    var secondsSinceLastFrame: TimeInterval { pipeline.secondsSinceLastFrame }

    private enum DefaultsKey {
        static let muted = "muted"
        static let pinned = "pinned"
    }

    private weak var window: NSWindow?
    private var wantsPiP = false
    private var restoringFromPiP = false
    private var running = false
    private var client: RTSPClient?
    private let pipeline = MediaPipeline()
    private let ioQueue = DispatchQueue(label: "camera.stream.io", qos: .userInteractive)
    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var watchdog: Timer?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var connectStarted = Date()

    init(cameraID: String, name: String) {
        self.cameraID = cameraID
        self.name = name
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor

        // The renderer is documented to accept samples from any queue.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        let muted = muted
        onPipeline { [weak self] pipeline in
            pipeline.muted = muted
            pipeline.onDisplay = { sample in
                if renderer.status == .failed { renderer.flush() }
                renderer.enqueue(sample)
            }
            pipeline.onFirstFrame = { self?.onMain { $0.didReceiveFirstFrame() } }
            pipeline.onDimensions = { dims in
                self?.onMain { $0.videoSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height)) }
            }
            pipeline.onSoundLevel = { level in self?.onMain { $0.soundLevel = level } }
            pipeline.onActivity = { kind in self?.onMain { $0.onActivity?(kind) } }
            pipeline.onThumbnail = { image in self?.onMain { $0.onThumbnail?(image) } }
        }
    }

    /// Runs `body` on the I/O queue, which owns the pipeline.
    private func onPipeline(_ body: @escaping @Sendable (MediaPipeline) -> Void) {
        let pipeline = pipeline
        ioQueue.async { body(pipeline) }
    }

    /// Hops back to the main thread from the I/O queue.
    private nonisolated func onMain(_ body: @escaping @MainActor (CameraStream) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { body(self) }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        retryDelay = 1
        connect()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        retryWork?.cancel()
        client?.stop()
        client = nil
        onPipeline { $0.stop() }
        soundLevel = nil
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        status = .idle
    }

    /// Reconnects, picking up a new bridge URL if the bridge restarted.
    func restart() {
        guard running else { return }
        retryDelay = 1
        connect()
    }

    private func connect() {
        guard running else { return }
        retryWork?.cancel()
        client?.stop()
        client = nil
        guard let url = urlProvider() else {
            status = .waitingForBridge
            scheduleRetry()
            return
        }
        status = .connecting
        connectStarted = Date()
        onPipeline { $0.reset() }
        soundLevel = nil

        let c = RTSPClient(url: url, queue: ioQueue)
        let pipeline = pipeline
        c.onPacket = { media, data in pipeline.push(media, data) }
        c.onClose = { [weak self] error in
            DispatchQueue.main.async { self?.connectionClosed(error) }
        }
        client = c
        c.start()
    }

    private func connectionClosed(_ error: Error?) {
        guard running else { return }
        client = nil
        status = .failed(error?.localizedDescription ?? "Flux interrompu")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running else { return }
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 15)
    }

    private func didReceiveFirstFrame() {
        guard running else { return }
        status = .live
        retryDelay = 1
        startPiPIfWanted()
    }

    /// Reconnects a stream that stopped delivering frames.
    private func checkHealth() {
        guard running else { return }
        switch status {
        case .live where pipeline.secondsSinceLastFrame > 10:
            status = .failed("Image figée, reconnexion…")
            connect()
        case .connecting where Date().timeIntervalSince(connectStarted) > 60:
            status = .failed("La caméra ne répond pas")
            connect()
        default:
            break
        }
    }

    // MARK: Window

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.title = name
        window.isMovableByWindowBackground = true
        applyAspectRatio()
        applyPin()
        setUpPiP()
    }

    /// Locks live resizing to the video's proportions and snaps the current frame to them,
    /// so the window never shows black bars around the picture.
    private func applyAspectRatio() {
        guard let window, videoSize.width > 0, videoSize.height > 0 else { return }
        // SwiftUI windows extend their content under the title bar, which would make the
        // ratio apply to video + title bar; keep the content below it so it's the video alone.
        if window.styleMask.contains(.fullSizeContentView), !window.styleMask.contains(.fullScreen) {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.contentAspectRatio = videoSize
        guard !window.styleMask.contains(.fullScreen) else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let height = (content.width * videoSize.height / videoSize.width).rounded()
        guard abs(height - content.height) >= 1 else { return }
        var target = content
        target.size.height = height
        target.origin.y = content.maxY - height // keep the title bar in place
        window.setFrame(window.frameRect(forContentRect: target), display: true, animate: false)
    }

    private func applyPin() {
        guard let window else { return }
        window.level = pinned ? .floating : .normal
        if pinned {
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
    }

    // MARK: Picture in Picture

    func requestPiP() {
        if pipActive { return }
        wantsPiP = true
        startPiPIfWanted()
    }

    func togglePiP() {
        if pipActive {
            pip?.stopPictureInPicture()
        } else {
            requestPiP()
        }
    }

    private func setUpPiP() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            DispatchQueue.main.async {
                self?.pipPossible = possible
                self?.startPiPIfWanted()
            }
        }
        pip = controller
    }

    /// macOS PiP bug: AVKit mirrors our display layer through a CALayerHost,
    /// scales it with its own transform, but sizes its content view only once,
    /// for the starting PiP size. Keep our layer at the PiP window's size (so
    /// AVKit's scale lines up) and make AVKit's views follow the window.
    /// AVKit's internal layers are left alone: touching them crops the picture.
    private func fitLayerToPiP() {
        guard pipActive,
              let panel = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("PIP") }),
              let content = panel.contentView
        else { return }
        observePiPResizes(of: panel)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = content.bounds
        CATransaction.commit()
        trackWindowSize(in: content)
    }

    private func trackWindowSize(in content: NSView) {
        for view in content.subviews where String(describing: type(of: view)).hasPrefix("AVPictureInPicture") {
            view.autoresizingMask = [.width, .height]
            if view.frame != content.bounds { view.frame = content.bounds }
            view.needsLayout = true
        }
        keepParkedHostViewsOffscreen(in: content, root: content)
    }

    /// AVKit parks an opaque black host view just above the PiP content and
    /// re-parks it during its own layout, so as the window grows it slides
    /// into view as a black band at the top. Push it back above the top edge
    /// whenever AVKit moves it. A host view at origin zero is AVKit's real
    /// one and is left alone.
    private func keepParkedHostViewsOffscreen(in view: NSView, root: NSView) {
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "AVPictureInPictureCALayerHostView" {
                Self.unpark(sub, root: root)
                watchHostView(sub, root: root)
            }
            keepParkedHostViewsOffscreen(in: sub, root: root)
        }
    }

    private static func unpark(_ host: NSView, root: NSView) {
        let offscreen = root.bounds.height + 10
        guard host.frame.minY > 0, host.frame.minY != offscreen else { return }
        host.setFrameOrigin(NSPoint(x: host.frame.minX, y: offscreen))
    }

    private var watchedHostViews: [ObjectIdentifier: NSObjectProtocol] = [:]

    private func watchHostView(_ host: NSView, root: NSView) {
        let id = ObjectIdentifier(host)
        guard watchedHostViews[id] == nil else { return }
        host.postsFrameChangedNotifications = true
        watchedHostViews[id] = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: host, queue: .main
        ) { [weak host, weak root] _ in
            MainActor.assumeIsolated {
                guard let host, let root else { return }
                Self.unpark(host, root: root)
            }
        }
    }

    private var pipResizeObservers: [NSObjectProtocol] = []
    private weak var observedPiPWindow: NSWindow?

    private func observePiPResizes(of pipWindow: NSWindow?) {
        guard let pipWindow, pipWindow !== observedPiPWindow else { return }
        stopObservingPiPResizes()
        observedPiPWindow = pipWindow
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            pipResizeObservers.append(center.addObserver(forName: name, object: pipWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitLayerToPiP() }
            })
        }
    }

    private func stopObservingPiPResizes() {
        pipResizeObservers.forEach(NotificationCenter.default.removeObserver)
        pipResizeObservers.removeAll()
        watchedHostViews.values.forEach(NotificationCenter.default.removeObserver)
        watchedHostViews.removeAll()
        observedPiPWindow = nil
    }

    private func startPiPIfWanted() {
        guard wantsPiP, status == .live, let pip, pip.isPictureInPicturePossible, !pip.isPictureInPictureActive else { return }
        wantsPiP = false
        pip.startPictureInPicture()
    }
}

// MARK: - PiP delegates

extension CameraStream: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipActive = true
            self.window?.orderOut(nil)
            self.fitLayerToPiP()
            for delay in [0.1, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.fitLayerToPiP() }
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.pipActive = false
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.restoringFromPiP = true
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipActive = false
            self.stopObservingPiPResizes()
            if self.restoringFromPiP {
                self.restoringFromPiP = false
            } else {
                self.onPiPDismissed?()
            }
        }
    }

    // Live stream: no seeking, never paused.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Task { @MainActor in self.fitLayerToPiP() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
