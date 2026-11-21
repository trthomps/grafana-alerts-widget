import AppKit
import Combine
import Network

/// A rule as the list shows it: the instances that passed the filters, or why it's hidden.
struct RuleItem: Identifiable, Equatable {
    var rule: AlertRule
    /// Shown instances for a shown rule; every non-normal instance for a hidden one.
    var instances: [AlertInstance]
    /// Instances of a shown rule that the filters dropped.
    var hiddenInstances: Int
    var hiddenReason: String?

    var id: String { rule.uid }

    var state: AlertState { instances.map(\.state).min() ?? rule.state }
    var severity: Severity { instances.map(\.severity).max() ?? Severity(label: rule.labels["severity"]) }
    var activeInstances: [AlertInstance] { instances.filter { $0.state.isActive } }
    /// What the badge counts: active and not silenced.
    var countedInstances: [AlertInstance] { instances.filter { $0.state.isActive && !$0.silenced } }
    var since: Date? { instances.compactMap(\.activeAt).min() }
    var allSilenced: Bool { !instances.isEmpty && instances.allSatisfy(\.silenced) }

    /// The single instance's summary, else the first one's.
    var summary: String? { instances.first?.summary ?? rule.annotations["summary"].nonEmpty }
}

/// Polls Grafana, applies the filters, posts banners and handles silencing.
@MainActor
final class AlertStore: ObservableObject {
    @Published private(set) var rules: [AlertRule] = []
    @Published private(set) var shown: [RuleItem] = []
    @Published private(set) var hidden: [RuleItem] = []
    @Published private(set) var error: GrafanaError?
    /// Couldn't read Alertmanager (silence state unknown); not fatal.
    @Published private(set) var silenceWarning: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastFetched: Date?
    @Published private(set) var credentialSource: String?
    @Published private(set) var serverURL: URL?
    @Published private(set) var version: String?
    @Published private(set) var now = Date()

    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var wasOnline = true
    private var filters = Prefs.filters
    /// Active instances already announced (or present at launch), by instance id.
    private var announced: [String: AlertInstance] = [:]
    private var hasLoadedOnce = false
    /// Bumped when the account changes so in-flight results for the old one are dropped.
    private var generation = 0
    private var refreshQueued = false
    private var credential: Credential?

    // MARK: - Counts

    /// The badge number: rules (or instances) with an active alert that passes the filters.
    var badgeCount: Int {
        switch Prefs.countMode {
        case .rules: shown.filter { !$0.countedInstances.isEmpty }.count
        case .instances: shown.reduce(0) { $0 + $1.countedInstances.count }
        }
    }

    var pendingCount: Int { shown.filter { $0.activeInstances.isEmpty && $0.state == .pending }.count }

    /// Worst severity among counted alerts, for the badge color.
    var worstSeverity: Severity? {
        shown.flatMap(\.countedInstances).map(\.severity).max { a, b in
            // Unknown sorts as critical: an unlabeled alert gets the red badge.
            (a == .unknown ? Severity.critical : a) < (b == .unknown ? Severity.critical : b)
        }
    }

    // MARK: - Lifecycle

    func start() {
        reschedulePolling()
        let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        clock.tolerance = 5
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Task { await self?.refresh() }
                }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.wasOnline = online }
                    if online, !self.wasOnline || self.error != nil {
                        Task { await self.refresh() }
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "grafana-alerts.path"))

        Task { await refresh() }
    }

    var isStale: Bool {
        guard let lastFetched else { return false }
        return now.timeIntervalSince(lastFetched) > max(Prefs.refreshInterval * 3, 5 * 60)
    }

    var shouldRefreshOnOpen: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > 15
    }

    func preferencesChanged() {
        if Prefs.refreshInterval != pollInterval { reschedulePolling() }
        let latest = Prefs.filters
        if latest != filters {
            filters = latest
            applyFilters()
            // New filters shouldn't read as alerts starting or resolving.
            announced = currentlyActive()
        }
        objectWillChange.send()   // count mode / colors may have changed
    }

    /// Server or credentials changed: start over.
    func accountChanged() {
        generation += 1
        credential = nil
        rules = []
        shown = []
        hidden = []
        announced = [:]
        hasLoadedOnce = false
        lastFetched = nil
        version = nil
        error = nil
        silenceWarning = nil
        serverURL = nil
        credentialSource = nil
        Task { await refresh(userInitiated: true) }
    }

    private func reschedulePolling() {
        pollTimer?.invalidate()
        pollInterval = Prefs.refreshInterval
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        timer.tolerance = pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Fetching

    /// `quiet` skips banners (used by --print).
    func refresh(userInitiated: Bool = false, quiet: Bool = false) async {
        guard !isRefreshing else {
            if userInitiated { refreshQueued = true }
            return
        }
        isRefreshing = true
        let started = generation
        defer {
            isRefreshing = false
            now = Date()
            if refreshQueued {
                refreshQueued = false
                Task { await refresh(userInitiated: true, quiet: quiet) }
            }
        }
        do {
            let credential = try currentCredential()
            credentialSource = credential.source
            serverURL = credential.baseURL
            let api = GrafanaAPI(credential: credential)

            async let rulesCall = api.activeRules()
            async let suppressedCall = api.suppressedInstanceIDs()
            var fetched = try await rulesCall
            let suppressed: Set<String>?
            do {
                suppressed = try await suppressedCall
            } catch {
                suppressed = nil
                Debug.log("alertmanager lookup failed: \(error)")
            }
            guard started == generation else { return }

            // If Alertmanager didn't answer, keep the last known silence state rather than
            // flipping every silenced alert back to firing (and announcing it).
            let silenced = suppressed ?? Set(rules.flatMap(\.instances).filter(\.silenced).map(\.id))
            for r in fetched.indices {
                for i in fetched[r].instances.indices {
                    fetched[r].instances[i].silenced = silenced.contains(fetched[r].instances[i].id)
                }
            }
            silenceWarning = suppressed == nil
                ? "Couldn't read silences from Alertmanager; showing the last known silences." : nil
            rules = fetched
            lastFetched = Date()
            error = nil
            applyFilters()
            // Without silence info, newly silenced alerts would look new: wait for the next poll.
            // (On the very first poll, still record the baseline so nothing is announced later as new.)
            if suppressed != nil { announce(quiet: quiet) } else if !hasLoadedOnce { announced = currentlyActive() }
            hasLoadedOnce = true
            if version == nil {
                let fetchedVersion = try? await api.version()
                guard started == generation else { return }
                version = fetchedVersion
            }
        } catch is CancellationError {
            return
        } catch let failure as GrafanaError {
            guard started == generation else { return }
            Debug.log("refresh failed: \(failure)")
            if case .unauthorized = failure { credential = nil }   // re-read the Keychain next time
            if failure == .notConfigured { credential = nil }
            error = failure
        } catch {
            guard started == generation else { return }
            self.error = .network(error.localizedDescription)
        }
    }

    private func currentCredential() throws -> Credential {
        if let credential { return credential }
        let fresh = try CredentialProvider.current()
        credential = fresh
        return fresh
    }

    private func applyFilters() {
        var shown: [RuleItem] = [], hidden: [RuleItem] = []
        for rule in rules {
            let candidates = rule.instances.filter { $0.state != .normal }
            if let reason = filters.ruleHiddenReason(rule) {
                if !candidates.isEmpty {
                    hidden.append(RuleItem(rule: rule, instances: candidates, hiddenInstances: 0, hiddenReason: reason))
                }
                continue
            }
            var passing: [AlertInstance] = []
            var reasons: [String] = []
            for instance in candidates {
                if let reason = filters.instanceHiddenReason(instance) { reasons.append(reason) } else { passing.append(instance) }
            }
            if passing.isEmpty {
                guard !candidates.isEmpty else { continue }
                let common = Dictionary(grouping: reasons, by: { $0 }).max { $0.value.count < $1.value.count }?.key
                hidden.append(RuleItem(rule: rule, instances: candidates, hiddenInstances: 0, hiddenReason: common))
            } else {
                shown.append(RuleItem(rule: rule, instances: passing.sorted(by: Self.instanceOrder),
                                      hiddenInstances: candidates.count - passing.count, hiddenReason: nil))
            }
        }
        shown.sort(by: Self.itemOrder)
        hidden.sort(by: Self.itemOrder)
        self.shown = shown
        self.hidden = hidden
    }

    /// Firing before pending, worst severity first, then most recently started.
    private static func itemOrder(_ a: RuleItem, _ b: RuleItem) -> Bool {
        if a.state != b.state { return a.state < b.state }
        if a.allSilenced != b.allSilenced { return !a.allSilenced }
        if a.severity != b.severity { return a.severity > b.severity }
        let at = a.instances.compactMap(\.activeAt).max() ?? .distantPast
        let bt = b.instances.compactMap(\.activeAt).max() ?? .distantPast
        if at != bt { return at > bt }
        return a.rule.name.localizedCaseInsensitiveCompare(b.rule.name) == .orderedAscending
    }

    private static func instanceOrder(_ a: AlertInstance, _ b: AlertInstance) -> Bool {
        if a.state != b.state { return a.state < b.state }
        if a.silenced != b.silenced { return !a.silenced }
        return a.labelKey < b.labelKey
    }

    /// Active, unsilenced instances that pass the filters: what banners are about.
    private func currentlyActive() -> [String: AlertInstance] {
        var result: [String: AlertInstance] = [:]
        for item in shown {
            for instance in item.activeInstances where !instance.silenced { result[instance.id] = instance }
        }
        return result
    }

    private func announce(quiet: Bool) {
        let current = currentlyActive()
        defer { announced = current }
        guard hasLoadedOnce, !quiet else { return }

        if Prefs.notifyFiring {
            let fresh = current.filter { announced[$0.key] == nil }
            let byRule = Dictionary(grouping: fresh.values, by: \.ruleUID)
            let items = shown.compactMap { item -> (AlertRule, [AlertInstance])? in
                guard let instances = byRule[item.rule.uid] else { return nil }
                return (item.rule, instances.sorted(by: Self.instanceOrder))
            }
            SystemNotifier.postFiring(items, baseURL: serverURL)
        }
        if Prefs.notifyResolved {
            // The rules query only returns rules with firing/pending instances, so a rule that
            // vanished from the response has resolved entirely. One that's still there only
            // resolved if the instance is no longer active (rather than silenced or filtered).
            let liveRules = Dictionary(uniqueKeysWithValues: rules.map { ($0.uid, $0) })
            let gone = announced.filter { current[$0.key] == nil }.map(\.value).filter { instance in
                guard let rule = liveRules[instance.ruleUID] else { return true }
                return !rule.instances.contains { $0.id == instance.id && $0.state.isActive }
            }
            let byRule = Dictionary(grouping: gone, by: \.ruleUID)
            let names = Dictionary(rules.map { ($0.uid, $0.name) }, uniquingKeysWith: { a, _ in a })
            SystemNotifier.postResolved(byRule.map { (names[$0.key] ?? $0.value.first?.labels["alertname"] ?? "Alert", $0.value) })
        }
    }

    // MARK: - Links

    func ruleURL(_ uid: String) -> URL? {
        serverURL?.appending(grafanaPath: "alerting/grafana/\(uid)/view")
    }

    var firingListURL: URL? {
        serverURL?.appending(grafanaPath: "alerting/list", query: ["search": "state:firing"])
    }

    var silencesURL: URL? { serverURL?.appending(grafanaPath: "alerting/silences") }

    /// Dashboard panel the rule is linked to, if any.
    func dashboardURL(_ rule: AlertRule) -> URL? {
        let annotations = rule.annotations.merging(rule.instances.first?.annotations ?? [:]) { a, _ in a }
        guard let dash = annotations["__dashboardUid__"].nonEmpty else { return nil }
        var query: [String: String] = [:]
        if let panel = annotations["__panelId__"].nonEmpty { query["viewPanel"] = panel }
        return serverURL?.appending(grafanaPath: "d/\(dash)", query: query)
    }

    func open(ruleUID: String) {
        if let url = ruleURL(ruleUID) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Silencing

    @Published private(set) var silenceMessage: String?

    func silence(rule: AlertRule, instance: AlertInstance?, duration: TimeInterval) async {
        do {
            let credential = try currentCredential()
            let what = instance.map { i in
                i.distinguishingLabels(common: rule.commonLabels).map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            }
            try await GrafanaAPI(credential: credential).createSilence(
                ruleUID: rule.uid, labels: instance?.labels, duration: duration,
                comment: "Silenced from the Grafana Alerts menu bar app" + (what.flatMap(\.nonEmpty).map { " (\($0))" } ?? "")
            )
            silenceMessage = "Silenced \(rule.name) for \(Fmt.duration(duration))."
            await refresh(userInitiated: true)
        } catch let failure as GrafanaError {
            if case .forbidden = failure {
                silenceMessage = "Couldn't silence: the token needs permission to create silences (Editor role, or alert.silences:create)."
            } else {
                silenceMessage = "Couldn't silence: \(failure.message)"
            }
        } catch {
            silenceMessage = "Couldn't silence: \(error.localizedDescription)"
        }
        let message = silenceMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                if self?.silenceMessage == message { self?.silenceMessage = nil }
            }
        }
    }
}
