import Foundation

enum AuthMode: String, CaseIterable, Identifiable {
    case token, basic, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .token: "Service account token"
        case .basic: "Username & password"
        case .none: "No auth"
        }
    }
}

/// What every API call needs: where the server is and how to authenticate.
struct Credential: Equatable {
    var baseURL: URL
    /// The full Authorization header value, or nil for anonymous access.
    var authorization: String?
    /// For display: "Service account token", "Environment", …
    var source: String
}

enum CredentialProvider {
    /// Settings first; falls back to `GRAFANA_URL` + `GRAFANA_SERVICE_ACCOUNT_TOKEN` (or
    /// `GRAFANA_API_KEY`), the same variables the Grafana CLI tools and MCP server use.
    static func current() throws -> Credential {
        if let base = normalizedServer(Prefs.serverURL) {
            switch Prefs.authMode {
            case .token:
                if let token = SecretStore.read(tokenAccount(base)) {
                    return Credential(baseURL: base, authorization: "Bearer \(token)", source: "Service account token")
                }
                if let env = environment(), env.baseURL == base { return env }
                throw GrafanaError.notConfigured
            case .basic:
                guard let password = SecretStore.read(passwordAccount(base)), let user = Prefs.basicUser.nonEmpty else {
                    throw GrafanaError.notConfigured
                }
                let encoded = Data("\(user):\(password)".utf8).base64EncodedString()
                return Credential(baseURL: base, authorization: "Basic \(encoded)", source: "Basic auth as \(user)")
            case .none:
                return Credential(baseURL: base, authorization: nil, source: "Anonymous")
            }
        }
        if let env = environment() { return env }
        throw GrafanaError.notConfigured
    }

    static func environment() -> Credential? {
        let env = ProcessInfo.processInfo.environment
        guard let base = normalizedServer(env["GRAFANA_URL"] ?? ""),
              let token = (env["GRAFANA_SERVICE_ACCOUNT_TOKEN"] ?? env["GRAFANA_API_KEY"]).nonEmpty else { return nil }
        return Credential(baseURL: base, authorization: "Bearer \(token)", source: "Environment (GRAFANA_URL)")
    }

    /// "grafana.example.com/" → "https://grafana.example.com". Keeps a sub-path for Grafana
    /// served under one (`https://example.com/grafana`). Strips a pasted page path like
    /// `/alerting/list?...`.
    static func normalizedServer(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              components.scheme == "https" || components.scheme == "http" else { return nil }
        components.query = nil
        components.fragment = nil
        var path = components.path
        for marker in ["/alerting", "/d/", "/dashboards", "/explore", "/login", "/a/", "/admin", "/connections"] {
            if let range = path.range(of: marker) { path = String(path[..<range.lowerBound]) }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    static func tokenAccount(_ base: URL) -> String { "token:\(base.absoluteString)" }
    static func passwordAccount(_ base: URL) -> String { "password:\(base.absoluteString)" }
}

/// Secrets in the login Keychain via `/usr/bin/security`. Using the CLI (rather than the
/// Security framework) means reads don't prompt again after every ad-hoc re-sign.
enum SecretStore {
    static let service = "io.github.trthomps.grafana-alerts"

    static func read(_ account: String) -> String? {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard status == 0 else { return nil }
        return output.nonEmpty
    }

    /// The secret goes over stdin (hex-encoded), so it never shows up in a process listing.
    @discardableResult
    static func write(_ account: String, _ secret: String) -> Bool {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(sanitize(account))\" -X \(hex)\n"
        let (status, _) = run(["-i"], stdin: command)
        return status == 0 && read(account) == secret
    }

    static func delete(_ account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func sanitize(_ text: String) -> String {
        text.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline }
    }

    private static func run(_ arguments: [String], stdin: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return (-1, "") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
