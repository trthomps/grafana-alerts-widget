import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/grafana.js" as G

KCM.SimpleKCM {
    id: page

    property string cfg_authMode
    property string cfg_serverURL
    property string cfg_basicUser

    readonly property string server: G.normalizeServer(cfg_serverURL) || ""
    readonly property string account: cfg_authMode === "basic" ? G.passwordAccount(server) : G.tokenAccount(server)
    readonly property string secretName: cfg_authMode === "basic" ? i18n("password") : i18n("token")
    /// null while unknown, else whether the keyring has a secret for this server and mode.
    property var hasSecret: null
    property var env: null
    property string status: ""
    property bool statusOK: false
    property bool checking: false
    property var checkXHRs: []
    property int checkSeq: 0

    onAccountChanged: refreshSecretState()
    onCfg_authModeChanged: status = ""

    Shell { id: shell }

    Timer {
        // Covers a hung keyring lookup and a server that never answers.
        id: checkTimeout
        interval: 30000
        onTriggered: {
            page.checkXHRs.forEach(x => x.abort())
            page.checkXHRs = []
            page.checkSeq += 1
            page.fail(i18n("Timed out. Check the server address and your network."))
        }
    }

    Timer {
        // The server field changes on every keystroke; look the secret up once typing pauses.
        id: secretTimer
        interval: 600
        onTriggered: {
            const account = page.account
            if (!page.server || page.cfg_authMode === "none") { page.hasSecret = null; return }
            shell.lookupSecret(account).then(s => { if (account === page.account) page.hasSecret = s !== "" })
        }
    }

    function refreshSecretState() {
        hasSecret = null
        secretTimer.restart()
    }

    Component.onCompleted: {
        shell.readEnvironment().then(e => { env = e })
        refreshSecretState()
    }

    function fail(message) {
        checkTimeout.stop()
        status = message
        statusOK = false
        checking = false
    }

    function get(base, authorization, path, query) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest()
            checkXHRs = checkXHRs.concat([xhr])
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                const err = G.errorForStatus(xhr.status, xhr.responseText)
                if (err) reject(err)
                else resolve(xhr.responseText)
            }
            xhr.open("GET", G.joinURL(base, path, query))
            if (authorization) xhr.setRequestHeader("Authorization", authorization)
            xhr.setRequestHeader("Accept", "application/json")
            xhr.send()
        })
    }

    /// Signs in the same way the widget does, then reads the version and the firing rules.
    function check() {
        checking = true
        status = ""
        const seq = ++checkSeq
        checkTimeout.restart()
        const failIfCurrent = message => { if (seq === checkSeq) fail(message) }

        let auth
        let base = server
        if (!base && env) {
            base = env.baseURL
            auth = Promise.resolve("Bearer " + env.token)
        } else if (!base) {
            failIfCurrent(i18n("Enter your Grafana server's address."))
            return
        } else if (cfg_authMode === "none") {
            auth = Promise.resolve(null)
        } else if (cfg_authMode === "basic") {
            if (!cfg_basicUser.trim()) { failIfCurrent(i18n("Enter your Grafana username.")); return }
            auth = shell.lookupSecret(G.passwordAccount(base)).then(p => {
                if (!p) throw new Error(i18n("No password stored for %1 yet. Run the command above.", base))
                return G.basicAuth(cfg_basicUser.trim(), p)
            })
        } else {
            auth = shell.lookupSecret(G.tokenAccount(base)).then(t => {
                if (t.trim()) return "Bearer " + t.trim()
                if (env && env.baseURL === base) return "Bearer " + env.token
                throw new Error(i18n("No token stored for %1 yet. Run the command above.", base))
            })
        }

        auth.then(authorization => {
            if (seq !== checkSeq) return
            const health = get(base, authorization, "api/health").then(G.parseVersion, () => null)
            const rules = get(base, authorization, "api/prometheus/grafana/api/v1/rules", { state: "firing" }).then(G.parseRules)
            return Promise.all([health, rules]).then(r => {
                if (seq !== checkSeq) return
                checkTimeout.stop()
                checkXHRs = []
                const firing = r[1].filter(rule => G.isActive(rule.state)).length
                status = (r[0] ? i18n("Connected to Grafana %1 at %2.", r[0], base) : i18n("Connected to %1.", base))
                    + " " + i18np("%1 rule firing.", "%1 rules firing.", firing)
                statusOK = true
                checking = false
            })
        }).catch(err => {
            if (seq !== checkSeq) return
            checkXHRs = []
            if (err.kind) {
                const info = G.errorInfo(err)
                failIfCurrent(info.title + ". " + info.message)
            } else {
                failIfCurrent(err.message)
            }
        })
    }

    function clearSecret() {
        shell.run(shell.clearCommand(account)).then(() => refreshSecretState())
    }

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    Kirigami.FormLayout {
        QQC2.TextField {
            Kirigami.FormData.label: i18n("Grafana URL:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 18
            placeholderText: page.env ? page.env.baseURL : "https://grafana.example.com"
            text: page.cfg_serverURL
            onTextEdited: { page.cfg_serverURL = text.trim(); page.status = "" }
        }
        Note {
            visible: page.cfg_serverURL.trim() !== "" && page.server !== page.cfg_serverURL.trim()
            text: page.server ? i18n("Uses %1", page.server) : i18n("That doesn't look like a web address.")
        }
        Note {
            visible: page.cfg_serverURL.trim() === "" && page.env !== null
            text: page.env ? i18n("Using %1 and its token from GRAFANA_URL until you fill this in.", page.env.baseURL) : ""
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Sign in with:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "token", text: i18n("Service account token") },
                { value: "basic", text: i18n("Username & password") },
                { value: "none", text: i18n("No auth") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_authMode))
            onActivated: page.cfg_authMode = currentValue
        }

        QQC2.TextField {
            visible: page.cfg_authMode === "basic"
            Kirigami.FormData.label: i18n("Username:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
            text: page.cfg_basicUser
            onTextEdited: { page.cfg_basicUser = text.trim(); page.status = "" }
        }

        // MARK: Storing the secret

        Note {
            visible: page.cfg_authMode === "token"
            opacity: 1
            font: Kirigami.Theme.defaultFont
            text: i18n("In Grafana: Administration → Users and access → Service accounts → Add service account. The Viewer role is enough to read alerts; Editor also lets you silence them from the widget. Then Add service account token, and store it in your keyring by running this in a terminal (it asks for the token, so it never lands in your shell history):")
        }
        Note {
            visible: page.cfg_authMode === "basic"
            opacity: 1
            font: Kirigami.Theme.defaultFont
            text: i18n("Grafana's own login (basic auth must be enabled, which it is by default). It doesn't work with SSO-only accounts; use a service account token for those. Store the password in your keyring by running this in a terminal:")
        }
        Note {
            visible: page.cfg_authMode === "none"
            opacity: 1
            font: Kirigami.Theme.defaultFont
            text: i18n("For Grafana with anonymous access enabled. The anonymous role needs to be able to read alert rules.")
        }

        RowLayout {
            visible: page.cfg_authMode !== "none"
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            QQC2.TextField {
                id: storeCommand
                Layout.fillWidth: true
                readOnly: true
                font.family: "monospace"
                text: page.server ? shell.storeCommand(page.account, "Grafana Alerts (" + page.server + ")")
                                  : i18n("Enter the Grafana URL first")
                enabled: page.server !== ""
            }
            QQC2.Button {
                icon.name: "edit-copy"
                enabled: page.server !== ""
                onClicked: { storeCommand.selectAll(); storeCommand.copy(); storeCommand.deselect() }
                QQC2.ToolTip.text: i18n("Copy")
                QQC2.ToolTip.visible: hovered
            }
        }

        RowLayout {
            visible: page.cfg_authMode !== "none" && page.server !== ""
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                source: page.hasSecret ? "checkmark" : "dialog-information"
                visible: page.hasSecret !== null
            }
            QQC2.Label {
                text: page.hasSecret === null ? i18n("Checking the keyring…")
                    : page.hasSecret ? i18n("A %1 is stored for this server.", page.secretName)
                    : i18n("No %1 stored for this server yet.", page.secretName)
            }
            QQC2.Button {
                visible: page.hasSecret === true
                text: i18n("Remove")
                icon.name: "edit-delete"
                onClicked: page.clearSecret()
            }
            QQC2.Button {
                visible: page.hasSecret !== null
                icon.name: "view-refresh"
                onClicked: page.refreshSecretState()
                QQC2.ToolTip.text: i18n("Look again")
                QQC2.ToolTip.visible: hovered
            }
        }

        QQC2.Button {
            visible: page.cfg_authMode === "token" && page.server !== ""
            text: i18n("Create Token in Grafana…")
            icon.name: "globe"
            onClicked: Qt.openUrlExternally(G.createTokenURL(page.server))
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        RowLayout {
            QQC2.Button {
                text: i18n("Test Connection")
                icon.name: "dialog-ok-apply"
                enabled: !page.checking
                onClicked: page.check()
            }
            QQC2.BusyIndicator {
                visible: page.checking
                running: visible
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredWidth: Layout.preferredHeight
            }
        }

        QQC2.Label {
            visible: page.status !== ""
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            color: page.statusOK ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
            text: page.status
        }

        Note {
            text: i18n("Secrets live in your keyring (KWallet or GNOME Keyring) through the Secret Service, and only in memory in the widget. Settings like the URL and username are in ~/.config/plasma-org.kde.plasma.desktop-appletsrc.")
        }
    }
}
