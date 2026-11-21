import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/grafana.js" as G

KCM.SimpleKCM {
    id: page

    property bool cfg_filterShowPending
    property bool cfg_filterHideSilenced
    property int cfg_filterMinSeverity
    property string cfg_filterIncludeFolders
    property string cfg_filterExcludeFolders
    property string cfg_filterExcludeGroups
    property string cfg_filterExcludeRules
    property string cfg_filterHiddenRuleUIDs
    property string cfg_filterIncludeLabels
    property string cfg_filterExcludeLabels
    property string cfg_listStats

    readonly property var stats: { try { return JSON.parse(cfg_listStats || "{}") } catch (e) { return {} } }
    readonly property var hiddenUIDs: G.patterns(cfg_filterHiddenRuleUIDs)
    /// One-click "hide" buttons for whatever is filling the list, minus what's already hidden.
    readonly property var folderChips: (stats.folders || [])
        .filter(c => !G.globAny(G.patterns(cfg_filterExcludeFolders), c.value)).slice(0, 8)
    readonly property var labelChips: (stats.labels || [])
        .filter(c => G.patterns(cfg_filterExcludeLabels).indexOf(c.value) < 0).slice(0, 8)

    function reset() {
        cfg_filterShowPending = false
        cfg_filterHideSilenced = true
        cfg_filterMinSeverity = 0
        cfg_filterIncludeFolders = ""
        cfg_filterExcludeFolders = ""
        cfg_filterExcludeGroups = ""
        cfg_filterExcludeRules = ""
        cfg_filterHiddenRuleUIDs = ""
        cfg_filterIncludeLabels = ""
        cfg_filterExcludeLabels = ""
    }

    component PatternField: QQC2.TextField {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
    }

    component Note: QQC2.Label {
        Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        wrapMode: Text.WordWrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    component Chips: Flow {
        id: chips
        property var values: []
        signal picked(string value)
        visible: values.length > 0
        Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        spacing: Kirigami.Units.smallSpacing
        Repeater {
            model: chips.values
            QQC2.Button {
                required property var modelData
                text: modelData.value + " (" + modelData.count + ")"
                icon.name: "list-remove"
                font: Kirigami.Theme.smallFont
                onClicked: chips.picked(modelData.value)
            }
        }
    }

    Kirigami.FormLayout {
        RowLayout {
            Kirigami.FormData.label: i18n("Last refresh:")
            QQC2.Label {
                text: page.stats.shown === undefined ? i18n("Not loaded yet")
                    : i18n("%1 shown · %2 hidden", page.stats.shown, page.stats.hidden)
            }
            QQC2.Button {
                text: i18n("Reset Filters")
                icon.name: "edit-reset"
                onClicked: page.reset()
            }
        }
        Note {
            visible: (page.stats.reasons || []).length > 0
            text: i18n("Hidden because: %1", (page.stats.reasons || []).map(r => r.value + " (" + r.count + ")").join(", "))
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("State") }

        QQC2.CheckBox {
            text: i18n("Show pending alerts")
            checked: page.cfg_filterShowPending
            onToggled: page.cfg_filterShowPending = checked
        }
        Note {
            text: i18n("Pending alerts have met their condition but not yet for the rule's pending period. They're listed but never counted or announced.")
        }
        QQC2.CheckBox {
            text: i18n("Hide silenced and inhibited alerts")
            checked: page.cfg_filterHideSilenced
            onToggled: page.cfg_filterHideSilenced = checked
        }
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Minimum severity:")
            model: G.severityTitles
            currentIndex: Math.max(0, Math.min(3, page.cfg_filterMinSeverity))
            onActivated: index => page.cfg_filterMinSeverity = index
        }
        Note {
            text: i18n("Read from the severity label (critical/warning/info and common synonyms). Alerts without one always show.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Folders, groups and rules") }

        PatternField {
            Kirigami.FormData.label: i18n("Only these folders:")
            placeholderText: i18n("Everything")
            text: page.cfg_filterIncludeFolders
            onTextEdited: page.cfg_filterIncludeFolders = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Hide folders:")
            placeholderText: "Staging, Experiments*"
            text: page.cfg_filterExcludeFolders
            onTextEdited: page.cfg_filterExcludeFolders = text
        }
        Chips {
            Kirigami.FormData.label: i18n("Hide:")
            values: page.folderChips
            onPicked: value => page.cfg_filterExcludeFolders = G.appendPattern(page.cfg_filterExcludeFolders, G.globLiteral(value))
        }
        PatternField {
            Kirigami.FormData.label: i18n("Hide groups:")
            placeholderText: "noisy-checks, Folder/group"
            text: page.cfg_filterExcludeGroups
            onTextEdited: page.cfg_filterExcludeGroups = text
        }
        Note {
            text: i18n("A bare group name hides it in every folder; Folder/group hides just that one.")
        }
        PatternField {
            Kirigami.FormData.label: i18n("Hide rules named:")
            placeholderText: "Watchdog, *test*"
            text: page.cfg_filterExcludeRules
            onTextEdited: page.cfg_filterExcludeRules = text
        }
        RowLayout {
            visible: page.hiddenUIDs.length > 0
            QQC2.Label {
                text: i18np("%1 rule hidden from the menu", "%1 rules hidden from the menu", page.hiddenUIDs.length)
            }
            QQC2.Button {
                text: i18n("Unhide")
                icon.name: "view-visible"
                onClicked: page.cfg_filterHiddenRuleUIDs = ""
            }
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Labels") }

        PatternField {
            Kirigami.FormData.label: i18n("Only alerts with:")
            placeholderText: "severity=critical, team=infra"
            text: page.cfg_filterIncludeLabels
            onTextEdited: page.cfg_filterIncludeLabels = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Hide alerts with:")
            placeholderText: "host=build-01, env=dev*"
            text: page.cfg_filterExcludeLabels
            onTextEdited: page.cfg_filterExcludeLabels = text
        }
        Chips {
            Kirigami.FormData.label: i18n("Hide:")
            values: page.labelChips
            onPicked: value => page.cfg_filterExcludeLabels = G.appendPattern(page.cfg_filterExcludeLabels, value)
        }
        Note {
            text: i18n("key=value or key!=value; a bare value matches any label. Comma-separated, case-insensitive, * matches anything. “Only” passes alerts matching any one entry; “Hide” drops alerts matching any one. Label filters apply to each instance: a rule shows when at least one of its instances passes.")
        }
    }
}
