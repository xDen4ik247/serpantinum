import QtQuick

// Rank ring: a quiet ring with the tier inside and the progress around it. Drawn once per change.
Item {
    id: ring
    property var theme
    property real progress: 0
    property string label: "N5"
    property bool small: false
    property bool done: false
    implicitWidth: 180
    implicitHeight: 180

    onProgressChanged: canvas.requestPaint()
    onDoneChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const cx = width / 2, cy = height / 2, R = Math.min(width, height) / 2;
            const rgba = (c, a) => "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")";
            const r = R * 0.82;
            ctx.lineWidth = Math.max(3, R * 0.07);
            ctx.lineCap = "round";
            ctx.strokeStyle = rgba(ring.theme.text, 0.10);
            ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
            ctx.strokeStyle = rgba(ring.done ? ring.theme.good : ring.theme.accent, 0.95);
            ctx.beginPath();
            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.002, Math.min(1, ring.done ? 1 : ring.progress)));
            ctx.stroke();
        }
    }
    Column {
        anchors.centerIn: parent
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ring.label
            color: ring.theme.text
            font { family: ring.theme.jp; pixelSize: Math.round(ring.height * (ring.label.length > 2 ? 0.16 : 0.2)); weight: Font.DemiBold }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !ring.small
            text: ring.done ? "✓" : Math.floor(ring.progress * 100) + "%"
            color: ring.theme.subtext1
            font { family: ring.theme.font; pixelSize: Math.round(ring.height * 0.08); features: { "tnum": 1 } }
        }
    }
}
