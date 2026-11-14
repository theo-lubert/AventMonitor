import AppKit
import AVFoundation
import SwiftUI

/// Hosts the stream's AVSampleBufferDisplayLayer (needed for system PiP).
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// While PiP runs, AVKit owns the layer (it reparents it into the PiP window).
    var pipActive = false

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hosted = layer
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        if view.hosted !== layer { view.hosted = layer }
        let wasInPiP = view.pipActive
        view.pipActive = pipActive
        if wasInPiP && !pipActive { view.reclaim() }
        if wasInPiP != pipActive { view.needsLayout = true }
    }

    final class LayerHostView: NSView {
        /// While PiP runs, CameraStream sizes the layer to the PiP window.
        var pipActive = false
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer?.addSublayer(hosted) }
                observeHosted()
                applyScale()
                needsLayout = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Takes the layer back once PiP has handed it over.
        func reclaim() {
            guard let hosted, let layer, hosted.superlayer !== layer else { return }
            hosted.removeFromSuperlayer()
            layer.addSublayer(hosted)
            needsLayout = true
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            applyScale()
        }

        /// Layers we create ourselves default to 1x; PiP needs the real
        /// backing scale or it mis-sizes the video it lifts out of the layer.
        private func applyScale() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            layer?.contentsScale = scale
            hosted?.contentsScale = scale
        }

        override func layout() {
            super.layout()
            guard let hosted, let layer, hosted.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if pipActive {
                // Never resize the display layer while PiP runs: it is kept at the
                // PiP window's size. AVKit's "playing in picture in picture"
                // placeholder is a sublayer of it, so it would sit at that size in
                // the window's corner; stretch it over the whole view instead.
                let target = hosted.convert(bounds, from: layer)
                for sub in hosted.sublayers ?? [] where Self.isPiPIndicator(sub) && sub.frame != target {
                    sub.frame = target
                }
            } else {
                hosted.frame = bounds
            }
        }

        private static func isPiPIndicator(_ layer: CALayer) -> Bool {
            String(describing: type(of: layer)).contains("PictureInPictureIndicator")
        }

        /// The display layer is resized to the PiP window and gets the placeholder
        /// added while PiP runs; both need the placeholder fitted again.
        private var hostedObservations: [NSKeyValueObservation] = []

        private func observeHosted() {
            hostedObservations = []
            guard let hosted else { return }
            hostedObservations = [
                hosted.observe(\.bounds) { [weak self] _, _ in self?.relayoutOnMain() },
                hosted.observe(\.sublayers) { [weak self] _, _ in self?.relayoutOnMain() },
            ]
        }

        private func relayoutOnMain() {
            DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
        }

        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Hands the hosting NSWindow to SwiftUI code.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class ObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Reports whether the hosting window is actually on screen: ordered in, not
/// minimized and not fully covered. The menu bar panel is ordered out when it closes.
/// Calls are balanced: every `true` is followed by a `false`, at the latest on removal.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.detach()
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var visible = false
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                }
            }
            update()
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            set(false)
        }

        private func update() {
            guard let window else { return set(false) }
            set(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func set(_ newValue: Bool) {
            guard newValue != visible else { return }
            visible = newValue
            onChange?(newValue)
        }
    }
}
