import QtQuick
import QtQuick.Effects
import "../"

// Liquid-glass island used behind bar modules and module groups when
// bar.glass is on. The compositor blurs what is behind it (see Bar.qml
// BackgroundEffect.blurRegion); this item only paints the tint, sheen and rim.
Item {
    id: glass

    property real radius: height / 2
    property real tintAlpha: 0.6
    property bool raised: true          // soft drop shadow under the island
    property bool lit: false            // brighter rim (hover / active state)

    readonly property color tintColor: ThemeBackend.base

    property real rimTopAlpha: lit ? 0.42 : 0.30
    property real rimBottomAlpha: lit ? 0.12 : 0.06
    Behavior on rimTopAlpha { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
    Behavior on rimBottomAlpha { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

    RectangularShadow {
        anchors.fill: parent
        visible: glass.raised && glass.width > 0
        radius: glass.radius
        offset.y: 2
        blur: 10
        spread: -1
        color: Qt.rgba(0, 0, 0, 0.32)
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
        property real sheen: 0.045
        fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
    }
}
