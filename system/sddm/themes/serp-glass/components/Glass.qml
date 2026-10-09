import QtQuick
import QtQuick.Effects

// Liquid-glass surface: translucent Matugen tint, soft top sheen, hairline rim
// that is bright at the top-left and fades to the bottom-right, soft shadow.
// Same recipe as the desktop's bar islands (bar/GlassPill.qml).
Item {
    id: glass

    property real radius: height / 2
    property color tintColor: "#0e1415"
    property real tintAlpha: 0.42
    property bool raised: true
    property real shadowAlpha: 0.30
    property real shadowBlur: 18
    property real shadowY: 4
    property bool lit: false
    property color rimColor: "white"
    property real rimWidth: 1.2
    property real sheen: 0.05
    property real rimTopAlpha: lit ? 0.55 : 0.32
    property real rimBottomAlpha: lit ? 0.16 : 0.06

    Behavior on rimTopAlpha { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    Behavior on rimBottomAlpha { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    Behavior on tintAlpha { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

    RectangularShadow {
        anchors.fill: parent
        visible: glass.raised && glass.width > 0
        radius: Math.min(glass.radius, glass.height / 2)
        offset.y: glass.shadowY
        blur: glass.shadowBlur
        spread: -2
        color: Qt.rgba(0, 0, 0, glass.shadowAlpha)
        cached: true
    }

    ShaderEffect {
        anchors.fill: parent
        visible: glass.width > 0 && glass.height > 0
        property size size: Qt.size(width, height)
        property real radius: glass.radius
        property real rimWidth: glass.rimWidth
        property vector4d tint: Qt.vector4d(glass.tintColor.r, glass.tintColor.g, glass.tintColor.b, glass.tintAlpha)
        property vector4d rimTop: Qt.vector4d(glass.rimColor.r, glass.rimColor.g, glass.rimColor.b, glass.rimTopAlpha)
        property vector4d rimBottom: Qt.vector4d(glass.rimColor.r, glass.rimColor.g, glass.rimColor.b, glass.rimBottomAlpha)
        property real sheen: glass.sheen
        fragmentShader: Qt.resolvedUrl("../shaders/glass.frag.qsb")
    }
}
