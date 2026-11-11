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
        if wasInPiP && !pipActive {
            view.reclaim()
            view.needsLayout = true
        }
    }

    final class LayerHostView: NSView {
        /// While PiP runs, CameraStream sizes the layer to the PiP window.
        var pipActive = false
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer?.addSublayer(hosted) }
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
            // Never resize the layer while it lives in the PiP window: our bounds
            // would offset and crop the picture there.
            guard !pipActive, let hosted, hosted.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
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
