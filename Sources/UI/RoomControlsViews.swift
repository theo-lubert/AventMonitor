import SwiftUI

// Night light, lullabies and talkback. The popovers open from the camera window's
// control bar; the quick actions sit under each camera in the menu bar panel.

/// Warm night-light yellow; a darker amber on light backgrounds, where pale yellow would not read.
private let lightColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(red: 1, green: 0.84, blue: 0.47, alpha: 1)
        : NSColor(red: 0.72, green: 0.45, blue: 0, alpha: 1)
})

enum RoomControlsViews {
    /// Remaining seconds of a timer the camera reported at `readAt`, counted down since.
    static func remaining(_ seconds: Int?, since readAt: Date, now: Date) -> Int? {
        guard let seconds else { return nil }
        let left = seconds - Int(now.timeIntervalSince(readAt))
        return left > 0 ? left : nil
    }
}

// MARK: - Night light

struct NightLightControls: View {
    @ObservedObject var room: RoomControls
    @State private var brightness: Double = 30
    @State private var editing = false

    var body: some View {
        let state = room.state
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { state?.nightLight ?? false }, set: { room.setNightLight($0) })) {
                Label("Veilleuse", systemImage: state?.nightLight == true ? "lightbulb.fill" : "lightbulb")
                    .font(.headline)
            }
            .toggleStyle(.switch)
            .disabled(state?.nightLight == nil)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Luminosité")
                    Spacer()
                    Text("\(Int(brightness)) %").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                Slider(value: $brightness, in: 1...100) { isEditing in
                    editing = isEditing
                    if !isEditing { room.setBrightness(Int(brightness)) }
                }
                .accessibilityLabel("Luminosité de la veilleuse")
            }
            .disabled(state?.brightness == nil)

            TimerChoices(title: "Éteindre après", current: state?.lightTimer,
                         remaining: state?.lightRemaining, readAt: room.readAt) { room.setLightTimer($0) }
                .disabled(state?.nightLight != true)

            RoomError(room: room)
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { if let b = state?.brightness { brightness = Double(b) } }
        .onChange(of: state?.brightness) { _, new in
            if !editing, let new { brightness = Double(new) }
        }
    }
}

// MARK: - Lullabies

struct LullabyControls: View {
    @ObservedObject var room: RoomControls
    @State private var volume: Double = 50
    @State private var editing = false

    var body: some View {
        let state = room.state
        let playing = state?.lullabyPlaying == true
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(playing ? lightColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state?.currentTrack?.name ?? "Berceuses")
                        .font(.headline)
                        .lineLimit(1)
                    Text(playing ? "En lecture" : "En pause")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 22) {
                Spacer()
                Button { room.previous() } label: { Image(systemName: "backward.fill") }
                    .help("Morceau précédent")
                Button { room.playPause() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                        .background(.primary.opacity(0.1), in: Circle())
                }
                .help(playing ? "Pause" : "Lecture")
                Button { room.next() } label: { Image(systemName: "forward.fill") }
                    .help("Morceau suivant")
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.title3)
            .disabled(state?.lullabyPlaying == nil)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 1...100) { isEditing in
                    editing = isEditing
                    if !isEditing { room.setVolume(Int(volume)) }
                }
                .accessibilityLabel("Volume de la berceuse")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .disabled(state?.volume == nil)

            Picker("Lecture", selection: Binding(get: { state?.playMode ?? .loop }, set: { room.setPlayMode($0) })) {
                ForEach(PlayMode.allCases) { mode in
                    Image(systemName: mode.systemImage).help(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state?.playMode == nil)

            TimerChoices(title: "Arrêter après", current: state?.lullabyTimer,
                         remaining: state?.lullabyRemaining, readAt: room.readAt) { room.setLullabyTimer($0) }
                .disabled(state == nil)

            Divider()
            TrackList(room: room)
            RoomError(room: room)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { if let v = state?.volume { volume = Double(v) } }
        .onChange(of: state?.volume) { _, new in
            if !editing, let new { volume = Double(new) }
        }
    }
}

private struct TrackList: View {
    @ObservedObject var room: RoomControls

    var body: some View {
        let current = room.state?.currentTrack
        let playing = room.state?.lullabyPlaying == true
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Lullaby.Category.allCases, id: \.self) { category in
                    Text(category.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, category == .lullabies ? 0 : 8)
                        .padding(.bottom, 2)
                    ForEach(Lullaby.catalogue.filter { $0.category == category }) { track in
                        let isCurrent = track == current
                        Button { room.play(track) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent && playing ? "speaker.wave.2.fill" : "play.fill")
                                    .font(.caption2)
                                    .frame(width: 14)
                                    .opacity(isCurrent ? 1 : 0.35)
                                Text(track.name)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(isCurrent ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isCurrent ? lightColor : .primary)
                    }
                }
            }
        }
        .frame(height: 190)
        .disabled(room.state == nil)
    }
}

// MARK: - Shared pieces

/// "Jamais · 15 min · 30 min · 1 h · 1 h 30", with the time left on the running timer.
private struct TimerChoices: View {
    let title: String
    let current: Int?
    let remaining: Int?
    let readAt: Date
    let set: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if current != nil, let left = RoomControlsViews.remaining(remaining, since: readAt, now: context.date) {
                        Text("encore \(RoomTimer.remaining(left))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            HStack(spacing: 5) {
                chip("Jamais", selected: current == nil) { set(nil) }
                ForEach(RoomTimer.choices, id: \.self) { seconds in
                    chip(RoomTimer.label(seconds), selected: current == seconds) { set(seconds) }
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.09), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct RoomError: View {
    @ObservedObject var room: RoomControls

    var body: some View {
        if let error = room.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if room.state == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Lecture de l'état de la caméra…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Camera window

/// Top right of the video: temperature, and whether the light or a lullaby is on,
/// so it shows without hovering.
struct RoomStatusPills: View {
    @ObservedObject var room: RoomControls

    var body: some View {
        let state = room.state
        HStack(spacing: 6) {
            if state?.nightLight == true {
                pill { Image(systemName: "lightbulb.fill").foregroundStyle(lightColor) }
                    .help("Veilleuse allumée")
            }
            if state?.lullabyPlaying == true {
                pill {
                    Image(systemName: "music.note").foregroundStyle(lightColor)
                    if let track = state?.currentTrack { Text(track.name).lineLimit(1) }
                }
                .help("Berceuse en cours")
            }
            if let t = state?.temperature {
                pill { Text(t.formatted(.number.precision(.fractionLength(1))) + " °C").monospacedDigit() }
                    .help("Température de la chambre")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5, content: content)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
    }
}

/// Above the control bar while talk mode is on: hold to talk, or hold the space bar.
struct TalkOverlay: View {
    @ObservedObject var stream: CameraStream
    let window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var pressing = false

    var body: some View {
        HStack(spacing: 14) {
            switch stream.talk {
            case .preparing:
                ProgressView().controlSize(.small).tint(.white)
                Text("Ouverture du micro de la caméra…")
            case .ready, .talking:
                talkButton
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.talk == .talking ? "On vous entend dans la chambre" : "Maintenez pour parler")
                        .font(.callout.weight(.semibold))
                    Text(stream.talk == .talking ? "Le son de la caméra est coupé" : "ou maintenez la barre d'espace")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            case .failed(let message):
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            case .off:
                EmptyView()
            }
            Spacer(minLength: 4)
            Button { stream.endTalk() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .help(stream.talk.isActive ? "Terminer" : "Fermer")
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 420)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private var talkButton: some View {
        let talking = stream.talk == .talking
        return Image(systemName: talking ? "mic.fill" : "mic")
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 48, height: 48)
            .background(talking ? Color.red : Color.white.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(Color.red.opacity(talking ? 0.35 : 0), lineWidth: 6).scaleEffect(1.18))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    stream.startTalking()
                }
                .onEnded { _ in
                    pressing = false
                    stream.stopTalking()
                })
            .accessibilityLabel("Parler")
            .accessibilityAddTraits(.isButton)
            .animation(.easeOut(duration: 0.12), value: talking)
    }

    /// Space bar held in this window talks, like a walkie-talkie.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak stream] event in
            guard let stream, event.keyCode == 49, event.window === window, event.window != nil else { return event }
            if event.type == .keyDown {
                if !event.isARepeat { stream.startTalking() }
            } else {
                stream.stopTalking()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Menu bar panel

/// Under a camera's thumbnail: night light, lullaby and talk, without opening the stream.
struct RoomQuickActions: View {
    @ObservedObject var room: RoomControls
    let talk: () -> Void

    var body: some View {
        let state = room.state
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                QuickButton(title: "Veilleuse", systemImage: state?.nightLight == true ? "lightbulb.fill" : "lightbulb",
                            on: state?.nightLight == true, enabled: state?.nightLight != nil,
                            help: state?.nightLight == true ? "Éteindre la veilleuse" : "Allumer la veilleuse") {
                    room.setNightLight(!(state?.nightLight ?? false))
                } menu: {
                    Section("Luminosité") {
                        ForEach([10, 25, 50, 75, 100], id: \.self) { p in
                            Button(state?.brightness == p ? "✓ \(p) %" : "\(p) %") { room.setBrightness(p) }
                        }
                    }
                    Section("Éteindre après") { timerItems(current: state?.lightTimer) { room.setLightTimer($0) } }
                }
                QuickButton(title: "Berceuse", systemImage: state?.lullabyPlaying == true ? "pause.fill" : "music.note",
                            on: state?.lullabyPlaying == true, enabled: state?.lullabyPlaying != nil,
                            help: state?.lullabyPlaying == true ? "Mettre la berceuse en pause" : "Lancer la berceuse") {
                    room.playPause()
                } menu: {
                    ForEach(Lullaby.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(Lullaby.catalogue.filter { $0.category == category }) { track in
                                Button(track == state?.currentTrack ? "✓ \(track.name)" : track.name) { room.play(track) }
                            }
                        }
                    }
                    Section("Volume") {
                        ForEach([20, 40, 60, 80, 100], id: \.self) { v in
                            Button(state?.volume == v ? "✓ \(v) %" : "\(v) %") { room.setVolume(v) }
                        }
                    }
                    Section("Arrêter après") { timerItems(current: state?.lullabyTimer) { room.setLullabyTimer($0) } }
                }
                QuickButton(title: "Parler", systemImage: "mic", on: false, enabled: true,
                            help: "Ouvrir la caméra et parler dans la chambre", action: talk, menu: { EmptyView() })
            }
            if state?.lullabyPlaying == true {
                MiniPlayer(room: room)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = room.error {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state?.lullabyPlaying)
    }

    @ViewBuilder
    private func timerItems(current: Int?, set: @escaping (Int?) -> Void) -> some View {
        Button(current == nil ? "✓ Jamais" : "Jamais") { set(nil) }
        ForEach(RoomTimer.choices, id: \.self) { s in
            Button(current == s ? "✓ \(RoomTimer.label(s))" : RoomTimer.label(s)) { set(s) }
        }
    }
}

private struct QuickButton<MenuContent: View>: View {
    let title: String
    let systemImage: String
    let on: Bool
    let enabled: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 15)).frame(height: 18)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(on ? lightColor : .primary)
            .background(on ? lightColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if MenuContent.self != EmptyView.self {
                Menu(content: menu) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(2)
                .disabled(!enabled)
                .help("Réglages")
            }
        }
    }
}

private struct MiniPlayer: View {
    @ObservedObject var room: RoomControls

    var body: some View {
        let state = room.state
        HStack(spacing: 8) {
            Button { room.pause() } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.12), in: Circle())
            }
            .help("Pause")
            VStack(alignment: .leading, spacing: 0) {
                Text(state?.currentTrack?.name ?? "Berceuse").font(.caption.weight(.medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let left = RoomControlsViews.remaining(state?.lullabyRemaining, since: room.readAt, now: context.date) {
                        Text("Arrêt dans \(RoomTimer.remaining(left))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { room.next() } label: { Image(systemName: "forward.fill").font(.caption) }
                .help("Morceau suivant")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
