import AppKit
import AVFoundation
import SwiftUI

/// Hosts the stream's display layers: the window's video on top, and under it the
/// layer system PiP takes into its own window.
struct VideoLayerView: NSViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer
    /// Nil for a plain video view, such as the menu's live tile.
    var pipLayer: AVSampleBufferDisplayLayer?
    /// While PiP runs, AVKit owns the PiP layer (it reparents it into the PiP window).
    var pipActive = false

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.set(video: videoLayer, pip: pipLayer)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.set(video: videoLayer, pip: pipLayer)
        let wasInPiP = view.pipActive
        view.pipActive = pipActive
        if wasInPiP && !pipActive { view.reclaim() }
        if wasInPiP != pipActive { view.needsLayout = true }
    }

    final class LayerHostView: NSView {
        /// While PiP runs, CameraStream sizes the PiP layer to the PiP window.
        var pipActive = false
        private var video: CALayer?
        private var pip: CALayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let root = CALayer()
            root.backgroundColor = NSColor.black.cgColor
            layer = root
            rootObservation = root.observe(\.sublayers) { [weak self] _, _ in self?.relayoutOnMain() }
        }

        required init?(coder: NSCoder) { fatalError() }

        private var rootObservation: NSKeyValueObservation?

        func set(video: CALayer, pip: CALayer?) {
            guard let root = layer else { return }
            if self.video !== video {
                self.video?.removeFromSuperlayer()
                self.video = video
                root.addSublayer(video)
            }
            if self.pip !== pip {
                // AVKit may still hold the old one; leave it to CameraStream.
                if self.pip?.superlayer === root { self.pip?.removeFromSuperlayer() }
                self.pip = pip
                if let pip { root.insertSublayer(pip, at: 0) }
            }
            applyScale()
            needsLayout = true
        }

        /// Takes the PiP layer back, under the video, once PiP has handed it over.
        func reclaim() {
            guard let pip, let root = layer, pip.superlayer !== root else { return }
            pip.removeFromSuperlayer()
            root.insertSublayer(pip, at: 0)
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
            video?.contentsScale = scale
            pip?.contentsScale = scale
        }

        override func layout() {
            super.layout()
            guard let root = layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if let video, video.superlayer === root { video.frame = bounds }
            // While PiP runs the PiP layer keeps the PiP window's size.
            if !pipActive, let pip, pip.superlayer === root { pip.frame = bounds }
            // A PiP layer from an earlier session that AVKit put back would sit over the video.
            for sub in root.sublayers ?? [] where sub !== video && sub !== pip && sub is AVSampleBufferDisplayLayer {
                sub.removeFromSuperlayer()
            }
            // Keep the video on top, whatever order AVKit hands layers back in.
            if let video, root.sublayers?.last !== video, video.superlayer === root {
                root.addSublayer(video)
            }
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
