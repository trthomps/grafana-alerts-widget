import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let store: AlertStore
    private var window: NSWindow?

    init(store: AlertStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Grafana Alerts Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable {
    case general, account, filters
}

struct SettingsView: View {
    @ObservedObject var store: AlertStore
    @State private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountSettings(store: store)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            FilterSettingsView(store: store)
                .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.filters)
        }
        .frame(width: 540, height: 660)
        .onAppear {
            if store.error == .notConfigured || (try? CredentialProvider.current()) == nil { tab = .account }
        }
    }
}

private func note(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var store: AlertStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.iconColor) private var iconColor: IconColor = .color
    @AppStorage(PrefKey.badgeStyle) private var badgeStyle: BadgeStyle = .badge
    @AppStorage(PrefKey.severityColors) private var severityColors = true
    @AppStorage(PrefKey.countMode) private var countMode: CountMode = .rules
    @AppStorage(PrefKey.dimWhenEmpty) private var dimWhenEmpty = true
    @AppStorage(PrefKey.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(PrefKey.notifyFiring) private var notifyFiring = true
    @AppStorage(PrefKey.notifyResolved) private var notifyResolved = false
    @AppStorage(PrefKey.notifySound) private var notifySound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar icon") {
                HStack(spacing: 10) {
                    ForEach(IconColor.allCases) { candidate in
                        tile(candidate.title, selected: candidate == iconColor, image: preview(color: candidate))
                            .onTapGesture { iconColor = candidate }
                    }
                }
                .padding(.vertical, 4)
                Picker("Count", selection: $badgeStyle) {
                    ForEach(BadgeStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Count what", selection: $countMode) {
                    ForEach(CountMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                note("A rule firing for 5 hosts is 1 rule, 5 instances. Grafana's alert list counts rules.")
                Toggle("Color the count by severity (critical red, warning orange)", isOn: $severityColors)
                Toggle("Dim the icon when nothing is firing", isOn: $dimWhenEmpty)
            }

            Section("Notifications") {
                Toggle("Notify when an alert starts firing", isOn: $notifyFiring)
                    .onChange(of: notifyFiring) { _, enabled in requestIfNeeded(enabled) { notifyFiring = false } }
                Toggle("Notify when an alert resolves", isOn: $notifyResolved)
                    .onChange(of: notifyResolved) { _, enabled in requestIfNeeded(enabled) { notifyResolved = false } }
                Toggle("Play a sound", isOn: $notifySound)
                    .disabled(!notifyFiring && !notifyResolved)
                if !SystemNotifier.available {
                    note("macOS notifications need the app bundle (`make app`), not `swift run`.")
                } else {
                    note("Only for alerts that pass your filters, and not for silenced ones. Clicking a banner opens the rule in Grafana.")
                }
            }

            Section("Behavior") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func requestIfNeeded(_ enabled: Bool, revert: @escaping () -> Void) {
        guard enabled else { return }
        Task {
            if !(await SystemNotifier.requestAuthorization()) { revert() }
        }
    }

    private func preview(color: IconColor) -> NSImage {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        let model = MenuBarModel(state: .ok, count: max(store.badgeCount, 4), severity: store.worstSeverity ?? .critical,
                                 color: color, badge: badgeStyle, severityColors: severityColors)
        return MenuBarRenderer.image(for: model, appearance: appearance)
    }

    private func tile(_ title: String, selected: Bool, image: NSImage) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.95)))
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Account

private struct AccountSettings: View {
    @ObservedObject var store: AlertStore
    @AppStorage(PrefKey.authMode) private var authMode: AuthMode = .token
    @AppStorage(PrefKey.serverURL) private var serverURL = ""
    @AppStorage(PrefKey.basicUser) private var basicUser = ""
    @State private var secretDraft = ""
    @State private var hasSecret = false
    @State private var message: String?
    @State private var serverEdit: Task<Void, Never>?

    private var base: URL? { CredentialProvider.normalizedServer(serverURL) }

    var body: some View {
        Form {
            Section {
                TextField("Grafana URL", text: $serverURL, prompt: Text("https://grafana.example.com"))
                Picker("Sign in with", selection: $authMode) {
                    ForEach(AuthMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: authMode) { _, _ in changed() }
            } header: {
                Text("Server")
            } footer: {
                if serverURL.isEmpty, let env = CredentialProvider.environment() {
                    note("Using \(env.baseURL.absoluteString) from GRAFANA_URL until you fill this in.")
                }
            }

            switch authMode {
            case .token: tokenSection
            case .basic: basicSection
            case .none:
                Section("No auth") {
                    note("For Grafana with anonymous access enabled. The anonymous role needs to be able to read alert rules.")
                }
            }

            Section("Status") {
                if let error = store.error {
                    LabeledContent("Status", value: error.title)
                    note(LocalizedStringKey(error.message))
                } else if store.lastFetched != nil {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Firing", value: "\(store.rules.filter { $0.state.isActive }.count) rules")
                } else {
                    LabeledContent("Status", value: "Connecting…")
                }
                if let server = store.serverURL { LabeledContent("Server", value: server.absoluteString) }
                if let version = store.version { LabeledContent("Grafana", value: version) }
                if let source = store.credentialSource { LabeledContent("Using", value: source) }
                if let warning = store.silenceWarning { note(LocalizedStringKey(warning)) }
                if let message { note(LocalizedStringKey(message)) }
                HStack {
                    Spacer()
                    Button("Test Connection") { store.accountChanged() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadState)
        .onChange(of: serverURL) { _, _ in
            // Typing in the URL field: wait for a pause, then switch servers.
            serverEdit?.cancel()
            serverEdit = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                reloadState()
                if store.serverURL != base { store.accountChanged() }
            }
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField("Token", text: $secretDraft, prompt: Text(hasSecret ? "•••••••• (saved)" : "glsa_…"))
            HStack {
                if hasSecret {
                    Button("Remove Token", role: .destructive) { removeSecret(CredentialProvider.tokenAccount) }
                }
                Spacer()
                if let base {
                    Button("Create Token in Grafana…") {
                        NSWorkspace.shared.open(base.appending(grafanaPath: "org/serviceaccounts/create"))
                    }
                }
                Button("Save") { saveSecret(CredentialProvider.tokenAccount) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secretDraft.isEmpty || base == nil)
            }
            note("In Grafana: Administration → Users and access → Service accounts → Add service account. The **Viewer** role is enough to read alerts; **Editor** also lets you silence from the menu. Then *Add service account token* and paste it here. Stored in your Keychain.")
        } header: {
            Text("Service account token")
        }
    }

    private var basicSection: some View {
        Section {
            TextField("Username", text: $basicUser)
                .onChange(of: basicUser) { _, _ in store.accountChanged() }
            SecureField("Password", text: $secretDraft, prompt: Text(hasSecret ? "•••••••• (saved)" : ""))
            HStack {
                if hasSecret {
                    Button("Remove Password", role: .destructive) { removeSecret(CredentialProvider.passwordAccount) }
                }
                Spacer()
                Button("Save") { saveSecret(CredentialProvider.passwordAccount) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secretDraft.isEmpty || base == nil || basicUser.isEmpty)
            }
            note("Grafana's own login (basic auth must be enabled, which it is by default). Doesn't work with SSO-only accounts; use a service account token for those. Stored in your Keychain.")
        } header: {
            Text("Username & password")
        }
    }

    private func reloadState() {
        guard let base else {
            hasSecret = false
            return
        }
        let account = authMode == .basic ? CredentialProvider.passwordAccount(base) : CredentialProvider.tokenAccount(base)
        hasSecret = SecretStore.read(account) != nil
    }

    private func changed() {
        message = nil
        secretDraft = ""
        reloadState()
        store.accountChanged()
    }

    private func saveSecret(_ account: (URL) -> String) {
        guard let base else { return }
        let secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if SecretStore.write(account(base), secret) {
            serverURL = base.absoluteString
            message = "Saved to the Keychain."
            changed()
            message = "Saved to the Keychain."
        } else {
            message = "Couldn't save to the Keychain."
        }
    }

    private func removeSecret(_ account: (URL) -> String) {
        guard let base else { return }
        SecretStore.delete(account(base))
        changed()
    }
}

// MARK: - Filters

private struct FilterSettingsView: View {
    @ObservedObject var store: AlertStore
    @AppStorage(PrefKey.showPending) private var showPending = false
    @AppStorage(PrefKey.hideSilenced) private var hideSilenced = true
    @AppStorage(PrefKey.minSeverity) private var minSeverity = Severity.unknown.rawValue
    @AppStorage(PrefKey.includeFolders) private var includeFolders = ""
    @AppStorage(PrefKey.excludeFolders) private var excludeFolders = ""
    @AppStorage(PrefKey.excludeGroups) private var excludeGroups = ""
    @AppStorage(PrefKey.excludeRules) private var excludeRules = ""
    @AppStorage(PrefKey.includeLabels) private var includeLabels = ""
    @AppStorage(PrefKey.excludeLabels) private var excludeLabels = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("\(store.shown.count) shown · \(store.hidden.count) hidden")
                        .monospacedDigit()
                    Spacer()
                    Button("Reset Filters", action: reset)
                }
                if !topReasons.isEmpty {
                    note(LocalizedStringKey("Hidden because: " + topReasons.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")))
                }
            }

            Section("State") {
                Toggle("Show pending alerts", isOn: $showPending)
                note("Pending alerts have met their condition but not yet for the rule's pending period. They're listed but never counted or announced.")
                Toggle("Hide silenced and inhibited alerts", isOn: $hideSilenced)
                Picker("Minimum severity", selection: $minSeverity) {
                    ForEach(Severity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                note("Read from the `severity` label (critical/warning/info and common synonyms). Alerts without one always show.")
            }

            Section {
                TextField("Only these folders", text: $includeFolders, prompt: Text("everything"))
                TextField("Hide folders", text: $excludeFolders, prompt: Text("Staging, Experiments*"))
                chips(store.rules.map(\.folder), excluded: Prefs.patterns(PrefKey.excludeFolders)) {
                    append($0, to: &excludeFolders)
                }
                TextField("Hide groups", text: $excludeGroups, prompt: Text("noisy-checks, Folder/group"))
                TextField("Hide rules named", text: $excludeRules, prompt: Text("Watchdog, *test*"))
            } header: {
                Text("Folders, groups and rules")
            }

            Section {
                TextField("Only alerts with", text: $includeLabels, prompt: Text("severity=critical, team=infra"))
                TextField("Hide alerts with", text: $excludeLabels, prompt: Text("host=build-01, env=dev*"))
                chips(labelSuggestions, excluded: Prefs.patterns(PrefKey.excludeLabels)) {
                    append($0, to: &excludeLabels)
                }
                note("`key=value` or `key!=value`; a bare `value` matches any label. Comma-separated, case-insensitive, `*` matches anything. *Only* passes alerts matching any one entry; *Hide* drops alerts matching any one.")
            } header: {
                Text("Labels")
            }
        }
        .formStyle(.grouped)
    }

    /// One-click "hide" buttons for whatever is currently filling the list.
    @ViewBuilder
    private func chips(_ values: [String], excluded: [String], add: @escaping (String) -> Void) -> some View {
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
            .filter { !Glob.any(excluded, matches: $0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
        if !counts.isEmpty {
            HStack(spacing: 6) {
                Text("Hide:").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(counts), id: \.key) { value, count in
                            Button("\(value) (\(count))") { add(value) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// `key=value` pairs from active alerts, skipping ones that are unique per instance.
    private var labelSuggestions: [String] {
        let instances = store.rules.flatMap(\.instances).filter { $0.state != .normal }
        let skip: Set<String> = ["alertname", "grafana_folder"]
        return instances.flatMap { instance in
            instance.labels.filter { !$0.key.hasPrefix("__") && !skip.contains($0.key) && $0.value.count < 40 }
                .map { "\($0.key)=\($0.value)" }
        }
    }

    private var topReasons: [(String, Int)] {
        let counts = Dictionary(grouping: store.hidden.compactMap(\.hiddenReason), by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }

    private func append(_ value: String, to text: inout String) {
        let existing = text.trimmingCharacters(in: .whitespaces)
        text = existing.isEmpty ? value : "\(existing), \(value)"
    }

    private func reset() {
        showPending = false
        hideSilenced = true
        minSeverity = Severity.unknown.rawValue
        includeFolders = ""; excludeFolders = ""; excludeGroups = ""; excludeRules = ""
        includeLabels = ""; excludeLabels = ""
    }
}
