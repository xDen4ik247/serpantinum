import QtQuick
import QtQuick.Shapes
import Quickshell
import "../../"
import "../../../"

// "Traffic" — live network (or disk) throughput as a smooth scrolling area chart.
// One sample per second from WidgetSensors; the plot glides one step left on each sample.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 220
    property real minHeight: 110
    property real maxWidth: 1600
    property real maxHeight: 700
    property bool isRound: false

    property string mode: "net"          // "net" | "disk"
    readonly property bool isDisk: mode === "disk"

    readonly property string title: isDisk ? "Disk" : "Network"
    readonly property string titleIcon: String.fromCodePoint(isDisk ? 0xF02CA : 0xF05A9)
    readonly property string labelA: isDisk ? "Read" : "Down"
    readonly property string labelB: isDisk ? "Write" : "Up"
    readonly property color colorA: ThemeBackend.mauve
    readonly property color colorB: ThemeBackend.peach
    readonly property real floorScale: isDisk ? 1e6 : 64e3

    readonly property real rateA: isDisk ? WidgetSensors.diskRead : WidgetSensors.netRx
    readonly property real rateB: isDisk ? WidgetSensors.diskWrite : WidgetSensors.netTx

    // ---- subscription
    property bool subscribed: false
    function updateSubscription() {
        if (visible && !subscribed) { WidgetSensors.subscribe(); subscribed = true; }
        else if (!visible && subscribed) { WidgetSensors.unsubscribe(); subscribed = false; }
    }
    onVisibleChanged: updateSubscription()
    Component.onCompleted: { updateSubscription(); rebuild(false); }
    Component.onDestruction: if (subscribed) WidgetSensors.unsubscribe()

    Connections {
        target: WidgetSensors
        function onSampled() { root.rebuild(true); }
    }

    // ---- geometry
    readonly property real pad: Math.max(12, Math.min(width, height) * 0.09)
    readonly property real headerH: Math.max(26, Math.min(44, height * 0.24))
    readonly property int slots: 60
    readonly property real stroke: Math.max(1.6, Math.min(2.6, height / 90))

    property real scaleMax: floorScale
    Behavior on scaleMax { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
    onScaleMaxChanged: rebuild(false)
    onWidthChanged: rebuild(false)
    onHeightChanged: rebuild(false)

    property string pathA: ""
    property string areaA: ""
    property string pathB: ""
    property string areaB: ""
    property real lastAY: -100
    property real lastBY: -100

    function niceCeil(v) {
        if (v <= 0) return 1;
        let p = Math.pow(10, Math.floor(Math.log10(v)));
        let m = v / p;
        let n = m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10;
        return n * p;
    }

    // monotone cubic (Fritsch–Carlson): smooth, never overshoots below zero
    function smoothPath(pts) {
        let n = pts.length;
        if (n === 0) return "";
        if (n === 1) return "M " + pts[0].x + " " + pts[0].y;
        let dxs = [], ms = [];
        for (let i = 0; i < n - 1; i++) {
            let dx = pts[i + 1].x - pts[i].x;
            dxs.push(dx);
            ms.push((pts[i + 1].y - pts[i].y) / dx);
        }
        let t = [ms[0]];
        for (let i = 1; i < n - 1; i++) {
            if (ms[i - 1] * ms[i] <= 0) t.push(0);
            else {
                let w1 = 2 * dxs[i] + dxs[i - 1], w2 = dxs[i] + 2 * dxs[i - 1];
                t.push((w1 + w2) / (w1 / ms[i - 1] + w2 / ms[i]));
            }
        }
        t.push(ms[n - 2]);
        let d = "M " + pts[0].x.toFixed(2) + " " + pts[0].y.toFixed(2);
        for (let i = 0; i < n - 1; i++) {
            let h = dxs[i] / 3;
            d += " C " + (pts[i].x + h).toFixed(2) + " " + (pts[i].y + t[i] * h).toFixed(2)
                + " " + (pts[i + 1].x - h).toFixed(2) + " " + (pts[i + 1].y - t[i + 1] * h).toFixed(2)
                + " " + pts[i + 1].x.toFixed(2) + " " + pts[i + 1].y.toFixed(2);
        }
        return d;
    }

    function rebuild(advance) {
        let ha = isDisk ? WidgetSensors.diskReadHist : WidgetSensors.netRxHist;
        let hb = isDisk ? WidgetSensors.diskWriteHist : WidgetSensors.netTxHist;
        let w = plotArea.width, h = plotArea.height;
        if (w <= 0 || h <= 0) return;

        if (advance) {
            let peak = 0;
            for (let i = Math.max(0, ha.length - slots - 1); i < ha.length; i++) peak = Math.max(peak, ha[i] || 0, hb[i] || 0);
            let target = niceCeil(Math.max(floorScale, peak * 1.15));
            if (Math.abs(target - scaleMax) > 1) scaleMax = target;   // Behavior animates it
        }

        let dx = w / (slots - 1);
        let top = h * 0.06;
        let usable = h - top - stroke;
        function build(hist) {
            let n = Math.min(hist.length, slots + 1);
            let pts = [];
            for (let k = 0; k < n; k++) {
                let v = hist[hist.length - n + k] || 0;
                let x = w - (n - 1 - k) * dx;
                let y = h - stroke / 2 - Math.min(1, v / Math.max(1, root.scaleMax)) * usable;
                pts.push({ x: x, y: y });
            }
            return pts;
        }
        let pa = build(ha), pb = build(hb);
        if (pa.length < 2) {
            pathA = areaA = pathB = areaB = "";
            lastAY = lastBY = -100;
            return;
        }
        pathA = smoothPath(pa);
        areaA = pathA + " L " + w.toFixed(2) + " " + h + " L " + pa[0].x.toFixed(2) + " " + h + " Z";
        pathB = smoothPath(pb);
        areaB = pathB + " L " + w.toFixed(2) + " " + h + " L " + pb[0].x.toFixed(2) + " " + h + " Z";
        lastAY = pa[pa.length - 1].y;
        lastBY = pb[pb.length - 1].y;

        if (advance && root.visible) {
            scrollAnim.stop();
            plot.x = dx;
            scrollAnim.start();
        }
    }

    // ---- visuals
    Rectangle {
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
    }

    Item {
        id: header
        x: root.pad
        y: root.pad * 0.85
        width: root.width - root.pad * 2
        height: root.headerH

        Rectangle {
            id: badge
            width: header.height * 0.92
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.rgba(root.colorA.r, root.colorA.g, root.colorA.b, 0.16)
            Text {
                anchors.centerIn: parent
                text: root.titleIcon
                color: root.colorA
                font.family: ThemeBackend.iconFont
                font.pixelSize: parent.width * 0.5
            }
        }
        Text {
            anchors.left: badge.right
            anchors.leftMargin: header.height * 0.35
            anchors.verticalCenter: parent.verticalCenter
            text: root.title
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: header.height * 0.46
            font.weight: Font.Bold
            visible: root.width > header.height * 9
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: header.height * 0.6

            Repeater {
                model: [
                    { label: root.labelA, value: root.rateA, color: root.colorA },
                    { label: root.labelB, value: root.rateB, color: root.colorB }
                ]
                delegate: Column {
                    spacing: 0
                    Row {
                        spacing: header.height * 0.14
                        anchors.right: parent.right
                        Rectangle {
                            width: header.height * 0.2
                            height: width
                            radius: width / 2
                            color: modelData.color
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: modelData.label.toUpperCase()
                            color: ThemeBackend.subtext1
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: header.height * 0.26
                            font.weight: Font.Bold
                            font.letterSpacing: 0.6
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        text: WidgetSensors.formatRate(modelData.value)
                        color: ThemeBackend.text
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: header.height * 0.42
                        font.weight: Font.Bold
                        font.features: { "tnum": 1 }
                    }
                }
            }
        }
    }

    Item {
        id: plotArea
        x: root.pad
        y: header.y + header.height + root.pad * 0.6
        width: root.width - root.pad * 2
        height: root.height - y - root.pad * 0.8
        clip: true

        // grid lines + scale label
        Repeater {
            model: 3
            delegate: Rectangle {
                width: plotArea.width
                height: 1
                y: Math.round(plotArea.height * 0.06 + (plotArea.height * 0.94 - root.stroke) * index / 3)
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, index === 0 ? 0.07 : 0.045)
            }
        }
        Rectangle {
            width: plotArea.width
            height: 1
            y: plotArea.height - 1
            color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.08)
        }

        Item {
            id: plot
            width: plotArea.width
            height: plotArea.height

            NumberAnimation on x {
                id: scrollAnim
                running: false
                to: 0
                duration: 650
                easing.type: Easing.OutCubic
            }

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0; x2: 0; y2: plot.height
                        GradientStop { position: 0.0; color: Qt.rgba(root.colorB.r, root.colorB.g, root.colorB.b, 0.22) }
                        GradientStop { position: 1.0; color: Qt.rgba(root.colorB.r, root.colorB.g, root.colorB.b, 0.0) }
                    }
                    PathSvg { path: root.areaB }
                }
                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0; x2: 0; y2: plot.height
                        GradientStop { position: 0.0; color: Qt.rgba(root.colorA.r, root.colorA.g, root.colorA.b, 0.42) }
                        GradientStop { position: 1.0; color: Qt.rgba(root.colorA.r, root.colorA.g, root.colorA.b, 0.02) }
                    }
                    PathSvg { path: root.areaA }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.colorB
                    strokeWidth: root.stroke
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: root.pathB }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.colorA
                    strokeWidth: root.stroke
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: root.pathA }
                }
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 2
            y: plotArea.height * 0.06 + 3
            text: WidgetSensors.formatRate(root.scaleMax).replace(".0 ", " ")
            color: ThemeBackend.subtext1
            opacity: 0.8
            font.family: ThemeBackend.fontFamily
            font.pixelSize: Math.max(9, root.headerH * 0.26)
            font.weight: Font.DemiBold
        }
    }

    // live "now" dots ride at the right edge of the plot
    Repeater {
        model: [{ y: root.lastBY, c: root.colorB }, { y: root.lastAY, c: root.colorA }]
        delegate: Rectangle {
            visible: modelData.y > -50
            width: root.stroke * 3.4
            height: width
            radius: width / 2
            color: modelData.c
            border.width: root.stroke * 0.9
            border.color: ThemeBackend.surface0
            x: plotArea.x + plotArea.width - width / 2
            y: plotArea.y + modelData.y - height / 2
            Behavior on y { NumberAnimation { duration: 650; easing.type: Easing.OutCubic } }
        }
    }
}
