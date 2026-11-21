import AppKit
import SwiftUI

@main
enum GrafanaAlertsApp {
    @MainActor
    static func main() {
        Prefs.registerDefaults()
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            Grafana Alerts — menu bar app for Grafana-managed alerts

              GrafanaAlerts                         run the menu bar app
              GrafanaAlerts --print                 print active alerts (with your filters) and exit
              GrafanaAlerts --render-icon DIR       render an .iconset for the app icon
              GrafanaAlerts --render-previews DIR   render menu bar icon PNGs

            Uses the server and token from Settings, or GRAFANA_URL and
            GRAFANA_SERVICE_ACCOUNT_TOKEN from the environment.
            """)
            return
        }
        if args.contains("--print") {
            exit(CLI.printAlerts())
        }
        if let dir = value(after: "--render-icon", in: args) {
            AppIcon.renderIconset(to: dir)
            return
        }
        if let dir = value(after: "--render-previews", in: args) {
            _ = NSApplication.shared
            CLI.renderPreviews(to: dir)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

struct AppActions {
    var refresh: () -> Void
    var openWeb: () -> Void
    var openSettings: () -> Void
    var closePopover: () -> Void = {}
    var quit: () -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AlertStore()
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var defaultsObserver: NSObjectProtocol?
    private var debounce: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = AppActions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.refresh(userInitiated: true) }
            },
            openWeb: { [weak self] in
                guard let url = self?.store.firingListURL else { return }
                NSWorkspace.shared.open(url)
            },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) }
        )

        statusController = StatusItemController(store: store, actions: actions)
        SystemNotifier.setUp { [weak self] uid in self?.store.open(ruleUID: uid) }
        if Prefs.notifyFiring || Prefs.notifyResolved {
            Task { _ = await SystemNotifier.requestAuthorization() }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }

        store.start()
        if (try? CredentialProvider.current()) == nil {
            showSettings()
        }
    }

    private func preferencesChanged() {
        statusController?.update()
        // Filter text fields write on every keystroke; wait for a pause before re-filtering.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.store.preferencesChanged() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings. That's the way in
    /// when a menu bar manager has hidden the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store)
        }
        settingsController?.show()
    }
}

/// `GRAFANA_ALERTS_DEBUG=1` prints diagnostics to stderr.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["GRAFANA_ALERTS_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[GrafanaAlerts] \(message())\n".utf8))
    }
}
