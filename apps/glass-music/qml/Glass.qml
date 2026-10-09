import QtQuick
import QtQuick.Effects

// Liquid-glass island: translucent Matugen tint, top sheen, hairline rim that is
// bright at the top-left and fades to the bottom-right, soft shadow.
Item {
    id: glass
    property var theme
    property real radius: 16
    property real tintAlpha: 0.32
    property color tintColor: theme ? theme.base : "black"
    property bool lit: false
    property bool raised: true
    property real rimTopAlpha: lit ? 0.5 : 0.26
    property real rimBottomAlpha: lit ? 0.14 : 0.05
    Behavior on rimTopAlpha { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
    Behavior on rimBottomAlpha { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

    RectangularShadow {
        anchors.fill: parent
        visible: glass.raised && glass.width > 0
        radius: glass.radius
        offset.y: 4
        blur: 18
        spread: -2
        color: Qt.rgba(0, 0, 0, 0.28)
        cached: true
    }
    ShaderEffect {
        anchors.fill: parent
        visible: glass.width > 0 && glass.height > 0
        property size size: Qt.size(width, height)
        property real radius: glass.radius
        property real rimWidth: 1.1
        property vector4d tint: Qt.vector4d(glass.tintColor.r, glass.tintColor.g, glass.tintColor.b, glass.tintAlpha)
        property vector4d rimTop: Qt.vector4d(1, 1, 1, glass.rimTopAlpha)
        property vector4d rimBottom: Qt.vector4d(1, 1, 1, glass.rimBottomAlpha)
        property real sheen: 0.035
        fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
    }
}
