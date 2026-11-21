import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/grafana.js" as G

// The click-through list (PopoverView.swift).
PlasmaExtras.Representation {
    id: popup

    readonly property bool mono: Plasmoid.configuration.iconColor === "monochrome"
    readonly property bool showHidden: Plasmoid.configuration.showHidden
    readonly property var rows: {
        const out = root.shown.map(i => ({ item: i, dimmed: false, first: false }))
        if (showHidden) root.hidden.forEach((i, n) => out.push({ item: i, dimmed: true, first: n === 0 }))
        return out
    }
    readonly property string notice: root.error ? root.error.title + ". " + root.error.message : root.silenceWarning

    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    Layout.minimumHeight: Kirigami.Units.gridUnit * 12
    Layout.preferredHeight: Kirigami.Units.gridUnit * 28
    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Logo {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.leftMargin: Kirigami.Units.smallSpacing
                monochrome: popup.mono
                color: Kirigami.Theme.textColor
            }
            Kirigami.Heading {
                level: 4
                text: i18n("Alerts")
            }
            Pill {
                visible: root.badgeCount > 0
                text: i18n("%1 firing", root.badgeCount)
                filled: true
                tint: popup.mono ? Kirigami.Theme.disabledTextColor : root.badgeColor
                PlasmaComponents.ToolTip {
                    text: Plasmoid.configuration.countMode === "instances" ? i18n("Firing alert instances") : i18n("Firing alert rules")
                }
            }
            Pill {
                visible: root.pendingCount > 0
                text: i18n("%1 pending", root.pendingCount)
                tint: Kirigami.Theme.neutralTextColor
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.BusyIndicator {
                visible: root.refreshing
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            PlasmaComponents.ToolButton {
                visible: !root.refreshing
                icon.name: "view-refresh"
                onClicked: root.refresh(true)
                PlasmaComponents.ToolTip { text: i18n("Refresh now") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents.ToolTip { text: i18n("Settings") }
            }
        }
    }

    footer: PlasmaExtras.PlasmoidHeading {
        position: PlasmaComponents.ToolBar.Footer
        visible: root.lastFetched > 0 || root.silenceMessage !== ""
        ColumnLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                visible: root.silenceMessage !== ""
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                wrapMode: Text.WordWrap
                text: root.silenceMessage
                font: Kirigami.Theme.smallFont
                opacity: 0.8
            }

            RowLayout {
                visible: root.lastFetched > 0
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.ToolButton {
                    visible: root.hidden.length > 0
                    text: popup.showHidden ? i18n("Hide filtered") : i18np("%1 filtered", "%1 filtered", root.hidden.length)
                    icon.name: popup.showHidden ? "view-hidden" : "view-filter"
                    font: Kirigami.Theme.smallFont
                    onClicked: Plasmoid.configuration.showHidden = !popup.showHidden
                    PlasmaComponents.ToolTip { text: i18n("Alerts your filters hide. They don't count toward the badge.") }
                }
                PlasmaComponents.Label {
                    visible: root.hidden.length === 0
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    text: i18n("Updated %1", G.ago(root.lastFetched, root.now))
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    text: i18n("Open Grafana")
                    icon.name: "globe"
                    font: Kirigami.Theme.smallFont
                    enabled: root.serverURL !== ""
                    onClicked: root.openURL(G.firingListURL(root.serverURL))
                }
            }
        }
    }

    // First load, or nothing to show.
    PlasmaExtras.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 2
        visible: list.count === 0
        iconName: root.lastFetched === 0
            ? (root.error ? root.error.icon : "view-refresh")
            : "checkmark"
        text: root.lastFetched === 0
            ? (root.error ? root.error.title : i18n("Loading alerts…"))
            : i18n("Nothing firing")
        explanation: root.lastFetched === 0
            ? (root.error ? root.error.message : "")
            : [root.hidden.length ? i18np("%1 hidden by your filters", "%1 hidden by your filters", root.hidden.length) : "",
               popup.notice].filter(s => s).join("\n")
        helpfulAction: root.lastFetched === 0 && root.error
            ? (root.error.kind === "notConfigured" ? settingsAction : retryAction) : null
        QQC2.Action {
            id: retryAction
            text: i18n("Try Again")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        }
        QQC2.Action {
            id: settingsAction
            text: i18n("Settings…")
            icon.name: "configure"
            onTriggered: Plasmoid.internalAction("configure").trigger()
        }
    }

    PlasmaComponents.ScrollView {
        anchors.fill: parent
        visible: list.count > 0
        opacity: root.stale ? 0.6 : 1

        ListView {
            id: list
            model: popup.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            header: ErrorLine {
                width: ListView.view.width
                visible: popup.notice !== ""
                height: visible ? implicitHeight : 0
            }

            delegate: RuleRow {
                required property var modelData
                width: ListView.view.width
                item: modelData.item
                dimmed: modelData.dimmed
                sectionTitle: modelData.first ? i18n("Hidden by filters") : ""
            }
        }
    }

    component ErrorLine: RowLayout {
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            source: "dialog-warning"
            color: Kirigami.Theme.neutralTextColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Kirigami.Units.smallSpacing
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            text: popup.notice
        }
    }
}
