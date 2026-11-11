import AppKit
import SwiftUI

/// Sound and movement seen on each camera, kept for a minute after the last detection.
/// Feeds the badges on the video, the Dock icon and the menu bar icon.
@MainActor
final class ActivityCenter: ObservableObject {
    enum Kind: CaseIterable {
        case sound, motion

        var color: NSColor {
            switch self {
            case .sound: return .systemOrange
            case .motion: return .systemBlue
            }
        }

        var label: String {
            switch self {
            case .sound: return "Son détecté"
            case .motion: return "Mouvement détecté"
            }
        }

        var systemImage: String {
            switch self {
            case .sound: return "waveform"
            case .motion: return "figure.walk.motion"
            }
        }
    }

    static let holdDuration: TimeInterval = 60

    /// Last detection per camera and kind, for the ones still active.
    @Published private(set) var last: [String: [Kind: Date]] = [:]
    private var expiry: Timer?

    func report(_ kind: Kind, camera: String) {
        last[camera, default: [:]][kind] = Date()
        scheduleExpiry()
    }

    func clearAll() {
        last = [:]
        scheduleExpiry()
    }

    func lastSeen(_ kind: Kind, camera: String) -> Date? { last[camera]?[kind] }

    func activeKinds(camera: String) -> [Kind] { Kind.allCases.filter { last[camera]?[$0] != nil } }

    /// Kinds active on any camera, in a stable order.
    var activeKinds: [Kind] { Self.kinds(in: last) }

    nonisolated static func kinds(in last: [String: [Kind: Date]]) -> [Kind] {
        Kind.allCases.filter { kind in last.values.contains { $0[kind] != nil } }
    }

    /// Drops detections older than the hold duration, then waits for the next one to expire.
    private func scheduleExpiry() {
        expiry?.invalidate()
        let cutoff = Date().addingTimeInterval(-Self.holdDuration)
        var pruned = last
        for (camera, kinds) in pruned {
            let kept = kinds.filter { $0.value > cutoff }
            pruned[camera] = kept.isEmpty ? nil : kept
        }
        if pruned != last { last = pruned }
        guard let oldest = pruned.values.flatMap(\.values).min() else { return }
        let fireAt = oldest.addingTimeInterval(Self.holdDuration + 0.05)
        expiry = Timer.scheduledTimer(withTimeInterval: max(fireAt.timeIntervalSinceNow, 0.05), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scheduleExpiry() }
        }
    }
}

// MARK: - Icons with badges

enum ActivityBadge {
    /// Draws one dot per kind, stacked vertically from the top right of `rect`.
    static func drawDots(_ kinds: [ActivityCenter.Kind], in rect: NSRect, diameter: CGFloat, ring: NSColor?) {
        let gap = diameter * 0.25
        var y = rect.maxY - diameter
        for kind in kinds {
            let dot = NSRect(x: rect.maxX - diameter, y: y, width: diameter, height: diameter)
            if let ring {
                ring.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -diameter * 0.12, dy: -diameter * 0.12)).fill()
            }
            kind.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            y -= diameter + gap
        }
    }

    /// The menu bar icon, plus coloured dots when something was detected.
    /// Coloured dots need a non-template image, so the icon itself is drawn in the menu bar's text colour.
    static func menuBarImage(_ kinds: [ActivityCenter.Kind]) -> NSImage {
        guard let base = NSImage(named: "MenuBarIcon") else { return NSImage() }
        guard !kinds.isEmpty else { return base }
        let dot: CGFloat = 6
        let gap = dot * 0.25
        let extra = dot + 1.5
        let stack = CGFloat(kinds.count) * dot + CGFloat(kinds.count - 1) * gap
        let size = NSSize(width: base.size.width + extra, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            let iconRect = NSRect(origin: .zero, size: base.size)
            base.draw(in: iconRect)
            NSColor.labelColor.set()
            iconRect.fill(using: .sourceAtop)
            // Centred vertically next to the icon.
            drawDots(kinds, in: NSRect(x: base.size.width, y: (rect.height - stack) / 2, width: extra, height: stack),
                     diameter: dot, ring: nil)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Updates the Dock icon: the app icon, with dots at the top right when something was detected.
    static func updateDock(_ kinds: [ActivityCenter.Kind]) {
        let tile = NSApp.dockTile
        if kinds.isEmpty {
            tile.contentView = nil
        } else {
            let icon = NSApp.applicationIconImage ?? NSImage()
            let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                icon.draw(in: rect)
                drawDots(kinds, in: rect.insetBy(dx: 8, dy: 8), diameter: 34, ring: .white)
                return true
            }
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        }
        tile.display()
    }
}
