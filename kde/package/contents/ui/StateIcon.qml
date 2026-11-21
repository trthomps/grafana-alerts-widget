import QtQuick
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

// A rule's state (StateIcon in PopoverView.swift): a ring with ! (firing), ↑ (recovering), a dashed
// ring (pending), ✓ (normal), or a crossed-out bell when every instance is silenced.
Item {
    id: icon

    property string alertState: "firing"
    property int severity: 0
    property bool silenced: false

    readonly property color tint: silenced ? Kirigami.Theme.disabledTextColor
        : alertState === "firing" ? root.severityColor(severity)
        : alertState === "pending" ? Kirigami.Theme.neutralTextColor
        : Kirigami.Theme.positiveTextColor

    implicitWidth: Kirigami.Units.iconSizes.small
    implicitHeight: Kirigami.Units.iconSizes.small

    Kirigami.Icon {
        anchors.fill: parent
        visible: icon.silenced
        source: "notifications-disabled"
        isMask: true
        color: icon.tint
    }

    Shape {
        anchors.fill: parent
        visible: !icon.silenced
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            id: ring
            readonly property real w: Math.max(1.25, icon.width / 11)
            strokeWidth: w
            strokeColor: icon.tint
            fillColor: "transparent"
            strokeStyle: icon.alertState === "pending" ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: [1.6, 1.6]
            PathAngleArc {
                centerX: icon.width / 2
                centerY: icon.height / 2
                radiusX: icon.width / 2 - ring.w / 2
                radiusY: icon.height / 2 - ring.w / 2
                startAngle: 0
                sweepAngle: 360
            }
        }
    }

    Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: icon.alertState === "firing" ? -0.5 : 0
        visible: !icon.silenced && icon.alertState !== "pending"
        text: icon.alertState === "firing" ? "!" : icon.alertState === "recovering" ? "↑" : "✓"
        color: icon.tint
        font.pixelSize: Math.round(icon.height * 0.7)
        font.weight: Font.Black
    }
}
