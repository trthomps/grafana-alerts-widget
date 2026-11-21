import QtQuick
import org.kde.plasma.plasma5support as P5Support

import "../code/grafana.js" as G

// Runs shell commands through Plasma's executable data engine (QML can't read the keyring or the
// environment on its own). run() returns a Promise of { code, stdout, stderr }.
P5Support.DataSource {
    id: shell
    engine: "executable"
    connectedSources: []

    property var callbacks: ({})
    property int serial: 0

    onNewData: (source, data) => {
        const cb = callbacks[source]
        delete callbacks[source]
        disconnectSource(source)
        if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "")
    }

    function run(command) {
        return new Promise(resolve => {
            // A unique trailing comment lets the same command run again while an old one lingers.
            // Nothing may hang the widget (e.g. secret-tool waiting on a keyring unlock prompt):
            // give every command 25 seconds. timeout signals the whole process group.
            const source = "timeout 25 sh -c " + G.shellQuote(command) + " # " + (++serial)
            callbacks[source] = (code, stdout, stderr) => resolve({ code, stdout, stderr })
            connectSource(source)
        })
    }

    readonly property string secretService: "io.github.trthomps.grafana-alerts"

    /// Resolves to the stored secret, or "" if there isn't one. Rejects (kind "keyring") when
    /// secret-tool is missing, times out on a locked keyring, or fails.
    function lookupSecret(account) {
        return run("secret-tool lookup service " + G.shellQuote(secretService) + " account " + G.shellQuote(account))
            .then(r => {
                const err = G.keyringError(r.code, r.stderr)
                if (err) throw err
                return r.code === 0 ? G.cleanSecret(r.stdout) : ""
            })
    }

    /// For the user to run in a terminal: secret-tool prompts for the secret, so it never lands in
    /// shell history or a process listing.
    function storeCommand(account, label) {
        return "secret-tool store --label=" + G.shellQuote(label)
            + " service " + G.shellQuote(secretService) + " account " + G.shellQuote(account)
    }

    function clearCommand(account) {
        return "secret-tool clear service " + G.shellQuote(secretService) + " account " + G.shellQuote(account)
    }

    /// GRAFANA_URL and GRAFANA_SERVICE_ACCOUNT_TOKEN (or GRAFANA_API_KEY) from plasmashell's
    /// environment, the variables mcp-grafana uses. Resolves to { baseURL, token } or null.
    function readEnvironment() {
        return run('printf "%s\\n%s\\n" "$GRAFANA_URL" "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-$GRAFANA_API_KEY}"').then(r => {
            const lines = r.stdout.split("\n")
            const base = G.normalizeServer(lines[0] || "")
            const token = (lines[1] || "").trim()
            return base && token ? { baseURL: base, token: token } : null
        })
    }
}
