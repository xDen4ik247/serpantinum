import QtQuick
import QtQuick.Shapes
import "../../../"

// One 270° gauge ring: track + animated value arc, value in the middle, label in the gap.
Item {
    id: ring

    property real value: 0              // 0..1
    property string valueText: ""
    property string unitText: ""
    property string label: ""
    property string icon: ""            // optional glyph shown before the label
    property color accent: ThemeBackend.mauve
    property bool live: true

    readonly property real d: Math.min(width, height)
    readonly property real stroke: Math.max(4, d * 0.095)
    readonly property real arcR: (d - stroke) / 2 - 1

    property real shown: 0
    Behavior on shown {
        enabled: ring.live
        NumberAnimation { duration: 700; easing.type: Easing.OutCubic }
    }
    onValueChanged: shown = Math.max(0, Math.min(1, value))
    Component.onCompleted: shown = Math.max(0, Math.min(1, value))

    Shape {
        id: arcs
        width: ring.d
        height: ring.d
        anchors.centerIn: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.13)
            strokeWidth: ring.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: arcs.width / 2
                centerY: arcs.height / 2
                radiusX: ring.arcR
                radiusY: ring.arcR
                startAngle: 135
                sweepAngle: 270
            }
        }

        ShapePath {
            fillColor: "transparent"
            strokeColor: ring.shown > 0.004 ? ring.accent : "transparent"
            strokeWidth: ring.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: arcs.width / 2
                centerY: arcs.height / 2
                radiusX: ring.arcR
                radiusY: ring.arcR
                startAngle: 135
                sweepAngle: Math.max(0.01, 270 * ring.shown)
            }
        }
    }

    Row {
        anchors.centerIn: arcs
        anchors.verticalCenterOffset: -ring.d * 0.03
        spacing: 1

        Text {
            id: valueLabel
            text: ring.valueText
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: Math.max(10, ring.d * 0.25)
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
        }
        Text {
            text: ring.unitText
            visible: text !== ""
            color: ThemeBackend.subtext0
            font.family: ThemeBackend.fontFamily
            font.pixelSize: Math.max(8, ring.d * 0.12)
            font.weight: Font.DemiBold
            anchors.baseline: valueLabel.baseline
        }
    }

    Row {
        anchors.horizontalCenter: arcs.horizontalCenter
        anchors.bottom: arcs.bottom
        anchors.bottomMargin: ring.d * 0.04
        spacing: ring.d * 0.03

        Text {
            visible: ring.icon !== ""
            text: ring.icon
            color: ring.accent
            font.family: ThemeBackend.iconFont
            font.pixelSize: Math.max(8, ring.d * 0.13)
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: ring.label
            color: ThemeBackend.subtext0
            font.family: ThemeBackend.fontFamily
            font.pixelSize: Math.max(8, ring.d * 0.115)
            font.weight: Font.Bold
            font.letterSpacing: ring.d * 0.012
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
