import AppKit
import SwiftUI

@main
struct AventMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    /// Read once: `body` is re-evaluated often and must not hit the Keychain.
    private static let hadSessionAtLaunch = SessionStore.hasSession

    var body: some Scene {
        Window("Baby Monitor", id: "main") {
            PanelView(showsQuit: false)
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.hadSessionAtLaunch ? .suppressed : .presented)

        WindowGroup("Caméra", id: "camera", for: String.self) { $cameraID in
            if let cameraID {
                CameraWindowView(cameraID: cameraID)
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 960, height: 540)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        // MenuBarExtra writes this binding back on every update; only forward
        // real changes, or each write republishes the model and loops.
        MenuBarExtra(isInserted: Binding(
            get: { model.showMenuBarIcon },
            set: { if model.showMenuBarIcon != $0 { model.showMenuBarIcon = $0 } }
        )) {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(activity: model.activity)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon, with a coloured dot per kind of activity detected in the last minute.
private struct MenuBarLabel: View {
    @ObservedObject var activity: ActivityCenter

    var body: some View {
        let kinds = activity.activeKinds
        if kinds.isEmpty {
            Image("MenuBarIcon")
        } else {
            Image(nsImage: ActivityBadge.menuBarImage(kinds))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window shows, so a Dock-less setup never flashes a Dock icon.
        let dock = UserDefaults.standard.object(forKey: AppModel.DefaultsKey.dock) as? Bool ?? true
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
