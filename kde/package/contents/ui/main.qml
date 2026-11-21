import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.notification

import "../code/grafana.js" as G

PlasmoidItem {
    id: root

    // MARK: - State (AlertStore.swift)

    property var rules: []
    property var shown: []               // G.makeItem objects
    property var hidden: []
    property var error: null             // G.errorInfo(...)
    /// Couldn't read Alertmanager (silence state unknown); not fatal.
    property string silenceWarning: ""
    property string silenceMessage: ""
    property bool refreshing: false
    property real lastFetched: 0
    property string credentialSource: ""
    property string version: ""
    property var credential: null       // { baseURL, authorization, source }
    property real now: Date.now()
    property real lastTick: Date.now()

    /// Active instances already announced (or present at the first poll): id → instance.
    property var announced: ({})
    property bool hasLoadedOnce: false
    /// Bumped when the account changes so in-flight results for the old one are dropped.
    property int generation: 0
    property bool refreshQueued: false
    /// Which entry of G.STATE_SETS each server accepted, and when: base → { index, at }.
    property var acceptedStateSet: ({})
    /// Rules whose instances are expanded in the list, by UID. Lives here so it survives the popup closing.
    property var expandedRules: ({})

    readonly property var cfg: Plasmoid.configuration
    readonly property var filters: G.filtersFromConfig({
        filterShowPending: cfg.filterShowPending, filterHideSilenced: cfg.filterHideSilenced,
        filterMinSeverity: cfg.filterMinSeverity, filterIncludeFolders: cfg.filterIncludeFolders,
        filterExcludeFolders: cfg.filterExcludeFolders, filterExcludeGroups: cfg.filterExcludeGroups,
        filterExcludeRules: cfg.filterExcludeRules, filterHiddenRuleUIDs: cfg.filterHiddenRuleUIDs,
        filterIncludeLabels: cfg.filterIncludeLabels, filterExcludeLabels: cfg.filterExcludeLabels
    })
    readonly property int refreshSeconds: Math.max(15, cfg.refreshInterval)
    readonly property string accountKey: cfg.authMode + "|" + cfg.serverURL + "|" + cfg.basicUser

    /// The badge number: rules (or instances) with an active alert that passes the filters.
    readonly property int badgeCount: G.badgeCount(shown, cfg.countMode)
    readonly property int pendingCount: G.pendingCount(shown)
    /// Worst severity among counted alerts (0–3), or null.
    readonly property var worstSeverity: G.worstSeverity(shown)
    readonly property bool stale: lastFetched > 0
        && now - lastFetched > Math.max(refreshSeconds * 3, 5 * 60) * 1000
    readonly property string serverURL: credential ? credential.baseURL : ""

    /// "ok" | "loading" | "error", for the panel icon (MenuBarModel.make).
    readonly property string iconState: {
        if (error && (lastFetched === 0 || error.kind === "notConfigured")) return "error"
        if (lastFetched === 0) return "loading"
        // A brief network blip with recent data isn't worth flagging; auth problems and stale data are.
        if (error) return error.kind === "network" && !stale ? "ok" : "error"
        return "ok"
    }

    readonly property bool planar: Plasmoid.formFactor === PlasmaCore.Types.Planar
        || Plasmoid.formFactor === PlasmaCore.Types.MediaCenter

    function severityColor(sev) {
        if (sev === 2) return Kirigami.Theme.neutralTextColor
        if (sev === 1) return infoColor
        return Kirigami.Theme.negativeTextColor
    }
    readonly property color infoColor: "#3daee9"
    readonly property color reasonColor: "#9b59b6"

    /// The badge's fill: the worst severity, or red when severity colors are off.
    readonly property color badgeColor: cfg.severityColors && worstSeverity !== null
        ? severityColor(worstSeverity) : Kirigami.Theme.negativeTextColor

    onFiltersChanged: if (hasLoadedOnce) {
        applyFilters()
        // New filters shouldn't read as alerts starting or resolving.
        announced = G.currentlyActive(shown)
    }
    /// The account the current state belongs to. accountKeyChanged also fires while the config
    /// loads at startup, so compare values rather than resetting on every signal.
    property string appliedAccountKey: ""
    onAccountKeyChanged: if (accountKey !== appliedAccountKey) accountChangeTimer.restart()

    Timer {
        // Typing a server URL or username changes the config on every keystroke; wait for it to settle.
        id: accountChangeTimer
        interval: 800
        onTriggered: if (root.accountKey !== root.appliedAccountKey) root.accountChanged()
    }

    // MARK: - Representations

    Plasmoid.icon: "dialog-warning"
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.status: PlasmaCore.Types.ActiveStatus

    preferredRepresentation: planar ? fullRepresentation : compactRepresentation
    compactRepresentation: CompactRepresentation {}
    fullRepresentation: PopupView {}

    toolTipMainText: i18n("Grafana Alerts")
    toolTipSubText: {
        if (error) return error.title
        if (lastFetched === 0) return i18n("Loading…")
        const noun = cfg.countMode === "instances"
            ? i18np("%1 firing alert instance", "%1 firing alert instances", badgeCount)
            : i18np("%1 firing alert", "%1 firing alerts", badgeCount)
        const hiddenText = hidden.length ? i18n(" · %1 filtered", hidden.length) : ""
        return (badgeCount === 0 ? i18n("Nothing firing") : noun) + hiddenText
    }
    toolTipTextFormat: Text.PlainText

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Open Firing Alerts in Browser")
            icon.name: "globe"
            enabled: root.serverURL !== ""
            onTriggered: root.openURL(G.firingListURL(root.serverURL))
        },
        PlasmaCore.Action {
            text: i18n("Open Silences in Browser")
            icon.name: "notifications-disabled"
            enabled: root.serverURL !== ""
            onTriggered: root.openURL(G.silencesURL(root.serverURL))
        }
    ]

    onExpandedChanged: () => {
        if (expanded && (lastFetched === 0 || Date.now() - lastFetched > 15000)) refresh(false)
    }

    // MARK: - Credentials (Auth.swift)

    Shell { id: shell }

    /// Resolves to a credential or rejects with an error (CredentialProvider.current).
    /// Settings first; falls back to GRAFANA_URL + GRAFANA_SERVICE_ACCOUNT_TOKEN in plasmashell's environment.
    function loadCredential() {
        const base = G.normalizeServer(cfg.serverURL)
        const fromEnv = () => shell.readEnvironment().then(env => env
            ? { baseURL: env.baseURL, authorization: "Bearer " + env.token, source: i18n("Environment (GRAFANA_URL)") }
            : null)
        if (!base) return fromEnv().then(c => { if (!c) throw G.apiError("notConfigured"); return c })

        if (cfg.authMode === "none")
            return Promise.resolve({ baseURL: base, authorization: null, source: i18n("Anonymous") })
        if (cfg.authMode === "basic") {
            const user = cfg.basicUser.trim()
            if (!user) return Promise.reject(G.apiError("notConfigured"))
            return shell.lookupSecret(G.passwordAccount(base)).then(password => {
                if (!password) throw G.apiError("notConfigured")
                return { baseURL: base, authorization: G.basicAuth(user, password), source: i18n("Basic auth as %1", user) }
            })
        }
        return shell.lookupSecret(G.tokenAccount(base)).then(token => {
            if (token.trim()) return { baseURL: base, authorization: "Bearer " + token.trim(), source: i18n("Service account token") }
            return fromEnv().then(c => {
                if (c && c.baseURL === base) return c
                throw G.apiError("notConfigured")
            })
        })
    }

    function currentCredential() {
        if (credential) return Promise.resolve(credential)
        const started = generation
        return loadCredential().then(c => {
            if (started !== generation) throw G.apiError("cancelled")
            credential = c
            return c
        })
    }

    // MARK: - HTTP (GrafanaAPI.swift)

    property var inflight: []

    /// Resolves to the response text. `body` (an object) is sent as JSON.
    function request(cred, method, path, query, body) {
        const url = G.joinURL(cred.baseURL, path, query)
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest()
            const entry = { xhr: xhr, started: Date.now(), done: false, reject: reject }
            inflight = inflight.concat([entry])
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE || entry.done) return
                entry.done = true
                inflight = inflight.filter(e => e !== entry)
                const err = G.errorForStatus(xhr.status, xhr.responseText)
                if (err) reject(err)
                else resolve(xhr.responseText)
            }
            xhr.open(method, url)
            if (cred.authorization) xhr.setRequestHeader("Authorization", cred.authorization)
            xhr.setRequestHeader("Accept", "application/json")
            xhr.setRequestHeader("User-Agent", "GrafanaAlerts/kde")
            if (body !== undefined) {
                xhr.setRequestHeader("Content-Type", "application/json")
                xhr.send(JSON.stringify(body))
            } else {
                xhr.send()
            }
        })
    }

    Timer {
        // QML's XMLHttpRequest has no timeout; abort anything older than 20 seconds.
        interval: 2000
        repeat: true
        running: root.inflight.length > 0
        onTriggered: {
            const cutoff = Date.now() - 20000
            root.inflight.filter(e => e.started < cutoff).forEach(e => {
                e.done = true
                e.xhr.abort()
                e.reject(G.apiError("network", i18n("The request timed out.")))
            })
            root.inflight = root.inflight.filter(e => !e.done)
        }
    }

    /// Rules with firing/pending/… instances, stepping down the state list for older Grafana.
    function fetchRules(cred) {
        const attempt = index => request(cred, "GET", "api/prometheus/grafana/api/v1/rules", { state: G.STATE_SETS[index] })
            .then(text => {
                const sets = Object.assign({}, acceptedStateSet)
                sets[cred.baseURL] = { index: index, at: Date.now() }
                acceptedStateSet = sets
                return G.parseRules(text)
            }, err => {
                if (G.shouldStepDown(err, index)) return attempt(index + 1)
                throw err
            })
        return attempt(G.stateSetIndex(acceptedStateSet[cred.baseURL], Date.now()))
    }

    /// Silenced/inhibited instance IDs, or null if Alertmanager didn't answer.
    function fetchSuppressed(cred) {
        return request(cred, "GET", "api/alertmanager/grafana/api/v2/alerts",
                       { active: "true", silenced: "true", inhibited: "true" })
            .then(G.parseSuppressed)
            .catch(err => {
                console.warn("grafana-alerts: alertmanager lookup failed:", err.kind, err.detail || err.message)
                return null
            })
    }

    // MARK: - Refresh

    function refresh(userInitiated) {
        if (refreshing) {
            if (userInitiated) refreshQueued = true
            return
        }
        refreshing = true
        const started = generation
        const finish = () => {
            now = Date.now()
            // accountChanged() already reset this and may have started a newer refresh.
            if (started !== generation) return
            refreshing = false
            if (refreshQueued) {
                refreshQueued = false
                Qt.callLater(() => refresh(true))
            }
        }
        // Re-read the keyring every poll (it's cheap), so a removed or replaced secret takes effect.
        loadCredential().then(cred => {
            if (started !== generation) throw G.apiError("cancelled")
            credential = cred
            credentialSource = cred.source
            return Promise.all([fetchRules(cred), fetchSuppressed(cred)]).then(results => {
                if (started !== generation) return
                const suppressed = results[1]
                // If Alertmanager didn't answer, keep the last known silence state rather than
                // flipping every silenced alert back to firing (and announcing it).
                rules = G.applySilences(results[0], suppressed || G.silencedIDs(rules))
                silenceWarning = suppressed === null
                    ? i18n("Couldn't read silences from Alertmanager; showing the last known silences.") : ""
                lastFetched = Date.now()
                error = null
                applyFilters()
                // Without silence info, newly silenced alerts would look new: wait for the next poll.
                // (On the very first poll, still record the baseline so nothing is announced later as new.)
                if (suppressed !== null) announce()
                else if (!hasLoadedOnce) announced = G.currentlyActive(shown)
                if (!hasLoadedOnce) writeStats()
                hasLoadedOnce = true
                if (!version) loadVersion(cred, started)
            })
        }).catch(err => {
            if (started !== generation || err.kind === "cancelled") return
            console.warn("grafana-alerts: refresh failed:", err.kind, err.detail || err.message)
            // Without a credential (it was removed, or the keyring failed) nothing else may use the old one.
            if (err.kind === "notConfigured" || err.kind === "keyring" || err.kind === "unauthorized") credential = null
            error = G.errorInfo(err.kind ? err : G.apiError("network", String(err)))
        }).then(finish)
    }

    function loadVersion(cred, started) {
        request(cred, "GET", "api/health").then(text => {
            if (started === generation) version = G.parseVersion(text) || "?"
        }).catch(() => {})
    }

    function applyFilters() {
        const p = G.partition(rules, filters)
        shown = p.shown
        hidden = p.hidden
        saveStats()
    }

    function announce() {
        const current = G.currentlyActive(shown)
        const previous = announced
        announced = current
        if (!hasLoadedOnce) return
        const a = G.announcements(previous, current, shown, rules)
        if (cfg.notifyFiring && a.firing.length) {
            if (a.firing.length > 4) {
                postNotification(i18n("%1 alerts started firing", a.firing.length),
                                 a.firing.slice(0, 4).map(f => f.rule.name).join("\n"), "", true)
            } else {
                a.firing.forEach(f => {
                    const t = G.firingText(f.rule, f.instances)
                    const critical = f.instances.some(i => (G.severity(i.labels.severity) || 3) === 3)
                    postNotification(t.title, t.text, f.rule.uid, critical)
                })
            }
        }
        if (cfg.notifyResolved) {
            a.resolved.slice(0, 5).forEach(r => {
                const text = r.instances.length === 1 ? (G.summaryOf(r.instances[0].annotations) || "")
                    : i18n("%1 instances resolved", r.instances.length)
                postNotification(i18n("✅ Resolved: %1", r.name), text, r.ruleUID, false)
            })
        }
    }

    Component {
        id: notificationComponent
        Notification {
            id: note
            property string ruleUID: ""
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "dialog-warning"
            autoDelete: true
            defaultAction: NotificationAction {
                label: i18n("Open in Grafana")
                onActivated: root.openURL(note.ruleUID ? G.ruleURL(root.serverURL, note.ruleUID)
                                                       : G.firingListURL(root.serverURL))
            }
        }
    }

    function postNotification(title, text, ruleUID, urgent) {
        const n = notificationComponent.createObject(root, {
            title: title, text: text, ruleUID: ruleUID,
            urgency: urgent ? Notification.HighUrgency : Notification.NormalUrgency
        })
        if (n) n.sendEvent()
    }

    // MARK: - Actions

    function openURL(url) {
        if (url) Qt.openUrlExternally(url)
        root.expanded = false
    }

    function openRule(uid) { openURL(G.ruleURL(serverURL, uid)) }

    function toggleExpanded(uid) {
        const next = Object.assign({}, expandedRules)
        if (next[uid]) delete next[uid]
        else next[uid] = true
        expandedRules = next
    }

    /// Silences a whole rule, or one instance (AlertStore.silence).
    function silence(rule, instance, seconds) {
        const started = generation
        const what = instance ? G.labelText(G.distinguishingLabels(instance, G.commonLabels(rule)), ", ") : ""
        const comment = "Silenced from the Grafana Alerts Plasma widget" + (what ? " (" + what + ")" : "")
        currentCredential().then(cred => request(cred, "POST", "api/alertmanager/grafana/api/v2/silences", null,
                G.silenceBody(rule.uid, instance ? instance.labels : null, seconds, comment, Date.now())))
            .then(() => {
                if (started !== generation) return
                showSilenceMessage(i18n("Silenced %1 for %2.", rule.name, G.duration(seconds)))
                refresh(true)
            }, err => {
                if (started !== generation || err.kind === "cancelled") return
                showSilenceMessage(err.kind === "forbidden"
                    ? i18n("Couldn't silence: the token needs permission to create silences (Editor role, or alert.silences:create).")
                    : i18n("Couldn't silence: %1", G.errorInfo(err).message))
            })
    }

    function showSilenceMessage(text) {
        silenceMessage = text
        silenceMessageTimer.restart()
    }

    Timer {
        id: silenceMessageTimer
        interval: 8000
        onTriggered: root.silenceMessage = ""
    }

    /// The right-click "Hide …" actions.
    function hideRule(rule) { cfg.filterHiddenRuleUIDs = G.appendPattern(cfg.filterHiddenRuleUIDs, rule.uid) }
    function hideFolder(rule) { cfg.filterExcludeFolders = G.appendPattern(cfg.filterExcludeFolders, G.globLiteral(rule.folder)) }
    function hideGroup(rule) {
        cfg.filterExcludeGroups = G.appendPattern(cfg.filterExcludeGroups, G.globLiteral(rule.folder + "/" + rule.group))
    }

    /// Server or credentials changed: start over.
    function accountChanged() {
        appliedAccountKey = accountKey
        generation += 1
        credential = null
        rules = []
        shown = []
        hidden = []
        announced = ({})
        hasLoadedOnce = false
        lastFetched = 0
        version = ""
        error = null
        silenceWarning = ""
        credentialSource = ""
        refreshing = false
        refreshQueued = false
        saveStats()
        refresh(true)
    }

    // MARK: - Stats for the settings pages (folder/label suggestions, hidden reasons)

    /// Written to the applet's config (the only place the settings pages can read), so at most once
    /// a minute, and only when something changed.
    function saveStats() { if (!statsTimer.running) statsTimer.start() }

    Timer {
        id: statsTimer
        interval: 60000
        onTriggered: root.writeStats()
    }

    function writeStats() {
        const values = G.suggestionValues(rules)
        const text = JSON.stringify({
            folders: G.topCounts(values.folders, [], 40),
            labels: G.topCounts(values.labels, [], 40),
            shown: shown.length,
            hidden: hidden.length,
            reasons: G.topReasons(hidden)
        })
        if (text !== cfg.listStats) cfg.listStats = text
    }

    // MARK: - Timers

    Timer {
        interval: root.refreshSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.refresh(false)
    }

    Timer {
        // Keeps "5m" current, and notices resume from suspend (a big gap between ticks).
        interval: 30000
        repeat: true
        running: true
        onTriggered: {
            const t = Date.now()
            const slept = t - root.lastTick > 90000
            root.lastTick = t
            root.now = t
            if (slept) wakeTimer.restart()
        }
    }

    Timer {
        id: wakeTimer
        interval: 5000 // give the network a moment after resume
        onTriggered: root.refresh(false)
    }

    Component.onCompleted: {
        appliedAccountKey = accountKey
        refresh(false)
    }
}
