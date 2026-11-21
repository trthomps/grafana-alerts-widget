import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/grafana.js" as G

// One alert rule (RuleRow in PopoverView.swift) and, when expanded, its instances. Click opens the
// rule in Grafana; the chevron shows instances; right-click to silence, hide or copy.
ColumnLayout {
    id: row

    property var item: null              // G.makeItem
    property bool dimmed: false
    property string sectionTitle: ""
    readonly property var rule: item ? item.rule : null
    readonly property bool expanded: !!item && !!root.expandedRules[item.id]
    readonly property bool canExpand: !!item && item.instances.length > 0

    spacing: 0

    PlasmaComponents.Label {
        visible: row.sectionTitle !== ""
        Layout.fillWidth: true
        leftPadding: Kirigami.Units.largeSpacing
        topPadding: Kirigami.Units.largeSpacing
        bottomPadding: Kirigami.Units.smallSpacing
        text: row.sectionTitle.toUpperCase()
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        font.weight: Font.DemiBold
        opacity: 0.7
    }

    MouseArea {
        id: area
        Layout.fillWidth: true
        implicitHeight: content.implicitHeight + Kirigami.Units.smallSpacing * 3
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) menu.openFor(null)
            else root.openRule(row.rule.uid)
        }

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.highlightColor
            opacity: area.containsMouse ? 0.15 : 0
        }

        RowLayout {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.rightMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing
            opacity: row.dimmed ? 0.6 : 1

            StateIcon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 2
                alertState: row.item ? row.item.state : "normal"
                severity: row.item ? row.item.severity : 0
                silenced: !!row.item && row.item.allSilenced
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        text: row.rule ? row.rule.name : ""
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.weight: Font.DemiBold
                        opacity: row.item && G.isActive(row.item.state) && !row.item.allSilenced ? 1 : 0.7
                    }
                    PlasmaComponents.Label {
                        Layout.alignment: Qt.AlignTop
                        visible: !!row.item && row.item.since !== null
                        text: row.item && row.item.since !== null ? G.ago(row.item.since, root.now, true) : ""
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.features: { "tnum": 1 }
                        opacity: 0.7
                    }
                }

                PlasmaComponents.Label {
                    visible: text !== ""
                    Layout.fillWidth: true
                    text: row.item && row.item.summary ? row.item.summary : ""
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font: Kirigami.Theme.smallFont
                    opacity: 0.75
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: row.rule ? row.rule.folder + " › " + row.rule.group : ""
                        elide: Text.ElideMiddle
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        Layout.fillWidth: true
                        Layout.maximumWidth: implicitWidth
                    }
                    PlasmaComponents.ToolButton {
                        visible: row.canExpand
                        flat: true
                        padding: 0
                        implicitHeight: Kirigami.Units.iconSizes.small + 2
                        icon.name: row.expanded ? "arrow-down" : "arrow-right"
                        icon.width: Kirigami.Units.iconSizes.small * 0.75
                        icon.height: Kirigami.Units.iconSizes.small * 0.75
                        text: row.item && (row.item.instances.length > 1 || row.item.hiddenInstances > 0)
                            ? i18np("%1 instance", "%1 instances", row.item.instances.length) : ""
                        display: text ? QQC2.AbstractButton.TextBesideIcon : QQC2.AbstractButton.IconOnly
                        font: Kirigami.Theme.smallFont
                        onClicked: root.toggleExpanded(row.item.id)
                        PlasmaComponents.ToolTip {
                            text: row.expanded ? i18n("Hide instances")
                                : row.item && row.item.instances.length > 1 ? i18n("Show instances") : i18n("Show labels")
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Pill {
                        visible: !!row.item && row.item.allSilenced
                        small: true
                        text: i18n("silenced")
                        tint: Kirigami.Theme.disabledTextColor
                    }
                    Pill {
                        visible: !!row.item && row.item.state === "pending"
                        small: true
                        text: i18n("pending")
                        tint: Kirigami.Theme.neutralTextColor
                    }
                    Pill {
                        visible: !!row.item && row.item.state === "recovering"
                        small: true
                        text: i18n("recovering")
                        tint: Kirigami.Theme.positiveTextColor
                    }
                    Pill {
                        visible: !!row.item && row.item.reason !== null
                        small: true
                        text: row.item && row.item.reason ? row.item.reason : ""
                        tint: root.reasonColor
                    }
                    Pill {
                        visible: !!row.item && !!row.item.severityLabel
                        small: true
                        text: row.item && row.item.severityLabel ? row.item.severityLabel : ""
                        tint: row.item && row.item.severity > 0 ? root.severityColor(row.item.severity)
                                                                 : Kirigami.Theme.disabledTextColor
                    }
                    Pill {
                        visible: !!row.item && row.item.hiddenReason !== null
                        small: true
                        text: row.item && row.item.hiddenReason ? row.item.hiddenReason : ""
                        tint: Kirigami.Theme.disabledTextColor
                    }
                }
            }
        }

        PlasmaComponents.ToolTip {
            text: i18n("Open in Grafana. Right-click to silence.")
            visible: area.containsMouse
            delay: Kirigami.Units.toolTipDelay * 2
        }
    }

    // MARK: Instances

    Repeater {
        model: row.expanded ? row.item.instances : []

        delegate: MouseArea {
            id: instanceArea
            required property var modelData
            readonly property var instance: modelData
            readonly property var labels: G.distinguishingLabels(instance, row.item.common)
            Layout.fillWidth: true
            implicitHeight: instanceContent.implicitHeight + Kirigami.Units.smallSpacing * 2
            hoverEnabled: true
            acceptedButtons: Qt.RightButton
            onClicked: menu.openFor(instance)

            Rectangle {
                anchors.fill: parent
                color: Kirigami.Theme.highlightColor
                opacity: instanceArea.containsMouse ? 0.08 : 0
            }

            RowLayout {
                id: instanceContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Kirigami.Units.largeSpacing * 2 + Kirigami.Units.iconSizes.small
                anchors.rightMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing
                opacity: row.dimmed ? 0.6 : 1

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    width: 6
                    height: 6
                    radius: 3
                    color: instanceArea.instance.silenced ? Kirigami.Theme.disabledTextColor
                        : instanceArea.instance.state === "pending" ? Kirigami.Theme.neutralTextColor
                        : root.severityColor(G.severity(instanceArea.instance.labels.severity))
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    PlasmaComponents.Label {
                        visible: text !== ""
                        Layout.fillWidth: true
                        text: G.summaryOf(instanceArea.instance.annotations) || ""
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        font: Kirigami.Theme.smallFont
                    }
                    PlasmaComponents.Label {
                        visible: instanceArea.labels.length > 0
                        Layout.fillWidth: true
                        text: G.labelText(instanceArea.labels)
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.family: "monospace"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        opacity: 0.7
                    }
                }

                ColumnLayout {
                    Layout.alignment: Qt.AlignTop
                    spacing: 1
                    PlasmaComponents.Label {
                        Layout.alignment: Qt.AlignRight
                        visible: instanceArea.instance.activeAt !== null
                        text: instanceArea.instance.activeAt !== null ? G.ago(instanceArea.instance.activeAt, root.now, true) : ""
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.features: { "tnum": 1 }
                        opacity: 0.7
                    }
                    PlasmaComponents.Label {
                        Layout.alignment: Qt.AlignRight
                        visible: text !== ""
                        text: instanceArea.instance.silenced ? i18n("silenced")
                            : instanceArea.instance.state !== "firing" ? G.stateTitles[instanceArea.instance.state].toLowerCase() : ""
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        opacity: 0.7
                    }
                }
            }

            PlasmaComponents.ToolTip {
                text: instanceArea.instance.value ? i18n("Value: %1", instanceArea.instance.value) : ""
                visible: instanceArea.containsMouse && text !== ""
                delay: Kirigami.Units.toolTipDelay * 2
            }
        }
    }

    PlasmaComponents.Label {
        visible: row.expanded && row.item.hiddenInstances > 0
        Layout.fillWidth: true
        leftPadding: Kirigami.Units.largeSpacing * 2 + Kirigami.Units.iconSizes.small
        bottomPadding: Kirigami.Units.smallSpacing
        text: row.item ? i18np("%1 more hidden by filters", "%1 more hidden by filters", row.item.hiddenInstances) : ""
        font: Kirigami.Theme.smallFont
        opacity: 0.5
    }

    Kirigami.Separator {
        Layout.fillWidth: true
        Layout.leftMargin: Kirigami.Units.largeSpacing * 2 + Kirigami.Units.iconSizes.small
        opacity: 0.5
    }

    // MARK: Menu (RuleMenu in PopoverView.swift)

    component DurationMenu: PlasmaComponents.Menu {
        id: durations
        /// The instance to silence, or null for the whole rule.
        property var target: null
        PlasmaComponents.MenuItem { text: i18n("For 1 hour"); onTriggered: root.silence(row.rule, durations.target, 3600) }
        PlasmaComponents.MenuItem { text: i18n("For 4 hours"); onTriggered: root.silence(row.rule, durations.target, 4 * 3600) }
        PlasmaComponents.MenuItem { text: i18n("For 1 day"); onTriggered: root.silence(row.rule, durations.target, 86400) }
        PlasmaComponents.MenuItem { text: i18n("For 1 week"); onTriggered: root.silence(row.rule, durations.target, 7 * 86400) }
    }

    /// A menu item that takes no space when hidden (QQC2 menus otherwise leave a gap).
    component OptionalItem: PlasmaComponents.MenuItem {
        height: visible ? implicitHeight : 0
    }

    PlasmaComponents.Menu {
        id: menu
        /// The right-clicked instance, or null for the rule row.
        property var instance: null
        readonly property string runbook: row.rule ? (G.runbookURL(row.rule, instance) || "") : ""
        readonly property string dashboard: row.rule ? (G.dashboardURL(root.serverURL, row.rule) || "") : ""

        function openFor(inst) {
            instance = inst
            // Sub-menus can't be hidden with a binding; hide "Silence Whole Rule" on rule rows by hand.
            for (let i = 0; i < count; i++) {
                const it = itemAt(i)
                if (it && it.subMenu === wholeRuleMenu) {
                    it.visible = inst !== null
                    it.height = inst !== null ? it.implicitHeight : 0
                }
            }
            popup()
        }

        PlasmaComponents.MenuItem {
            text: i18n("Open in Grafana")
            icon.name: "globe"
            onTriggered: root.openRule(row.rule.uid)
        }
        OptionalItem {
            visible: menu.runbook !== ""
            text: i18n("Open Runbook")
            icon.name: "documentation"
            onTriggered: root.openURL(menu.runbook)
        }
        OptionalItem {
            visible: menu.dashboard !== ""
            text: i18n("Open Dashboard Panel")
            icon.name: "office-chart-line"
            onTriggered: root.openURL(menu.dashboard)
        }
        PlasmaComponents.MenuSeparator {}
        DurationMenu {
            title: menu.instance ? i18n("Silence This Instance") : i18n("Silence Rule")
            icon.name: "notifications-disabled"
            target: menu.instance
        }
        DurationMenu {
            id: wholeRuleMenu
            title: i18n("Silence Whole Rule")
            icon.name: "notifications-disabled"
            target: null
        }
        PlasmaComponents.MenuSeparator {}
        PlasmaComponents.MenuItem {
            text: i18n("Hide This Rule")
            icon.name: "view-hidden"
            onTriggered: root.hideRule(row.rule)
        }
        PlasmaComponents.MenuItem {
            text: row.rule ? i18n("Hide Folder “%1”", row.rule.folder) : ""
            icon.name: "view-hidden"
            onTriggered: root.hideFolder(row.rule)
        }
        PlasmaComponents.MenuItem {
            text: row.rule ? i18n("Hide Group “%1”", row.rule.group) : ""
            icon.name: "view-hidden"
            onTriggered: root.hideGroup(row.rule)
        }
        PlasmaComponents.MenuSeparator {}
        PlasmaComponents.MenuItem {
            text: i18n("Copy Name")
            icon.name: "edit-copy"
            onTriggered: row.copy(row.rule.name)
        }
        OptionalItem {
            visible: menu.instance !== null
            text: i18n("Copy Labels")
            icon.name: "edit-copy"
            onTriggered: {
                const labels = menu.instance.labels
                row.copy(Object.keys(labels).filter(k => k.indexOf("__") !== 0).sort()
                    .map(k => k + "=" + labels[k]).join("\n"))
            }
        }
    }

    function copy(text) {
        clip.text = text
        clip.selectAll()
        clip.copy()
    }

    // Clipboard access without extra modules.
    TextEdit { id: clip; visible: false }
}
