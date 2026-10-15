import QtQuick

// Rank emblem. Dota style: a metal medal with wings, its own symbol and five stars (Herald … Immortal).
// Plain style: a quiet ring with the tier inside. Drawn once per change; nothing loops.
Item {
    id: medal
    property var theme
    property int index: 0          // 0 Herald … 7 Immortal
    property int stars: 1
    property real progress: 0      // plain style: the ring
    property string label: "N5"    // plain style: the text inside
    property bool dota: true
    property bool small: false
    implicitWidth: 180
    implicitHeight: 180

    // base metal colour of each medal, close to Dota's own
    readonly property var metals: ["#9a7b56", "#93aaa2", "#4fa3a9", "#c6a94a", "#d9c47c", "#8a7ad6", "#63b8e6", "#e0574e"]
    // symbols (Font Awesome in the Symbols Nerd Font): bullhorn, shield, flag, castle, columns, tree, sun, diamond
    readonly property var symbols: ["", "", "", "", "", "", "", ""]
    readonly property color metal: metals[Math.max(0, Math.min(7, index))]

    onIndexChanged: canvas.requestPaint()
    onStarsChanged: canvas.requestPaint()
    onProgressChanged: canvas.requestPaint()
    onDotaChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width, h = height, cx = w / 2, cy = h / 2, R = Math.min(w, h) / 2;
            const m = medal.metal;
            const rgba = (c, a) => "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")";
            const shade = (c, k) => Qt.rgba(Math.min(1, c.r * k), Math.min(1, c.g * k), Math.min(1, c.b * k), 1);
            if (!medal.dota) {
                // plain: track ring + progress arc
                const r = R * 0.82;
                ctx.lineWidth = Math.max(3, R * 0.07);
                ctx.lineCap = "round";
                ctx.strokeStyle = rgba(medal.theme.text, 0.10);
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
                ctx.strokeStyle = rgba(medal.theme.accent, 0.95);
                ctx.beginPath(); ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.002, Math.min(1, medal.progress))); ctx.stroke();
                return;
            }
            // soft glow behind (static)
            const glow = ctx.createRadialGradient(cx, cy, R * 0.3, cx, cy, R);
            glow.addColorStop(0, rgba(m, 0.22));
            glow.addColorStop(1, rgba(m, 0));
            ctx.fillStyle = glow;
            ctx.fillRect(0, 0, w, h);
            // wings: three feathers each side
            for (const side of [-1, 1]) {
                for (let i = 0; i < 3; i++) {
                    const len = R * (0.92 - i * 0.14), spread = 0.42 + i * 0.36;
                    const g = ctx.createLinearGradient(cx, cy, cx + side * len, cy - len * 0.2);
                    g.addColorStop(0, rgba(shade(m, 1.25), 0.95));
                    g.addColorStop(1, rgba(shade(m, 0.55), 0.85));
                    ctx.fillStyle = g;
                    ctx.beginPath();
                    ctx.moveTo(cx + side * R * 0.30, cy - R * 0.12 + i * R * 0.16);
                    ctx.quadraticCurveTo(cx + side * len * 0.85, cy - R * spread * 0.55 + i * R * 0.12, cx + side * len, cy - R * 0.32 + i * R * 0.30);
                    ctx.quadraticCurveTo(cx + side * len * 0.70, cy + R * 0.02 + i * R * 0.18, cx + side * R * 0.30, cy + R * 0.10 + i * R * 0.14);
                    ctx.closePath();
                    ctx.fill();
                    ctx.strokeStyle = rgba(shade(m, 0.35), 0.6);
                    ctx.lineWidth = 1;
                    ctx.stroke();
                }
            }
            // the metal disc
            const r = R * 0.56;
            const disc = ctx.createLinearGradient(cx - r, cy - r, cx + r, cy + r);
            disc.addColorStop(0, shade(m, 1.45));
            disc.addColorStop(0.45, m);
            disc.addColorStop(1, shade(m, 0.45));
            ctx.fillStyle = disc;
            ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fill();
            ctx.lineWidth = Math.max(1.5, R * 0.025);
            ctx.strokeStyle = rgba(shade(m, 1.7), 0.75);
            ctx.stroke();
            // inner dark field
            const ri = r * 0.74;
            const field = ctx.createRadialGradient(cx - ri * 0.3, cy - ri * 0.4, ri * 0.1, cx, cy, ri);
            field.addColorStop(0, rgba(shade(m, 0.55), 1));
            field.addColorStop(1, rgba(shade(m, 0.18), 1));
            ctx.fillStyle = field;
            ctx.beginPath(); ctx.arc(cx, cy, ri, 0, Math.PI * 2); ctx.fill();
            ctx.lineWidth = 1;
            ctx.strokeStyle = rgba(shade(m, 1.6), 0.45);
            ctx.stroke();
            // stars along the lower rim
            const n = medal.index >= 7 ? 0 : 5;
            for (let i = 0; i < n; i++) {
                const a = Math.PI / 2 - (i - 2) * 0.36;   // first star on the left
                const sx = cx + Math.cos(a) * r * 0.99, sy = cy + Math.sin(a) * r * 0.99;
                const sr = R * 0.075;
                ctx.beginPath();
                for (let k = 0; k < 10; k++) {
                    const rr = k % 2 === 0 ? sr : sr * 0.45;
                    const t = -Math.PI / 2 + k * Math.PI / 5;
                    if (k === 0) ctx.moveTo(sx + Math.cos(t) * rr, sy + Math.sin(t) * rr);
                    else ctx.lineTo(sx + Math.cos(t) * rr, sy + Math.sin(t) * rr);
                }
                ctx.closePath();
                const on = i < medal.stars;
                ctx.fillStyle = on ? "rgba(255,226,150,0.98)" : "rgba(20,20,26,0.85)";
                ctx.fill();
                ctx.lineWidth = 1;
                ctx.strokeStyle = on ? "rgba(120,80,20,0.9)" : rgba(shade(m, 1.3), 0.6);
                ctx.stroke();
            }
        }
    }

    // the medal's symbol, or the tier in plain style
    Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: medal.dota ? -medal.height * 0.02 : 0
        visible: medal.dota
        text: medal.symbols[Math.max(0, Math.min(7, medal.index))]
        color: Qt.rgba(1, 0.96, 0.88, 0.92)
        style: Text.Raised
        styleColor: Qt.rgba(0, 0, 0, 0.45)
        font { family: medal.theme.icons; pixelSize: Math.round(medal.height * 0.20) }
    }
    Column {
        anchors.centerIn: parent
        visible: !medal.dota
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: medal.label
            color: medal.theme.text
            font { family: medal.theme.jp; pixelSize: Math.round(medal.height * (medal.label.length > 2 ? 0.16 : 0.2)); weight: Font.DemiBold }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !medal.small
            text: Math.floor(medal.progress * 100) + "%"
            color: medal.theme.subtext1
            font { family: medal.theme.font; pixelSize: Math.round(medal.height * 0.08); features: { "tnum": 1 } }
        }
    }
}
