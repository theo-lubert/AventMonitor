import SwiftUI

struct CameraWindowView: View {
    @EnvironmentObject private var model: AppModel
    let cameraID: String

    var body: some View {
        CameraPlayerView(stream: model.stream(for: cameraID), room: model.room(for: cameraID))
    }
}

private struct CameraPlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var stream: CameraStream
    @ObservedObject var room: RoomControls
    @State private var hovering = false
    @State private var window: NSWindow?
    @State private var popover: Popover?

    private enum Popover { case light, lullaby }

    /// The bar stays up while one of its popovers is open, or they would lose their anchor.
    private var showsControls: Bool { hovering || stream.status != .live || popover != nil }

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(layer: stream.layer, pipActive: stream.pipActive)
            if stream.status != .live {
                StatusBadge(status: stream.status)
            }
            if stream.status == .live, let level = stream.soundLevel {
                HStack {
                    SoundLevelBars(level: level)
                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.vertical, 44) // clear of the activity pills and the controls
            }
            VStack {
                HStack(alignment: .top) {
                    ActivityPills(activity: model.activity, cameraID: stream.cameraID)
                    Spacer()
                    RoomStatusPills(room: room)
                }
                Spacer()
            }
            .padding(12)
            VStack(spacing: 10) {
                Spacer()
                if stream.talk != .off {
                    TalkOverlay(stream: stream, window: window)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if showsControls {
                    controls
                        .transition(.opacity)
                }
            }
            .padding(12)
            .animation(.easeInOut(duration: 0.15), value: stream.talk)
        }
        .frame(minWidth: 320, minHeight: 180)
        .aspectRatio(stream.videoSize.width / max(stream.videoSize.height, 1), contentMode: .fit)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .background(WindowAccessor { w in
            stream.attach(window: w)
            if window !== w { DispatchQueue.main.async { window = w } }
        })
        .onAppear {
            model.openStream(stream.cameraID)
            room.watch()
        }
        .onDisappear {
            room.unwatch()
            model.closeStream(stream.cameraID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCameraWindow)) { note in
            if note.object as? String == stream.cameraID { close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCameraWindows)) { _ in close() }
        .navigationTitle(stream.name)
    }

    private func close() {
        stream.stop()
        if let window { window.close() } else { dismissWindow(id: "camera", value: stream.cameraID) }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(stream.status == .live ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(stream.status == .live ? "EN DIRECT" : stream.status.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if stream.status == .live {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = Int(stream.secondsSinceLastFrame)
                    if seconds >= 5 {
                        Text("\(seconds) s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .help("Secondes depuis la dernière image reçue")
                    }
                }
            }
            Spacer(minLength: 8)
            ControlButton(systemImage: room.state?.nightLight == true ? "lightbulb.fill" : "lightbulb",
                          help: "Veilleuse", active: room.state?.nightLight == true) { popover = .light }
                .popover(isPresented: popoverBinding(.light), arrowEdge: .top) { NightLightControls(room: room) }
            ControlButton(systemImage: "music.note", help: "Berceuses et sons",
                          active: room.state?.lullabyPlaying == true) { popover = .lullaby }
                .popover(isPresented: popoverBinding(.lullaby), arrowEdge: .top) { LullabyControls(room: room) }
            ControlButton(systemImage: stream.talk.isActive ? "mic.fill" : "mic",
                          help: stream.talk.isActive ? "Arrêter de parler" : "Parler dans la chambre (met une berceuse en pause)",
                          active: stream.talk.isActive) {
                stream.talk.isActive ? stream.endTalk() : stream.beginTalk()
            }
            Divider().frame(height: 16).overlay(Color.white.opacity(0.25))
            ControlButton(systemImage: stream.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          help: stream.muted ? "Activer le son" : "Couper le son") { stream.muted.toggle() }
            ControlButton(systemImage: stream.pinned ? "pin.fill" : "pin",
                          help: stream.pinned ? "Ne plus garder au premier plan" : "Garder au premier plan, sur tous les bureaux") {
                stream.pinned.toggle()
            }
            ControlButton(systemImage: "pip.enter", help: "Picture in Picture") { stream.togglePiP() }
                .disabled(stream.status != .live || !stream.pipPossible)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 560)
    }

    private func popoverBinding(_ which: Popover) -> Binding<Bool> {
        Binding(get: { popover == which }, set: { if !$0, popover == which { popover = nil } })
    }
}

private struct ControlButton: View {
    let systemImage: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color(red: 1, green: 0.84, blue: 0.47) : .white)
                .frame(width: 24, height: 22)
                .background(active ? Color(red: 1, green: 0.84, blue: 0.47).opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Son détecté" / "Mouvement détecté", for a minute after the last detection on this camera.
private struct ActivityPills: View {
    @ObservedObject var activity: ActivityCenter
    let cameraID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ActivityCenter.Kind.allCases, id: \.self) { kind in
                    if let seen = activity.lastSeen(kind, camera: cameraID) {
                        pill(kind, ago: context.date.timeIntervalSince(seen))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity.activeKinds(camera: cameraID))
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ kind: ActivityCenter.Kind, ago: TimeInterval) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(nsColor: kind.color)).frame(width: 8, height: 8)
            Text(kind.label).font(.caption.weight(.semibold))
            Text(ago < 2 ? "maintenant" : "il y a \(Int(ago)) s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
    }
}

/// Three stacked bars, level 1 at the bottom and 3 at the top, as in the official app.
private struct SoundLevelBars: View {
    let level: Int

    var body: some View {
        VStack(spacing: 5) {
            ForEach((1...3).reversed(), id: \.self) { bar in
                let lit = bar <= level
                Capsule()
                    .fill(lit ? Color.white : Color.white.opacity(0.22))
                    .frame(width: 8)
                    .frame(minHeight: 16, maxHeight: 60)
                    .shadow(color: .white.opacity(lit ? 0.55 : 0), radius: 4)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityElement()
        .accessibilityLabel("Niveau sonore")
        .accessibilityValue("\(level) sur 3")
        .help("Niveau sonore dans la pièce")
    }
}

private struct StatusBadge: View {
    let status: CameraStream.Status

    var body: some View {
        VStack(spacing: 10) {
            if case .failed = status {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            Text(status.label).font(.callout)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(20)
    }
}
