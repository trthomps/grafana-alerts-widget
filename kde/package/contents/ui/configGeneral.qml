import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property string cfg_iconColor
    property string cfg_badgeStyle
    property bool cfg_severityColors
    property string cfg_countMode
    property bool cfg_dimWhenEmpty
    property int cfg_refreshInterval
    property bool cfg_notifyFiring
    property bool cfg_notifyResolved

    component Choice: QQC2.ComboBox {
        required property string current
        signal picked(var value)
        textRole: "text"
        valueRole: "value"
        Component.onCompleted: currentIndex = Math.max(0, indexOfValue(current))
        onActivated: picked(currentValue)
    }

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    Kirigami.FormLayout {
        Choice {
            Kirigami.FormData.label: i18n("Icon:")
            current: page.cfg_iconColor
            model: [
                { value: "color", text: i18n("Grafana colors") },
                { value: "monochrome", text: i18n("Monochrome (follows the panel's text color)") }
            ]
            onPicked: value => page.cfg_iconColor = value
        }

        Choice {
            Kirigami.FormData.label: i18n("Firing count:")
            current: page.cfg_badgeStyle
            model: [
                { value: "badge", text: i18n("Badge on the icon") },
                { value: "number", text: i18n("Number next to the icon") },
                { value: "dot", text: i18n("Dot") },
                { value: "none", text: i18n("None") }
            ]
            onPicked: value => page.cfg_badgeStyle = value
        }

        Choice {
            Kirigami.FormData.label: i18n("Count:")
            current: page.cfg_countMode
            model: [
                { value: "rules", text: i18n("Firing rules") },
                { value: "instances", text: i18n("Firing instances") }
            ]
            onPicked: value => page.cfg_countMode = value
        }
        Note {
            text: i18n("A rule firing for 5 hosts is 1 rule, 5 instances. Grafana's alert list counts rules.")
        }

        QQC2.CheckBox {
            text: i18n("Color the count by severity (critical red, warning orange)")
            checked: page.cfg_severityColors
            onToggled: page.cfg_severityColors = checked
        }

        QQC2.CheckBox {
            text: i18n("Dim the icon when nothing is firing")
            checked: page.cfg_dimWhenEmpty
            onToggled: page.cfg_dimWhenEmpty = checked
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("When an alert starts firing")
            checked: page.cfg_notifyFiring
            onToggled: page.cfg_notifyFiring = checked
        }
        QQC2.CheckBox {
            text: i18n("When an alert resolves")
            checked: page.cfg_notifyResolved
            onToggled: page.cfg_notifyResolved = checked
        }
        Note {
            text: i18n("Only for alerts that pass your filters, and not for silenced ones. Click one to open the rule in Grafana. Sounds and popups follow System Settings → Notifications.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Refresh every:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: 15, text: i18n("15 seconds") },
                { value: 30, text: i18n("30 seconds") },
                { value: 60, text: i18n("1 minute") },
                { value: 120, text: i18n("2 minutes") },
                { value: 300, text: i18n("5 minutes") }
            ]
            Component.onCompleted: {
                const i = indexOfValue(page.cfg_refreshInterval)
                currentIndex = i >= 0 ? i : 2
            }
            onActivated: page.cfg_refreshInterval = currentValue
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: i18n("Middle-click the panel icon to refresh. Right-click an alert to open its runbook or dashboard, silence it, or hide it.")
        }
    }
}
