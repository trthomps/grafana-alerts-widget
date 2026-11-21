import QtQuick
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// A small rounded label: a filled count ("3 firing") or a tinted chip ("warning", "NoData").
Rectangle {
    id: pill

    property string text: ""
    property color tint: Kirigami.Theme.textColor
    /// Solid with white text, rather than a faint fill with tinted text.
    property bool filled: false
    /// Just an outline (the "pending" count in the header).
    property bool outlined: !filled && small === false
    property bool small: false
    property real maximumWidth: Kirigami.Units.gridUnit * 8

    radius: height / 2
    color: filled ? tint : small ? Qt.rgba(tint.r, tint.g, tint.b, 0.13) : "transparent"
    border.width: outlined ? 1 : 0
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.6)
    implicitWidth: Math.min(label.implicitWidth + Kirigami.Units.smallSpacing * 2, maximumWidth)
    implicitHeight: label.implicitHeight + 2

    PlasmaComponents.Label {
        id: label
        anchors.centerIn: parent
        width: Math.min(implicitWidth, pill.width - Kirigami.Units.smallSpacing * 2)
        elide: Text.ElideRight
        text: pill.text
        color: pill.filled ? "white" : pill.tint
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        font.weight: pill.filled ? Font.Bold : pill.small ? Font.Normal : Font.DemiBold
        font.features: { "tnum": 1 }
    }
}
