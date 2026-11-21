import Foundation

/// Where an alert rule or instance is in its lifecycle, as Grafana reports it.
enum AlertState: String, Codable, Comparable, CaseIterable {
    case firing, recovering, pending, normal

    /// Instance states look like "Alerting", "Alerting (NoData)", "Alerting (Error)", "Pending",
    /// "Recovering", "Normal", "NoData", "Error".
    init(instance raw: String) {
        let lower = raw.lowercased()
        // Plain "NoData"/"Error" means the rule's no-data/error handling is set to that state:
        // Grafana still notifies (DatasourceNoData / DatasourceError), so treat them as firing.
        if lower.hasPrefix("alerting") || lower.hasPrefix("firing") || lower == "nodata" || lower == "error" {
            self = .firing
        }
        else if lower.hasPrefix("recovering") { self = .recovering }
        else if lower.hasPrefix("pending") { self = .pending }
        else { self = .normal }
    }

    /// Rule states: "firing", "pending", "recovering", "inactive".
    init(rule raw: String) {
        self = AlertState(rawValue: raw.lowercased()) ?? .normal
    }

    /// Firing and recovering alerts are still being sent to contact points.
    var isActive: Bool { self == .firing || self == .recovering }

    var title: String {
        switch self {
        case .firing: "Firing"
        case .recovering: "Recovering"
        case .pending: "Pending"
        case .normal: "Normal"
        }
    }

    private var rank: Int {
        switch self {
        case .firing: 0
        case .recovering: 1
        case .pending: 2
        case .normal: 3
        }
    }

    /// Most urgent first.
    static func < (a: AlertState, b: AlertState) -> Bool { a.rank < b.rank }
}

/// Severity from the conventional `severity` label. Higher is worse.
enum Severity: Int, Comparable, CaseIterable, Identifiable {
    case unknown = 0, info = 1, warning = 2, critical = 3

    var id: Int { rawValue }

    init(label: String?) {
        switch label?.lowercased() {
        case nil, "": self = .unknown
        case "critical", "crit", "page", "p1", "high", "error", "emergency", "alert", "fatal", "disaster": self = .critical
        case "warning", "warn", "medium", "p2", "p3", "major", "minor", "average": self = .warning
        default: self = .info
        }
    }

    var title: String {
        switch self {
        case .unknown: "Any"
        case .info: "Info"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// One series of an alert rule (one label set).
struct AlertInstance: Identifiable, Equatable, Codable {
    var ruleUID: String
    var labels: [String: String]
    var annotations: [String: String]
    var state: AlertState
    /// "NoData" or "Error" when the instance is alerting because of that.
    var reason: String?
    var activeAt: Date?
    var value: String?
    var silenced = false

    /// Stable across refreshes: the rule plus its user-visible labels.
    var id: String { "\(ruleUID)|\(labelKey)" }

    /// Labels Grafana and Alertmanager agree on (internal `__*__` labels dropped), sorted.
    var labelKey: String { Self.labelKey(labels) }

    static func labelKey(_ labels: [String: String]) -> String {
        labels.filter { !$0.key.hasPrefix("__") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    var severity: Severity { Severity(label: labels["severity"]) }

    var summary: String? {
        annotations["summary"].nonEmpty ?? annotations["description"].nonEmpty
    }

    /// Labels worth showing next to the instance: not internal, not the rule's own name/folder,
    /// and not labels every instance of the rule shares.
    func distinguishingLabels(common: [String: String]) -> [(String, String)] {
        labels.filter { key, value in
            !key.hasPrefix("__") && key != "alertname" && key != "grafana_folder" && common[key] != value
        }
        .sorted { $0.key < $1.key }
        .map { ($0.key, $0.value) }
    }
}

/// A Grafana-managed alert rule with the instances that matched the state query.
struct AlertRule: Identifiable, Equatable, Codable {
    var uid: String
    var name: String
    var folder: String
    var folderUID: String?
    var group: String
    var state: AlertState
    var health: String
    var lastError: String?
    var labels: [String: String]
    var annotations: [String: String]
    var instances: [AlertInstance]
    var isPaused: Bool

    var id: String { uid }

    var runbookURL: URL? { annotations["runbook_url"].nonEmpty.flatMap(URL.init(string:)) }

    /// Labels shared by every instance, so rows only show what tells instances apart.
    var commonLabels: [String: String] {
        guard var common = instances.first?.labels else { return labels }
        for instance in instances.dropFirst() {
            common = common.filter { instance.labels[$0.key] == $0.value }
        }
        return common
    }
}

enum GrafanaError: Error, Equatable {
    case notConfigured
    case unauthorized(String?)
    case forbidden(String?)
    case http(Int, String?)
    case network(String)
    case decoding(String)

    var title: String {
        switch self {
        case .notConfigured: "Not set up"
        case .unauthorized: "Token rejected"
        case .forbidden: "Access denied"
        case .http(let code, _): "Server error \(code)"
        case .network: "Can't reach Grafana"
        case .decoding: "Unexpected response"
        }
    }

    var message: String {
        switch self {
        case .notConfigured:
            "Open Settings → Account and enter your Grafana URL and a service account token."
        case .unauthorized(let detail):
            detail ?? "Grafana rejected the credentials. Check the token in Settings → Account."
        case .forbidden(let detail):
            detail ?? "The token can't read alert rules. A Viewer service account is enough to read; silencing needs Editor."
        case .http(_, let detail): detail ?? "The server returned an error."
        case .network(let detail): detail
        case .decoding(let detail): detail
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "person.crop.circle.badge.questionmark"
        case .unauthorized, .forbidden: "lock.trianglebadge.exclamationmark"
        case .network: "wifi.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
