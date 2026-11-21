import Foundation

/// The parts of Grafana's HTTP API this app uses. All of it is Grafana-managed alerting:
///
/// - `GET /api/prometheus/grafana/api/v1/rules?state=firing&state=pending&state=recovering`
///   Rules (with folder, group, labels, annotations, health) and their matching instances.
/// - `GET /api/alertmanager/grafana/api/v2/alerts` to learn which instances are silenced or inhibited.
/// - `POST /api/alertmanager/grafana/api/v2/silences` to silence a rule or one instance.
/// - `GET /api/health` for the version (no auth needed).
struct GrafanaAPI {
    let credential: Credential
    var session: URLSession = .shared

    // MARK: - Rules

    func activeRules() async throws -> [AlertRule] {
        let response: RulesResponse = try await get("api/prometheus/grafana/api/v1/rules", query: [
            "state": ["firing", "pending", "recovering"],
        ])
        var rules: [AlertRule] = []
        for group in response.data.groups {
            for rule in group.rules where rule.type == nil || rule.type == "alerting" {
                guard let uid = rule.uid else { continue }
                let instances = (rule.alerts ?? []).map { alert in
                    AlertInstance(
                        ruleUID: uid,
                        labels: alert.labels ?? [:],
                        annotations: alert.annotations ?? [:],
                        state: AlertState(instance: alert.state),
                        reason: Self.reason(alert.state),
                        // Unset times come through as year 1.
                        activeAt: alert.activeAt.flatMap(Self.parseDate).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
                        value: alert.value
                    )
                }
                rules.append(AlertRule(
                    uid: uid,
                    name: rule.name,
                    folder: group.file,
                    folderUID: rule.folderUid ?? group.folderUid,
                    group: group.name,
                    state: AlertState(rule: rule.state ?? ""),
                    health: rule.health ?? "ok",
                    lastError: rule.lastError.nonEmpty,
                    labels: rule.labels ?? [:],
                    annotations: rule.annotations ?? [:],
                    instances: instances,
                    isPaused: rule.isPaused ?? false
                ))
            }
        }
        return rules
    }

    /// "Alerting (NoData)" → "NoData".
    private static func reason(_ state: String) -> String? {
        guard let open = state.firstIndex(of: "("), let close = state.lastIndex(of: ")"), open < close else { return nil }
        return String(state[state.index(after: open)..<close]).nonEmpty
    }

    private struct RulesResponse: Decodable {
        var data: DataDTO
        struct DataDTO: Decodable { var groups: [GroupDTO] }
    }

    private struct GroupDTO: Decodable {
        var name: String
        var file: String
        var folderUid: String?
        var rules: [RuleDTO]
    }

    private struct RuleDTO: Decodable {
        var uid: String?
        var name: String
        var state: String?
        var health: String?
        var lastError: String?
        var type: String?
        var folderUid: String?
        var isPaused: Bool?
        var labels: [String: String]?
        var annotations: [String: String]?
        var alerts: [AlertDTO]?
    }

    private struct AlertDTO: Decodable {
        var labels: [String: String]?
        var annotations: [String: String]?
        var state: String
        var activeAt: String?
        var value: String?
    }

    // MARK: - Alertmanager

    /// Label keys (`AlertInstance.labelKey`, prefixed by rule UID) of instances Alertmanager is
    /// currently suppressing (silenced or inhibited).
    func suppressedInstanceIDs() async throws -> Set<String> {
        let alerts: [AMAlertDTO] = try await get("api/alertmanager/grafana/api/v2/alerts", query: [
            "active": ["true"], "silenced": ["true"], "inhibited": ["true"],
        ])
        var ids = Set<String>()
        for alert in alerts where alert.status.state == "suppressed" {
            guard let uid = alert.labels["__alert_rule_uid__"] else { continue }
            ids.insert("\(uid)|\(AlertInstance.labelKey(alert.labels))")
        }
        return ids
    }

    private struct AMAlertDTO: Decodable {
        var labels: [String: String]
        var status: Status
        struct Status: Decodable { var state: String }
    }

    /// Silences a whole rule, or one instance when `labels` is given.
    func createSilence(ruleUID: String, labels: [String: String]?, duration: TimeInterval, comment: String) async throws {
        var matchers: [[String: Any]] = [["name": "__alert_rule_uid__", "value": ruleUID, "isRegex": false, "isEqual": true]]
        for (key, value) in (labels ?? [:]).sorted(by: { $0.key < $1.key }) where !key.hasPrefix("__") {
            matchers.append(["name": key, "value": value, "isRegex": false, "isEqual": true])
        }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "matchers": matchers,
            "startsAt": formatter.string(from: now),
            "endsAt": formatter.string(from: now.addingTimeInterval(duration)),
            "createdBy": "Grafana Alerts (macOS)",
            "comment": comment,
        ]
        var request = request(url("api/alertmanager/grafana/api/v2/silences", query: [:]), method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    // MARK: - Misc

    func version() async throws -> String {
        struct Health: Decodable { var version: String? }
        let health: Health = try await get("api/health")
        return health.version ?? "?"
    }

    // MARK: - Plumbing

    private func url(_ path: String, query: [String: [String]]) -> URL {
        var components = URLComponents(url: credential.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.sorted { $0.key < $1.key }.flatMap { key, values in
            values.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [String: [String]] = [:]) async throws -> T {
        let target = url(path, query: query)
        let data = try await perform(request(target, method: "GET"))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if let text = String(data: data.prefix(200), encoding: .utf8), text.lowercased().contains("<html") {
                throw GrafanaError.decoding("Got a web page instead of JSON from \(target.path). Is the server URL right?")
            }
            throw GrafanaError.decoding("Couldn't read \(target.path): \(error)")
        }
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        if let authorization = credential.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GrafanaAlerts/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GrafanaError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GrafanaError.network("No HTTP response") }
        Debug.log("\(request.httpMethod ?? "") \(request.url?.path ?? "") → \(http.statusCode)")
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw GrafanaError.unauthorized(Self.serverMessage(data))
        case 403: throw GrafanaError.forbidden(Self.serverMessage(data))
        default: throw GrafanaError.http(http.statusCode, Self.serverMessage(data))
        }
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["message"] as? String).nonEmpty ?? (object["error"] as? String).nonEmpty
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Grafana sometimes sends nanoseconds ("2026-11-20T03:59:00.123456789Z"): trim to millis.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            return fractional.date(from: "\(text[..<dot]).\(fraction)\(text[zone...])")
        }
        return nil
    }
}

extension URL {
    func appending(grafanaPath path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}
