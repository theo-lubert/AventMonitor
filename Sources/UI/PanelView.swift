import SwiftUI

/// Content shared by the menu bar panel and the main window.
struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var showsQuit = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Footer(showsQuit: showsQuit)
            Divider().padding(.horizontal, 2)
            if let failure = model.coreFailure {
                Label(failure, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 6)
            }
            switch model.phase {
            case .starting:
                HStack { ProgressView().controlSize(.small); Text("Démarrage…") }
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .loggedOut:
                LoginView().padding(.horizontal, 6).padding(.top, 2)
            case .loggedIn:
                CameraList(open: open)
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(shortcuts)
    }

    /// Menu items only fire while the menu is open; keep ⌘R / ⌘Q live on the panel.
    private var shortcuts: some View {
        ZStack {
            if model.phase == .loggedIn {
                Button("") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
            if showsQuit {
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func open(_ cameraID: String, pip: Bool) {
        let stream = model.stream(for: cameraID)
        if pip { stream.requestPiP() }
        openWindow(id: "camera", value: cameraID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Top bar: account on the left, settings ⚙︎ and quit ⏻ on the right.
private struct Footer: View {
    @EnvironmentObject private var model: AppModel
    let showsQuit: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let s = model.session {
                let display = s.nickname.isEmpty ? s.email : s.nickname
                Text(String(display.prefix(1)).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.gradient))
                    .help(s.email)
            }
            Spacer(minLength: 4)
            if model.isBusy { ProgressView().controlSize(.mini) }
            SettingsMenu()
            if showsQuit {
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").footerIcon()
                }
                .buttonStyle(.plain)
                .help("Quitter (⌘Q)")
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject private var model: AppModel
    /// Build info is shown only while ⌥ is held, like macOS hidden menu items.
    @State private var optionDown = NSEvent.modifierFlags.contains(.option)
    @State private var flagsMonitor: Any?

    var body: some View {
        Menu {
            if model.session != nil {
                Button("Actualiser les caméras") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Divider()
            }
            Toggle("Icône dans le Dock", isOn: $model.showDockIcon)
            Toggle("Icône dans la barre des menus", isOn: $model.showMenuBarIcon)
            Toggle("Ouvrir au démarrage du Mac", isOn: $model.launchAtLogin)
            if let s = model.session {
                Divider()
                Text(s.email)
                Button("Se déconnecter", role: .destructive) { model.logout() }
            }
            if optionDown {
                Divider()
                Text("Build du \(BuildInfo.date)")
            }
        } label: {
            Image(systemName: "gearshape").footerIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Réglages")
        .onAppear {
            optionDown = NSEvent.modifierFlags.contains(.option)
            guard flagsMonitor == nil else { return }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionDown = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }
}

private extension Image {
    func footerIcon() -> some View {
        font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

private struct CameraList: View {
    @EnvironmentObject private var model: AppModel
    let open: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.cameras.isEmpty {
                Text(model.isBusy ? "Recherche des caméras…" : "Aucune caméra sur ce compte.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(6)
            }
            ForEach(model.cameras) { cam in
                CameraTile(camera: cam, thumbnails: model.thumbnails, open: open)
            }
            .disabled(model.bridge == nil)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 6)
            } else if model.bridge == nil, !model.cameras.isEmpty, !model.isBusy {
                Text("Pont local indisponible.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Last still of the camera: click opens the window, the corner button starts PiP.
private struct CameraTile: View {
    let camera: Camera
    @ObservedObject var thumbnails: ThumbnailStore
    let open: (String, Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    /// Panel width (300) minus its padding, in 16:9. The menu bar panel sizes
    /// itself to its content, so a flexible tile would collapse.
    static let size = CGSize(width: 280, height: 158)

    private var thumbnail: ThumbnailStore.Thumbnail? { thumbnails.thumbnails[camera.id] }

    var body: some View {
        Button { open(camera.id, false) } label: {
            ZStack {
                Color.clear
                    .overlay { background }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack {
                    HStack {
                        if thumbnails.live.contains(camera.id) {
                            liveBadge
                        } else if let thumbnail {
                            age(of: thumbnail.date)
                        }
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(camera.online ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(camera.online ? camera.name : "\(camera.name) · hors ligne")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .padding(8)
                .foregroundStyle(.white)
                if hovering && isEnabled {
                    Image(systemName: "macwindow")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(camera.online ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Ouvrir dans une fenêtre")
        .overlay(alignment: .topTrailing) {
            Button { open(camera.id, true) } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Picture in Picture : par-dessus toutes les apps, même en plein écran")
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var background: some View {
        if let thumbnail {
            Image(nsImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .brightness(hovering && isEnabled ? -0.1 : 0)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "video.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    private var liveBadge: some View {
        Text("EN DIRECT")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.85), in: Capsule())
    }

    /// How old the still is, so it is never mistaken for live video.
    private func age(of date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.ageText(from: date, to: context.date))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private static func ageText(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "à l'instant" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// When this binary was linked (its executable's modification date).
enum BuildInfo {
    static let date: String = {
        guard let url = Bundle.main.executableURL,
              let built = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "inconnu" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy, HH:mm:ss"
        return f.string(from: built)
    }()
}
