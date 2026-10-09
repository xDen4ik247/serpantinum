import QtQuick
import "../"
import Quickshell
import "../../"
import "../../../"

// "Vitals" — animated gauge rings for CPU / GPU / NPU / RAM / temperature / battery.
// Rings whose sensor is missing are hidden and the rest re-flow into the best grid.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 120
    property real minHeight: 110
    property real maxWidth: 1400
    property real maxHeight: 900
    property bool isRound: false
    property bool ready: false
    Component.onCompleted: Qt.callLater(() => root.ready = true)

    // per-widget toggles (can be set through wProps in the layout file)
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
    readonly property real pad: Math.max(12, Math.min(width, height) * 0.1)
    readonly property real gap: Math.max(8, Math.min(width, height) * 0.06)

    // choose the column count that gives the biggest rings
    readonly property var grid: {
        let best = { cols: 1, rows: count, d: 0 };
        let aw = width - pad * 2;
        let ah = height - pad * 2;
        for (let c = 1; c <= count; c++) {
            let r = Math.ceil(count / c);
            let d = Math.min((aw - (c - 1) * gap) / c, (ah - (r - 1) * gap) / r);
            if (d > best.d + 0.5) best = { cols: c, rows: r, d: d };
        }
        return best;
    }
    readonly property real ringD: Math.max(10, grid.d)
    // spread rings evenly across the free width so the row breathes
    readonly property real cellW: (width - pad * 2) / grid.cols
    readonly property real cellH: (height - pad * 2) / grid.rows

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
        delegate: VitalRing {
            id: ringDelegate
            readonly property var m: vd.metrics[index]
            readonly property int slot: root.slotOf(m.key)
            readonly property int row: slot < 0 ? 0 : Math.floor(slot / root.grid.cols)
            readonly property int col: slot < 0 ? 0 : slot % root.grid.cols
            // centre the last, possibly incomplete, row
            readonly property int inRow: row === root.grid.rows - 1 ? (root.count - row * root.grid.cols) : root.grid.cols
            readonly property real rowOffset: (root.grid.cols - inRow) * root.cellW / 2

            width: root.ringD
            height: root.ringD
            x: root.pad + rowOffset + col * root.cellW + (root.cellW - root.ringD) / 2
            y: root.pad + row * root.cellH + (root.cellH - root.ringD) / 2
            visible: opacity > 0.01
            opacity: m.available ? 1 : 0
            scale: m.available ? 1 : 0.85

            live: root.visible
            value: m.value
            valueText: m.text
            unitText: m.unit
            label: m.label
            accent: m.accent

            Behavior on x { enabled: root.ready; NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: root.ready; NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }
            Behavior on accent { ColorAnimation { duration: 600 } }
        }
    }
}
