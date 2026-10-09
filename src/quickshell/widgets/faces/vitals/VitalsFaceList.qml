import QtQuick
import "../"
import Quickshell
import "../../"
import "../../../"

// "Vitals" list variant — one row per sensor: icon, label, detail, animated capsule bar.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 180
    property real minHeight: 120
    property real maxWidth: 900
    property real maxHeight: 900
    property bool isRound: false
    property bool ready: false
    Component.onCompleted: Qt.callLater(() => root.ready = true)

    property bool showCpu: true
    property bool showGpu: true
    property bool showNpu: true
    property bool showRam: true
    property bool showTemp: true
    property bool showBattery: true

    VitalsData {
        id: vd
        active: root.visible
        showCpu: root.showCpu
        showGpu: root.showGpu
        showNpu: root.showNpu
        showRam: root.showRam
        showTemp: root.showTemp
        showBattery: root.showBattery
    }

    readonly property int count: Math.max(1, vd.visibleMetrics.length)
    readonly property real pad: Math.max(14, Math.min(width, height) * 0.08)
    readonly property real rowH: (height - pad * 2) / count
    readonly property real fontPx: Math.max(10, Math.min(16, rowH * 0.36))

    function slotOf(key) {
        let list = vd.visibleMetrics;
        for (let i = 0; i < list.length; i++) if (list[i].key === key) return i;
        return -1;
    }

    Rectangle {
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
    }

    Repeater {
        model: 6
        delegate: Item {
            id: rowItem
            readonly property var m: vd.metrics[index]
            readonly property int slot: root.slotOf(m.key)
            property real shown: 0
            property color accent: m.accent
            Behavior on accent { ColorAnimation { duration: 600 } }
            Behavior on shown { enabled: root.visible; NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
            readonly property real target: Math.max(0, Math.min(1, m.value))
            onTargetChanged: shown = target
            Component.onCompleted: shown = target

            x: root.pad
            width: root.width - root.pad * 2
            height: root.rowH
            y: root.pad + Math.max(0, slot) * root.rowH
            opacity: m.available ? 1 : 0
            visible: opacity > 0.01
            Behavior on y { enabled: root.ready; NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

            Rectangle {
                id: badge
                width: Math.min(rowItem.height * 0.78, root.fontPx * 2.3)
                height: width
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.rgba(rowItem.accent.r, rowItem.accent.g, rowItem.accent.b, 0.16)
                Text {
                    anchors.centerIn: parent
                    text: rowItem.m.icon
                    color: rowItem.accent
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: parent.width * 0.52
                }
            }

            Item {
                anchors.left: badge.right
                anchors.leftMargin: root.fontPx * 0.8
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                Text {
                    id: lbl
                    text: rowItem.m.label
                    color: ThemeBackend.text
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.fontPx
                    font.weight: Font.Bold
                    anchors.left: parent.left
                    anchors.bottom: bar.top
                    anchors.bottomMargin: root.fontPx * 0.35
                }
                Text {
                    text: rowItem.m.detail
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.fontPx * 0.9
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    anchors.right: parent.right
                    anchors.baseline: lbl.baseline
                }

                Rectangle {
                    id: bar
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: root.fontPx * 0.55
                    height: Math.max(4, root.fontPx * 0.42)
                    radius: height / 2
                    color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.09)

                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        width: Math.max(parent.height, parent.width * rowItem.shown)
                        opacity: rowItem.shown > 0.004 ? 1 : 0
                        color: rowItem.accent
                    }
                }
            }
        }
    }
}
