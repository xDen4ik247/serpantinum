import QtQuick
import "../"

// One glass keycap: translucent face, bright top rim, a darker "depth" lip below.
Item {
    id: cap
    property string text: ""
    property bool modifier: false
    property bool active: false          // highlighted (search hit on the key)
    property bool sep: false             // "or" divider between alternative key combos
    readonly property bool glyph: text.length === 1 && text.charCodeAt(0) > 0x2000

    implicitHeight: 25
    implicitWidth: sep ? 10 : Math.max(implicitHeight, label.implicitWidth + (text.length > 1 ? 16 : 10))

    Text {
        visible: cap.sep
        anchors.centerIn: parent
        text: "/"
        color: ThemeBackend.overlay1
        font.family: ThemeBackend.fontFamily
        font.pixelSize: 13
    }

    // depth lip
    Rectangle {
        visible: !cap.sep
        anchors.fill: parent
        anchors.topMargin: 2
        radius: 7
        color: Qt.rgba(0, 0, 0, 0.30)
    }
    // face
    Rectangle {
        id: face
        visible: !cap.sep
        anchors.fill: parent
        anchors.bottomMargin: 2
        radius: 7
        gradient: Gradient {
            GradientStop { position: 0; color: cap.active ? Qt.rgba(ThemeBackend.blue.r, ThemeBackend.blue.g, ThemeBackend.blue.b, 0.42)
                                                         : Qt.rgba(1, 1, 1, cap.modifier ? 0.13 : 0.19) }
            GradientStop { position: 1; color: cap.active ? Qt.rgba(ThemeBackend.blue.r, ThemeBackend.blue.g, ThemeBackend.blue.b, 0.24)
                                                         : Qt.rgba(1, 1, 1, cap.modifier ? 0.05 : 0.08) }
        }
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, cap.modifier ? 0.16 : 0.24)
        // top highlight line
        Rectangle {
            x: 5; y: 1
            width: parent.width - 10
            height: 1
            radius: 0.5
            color: Qt.rgba(1, 1, 1, 0.22)
        }
        Text {
            id: label
            anchors.centerIn: parent
            anchors.verticalCenterOffset: cap.glyph ? 0 : 0
            text: cap.text
            color: cap.modifier ? ThemeBackend.subtext1 : ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: cap.glyph ? 14 : 12
            font.weight: cap.modifier ? Font.Medium : Font.DemiBold
        }
    }
}
