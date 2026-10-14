import QtQuick

// Round initial on a colour picked from the address (stable per sender).
Rectangle {
    id: av
    property var app
    property string name: ""
    property string addr: ""
    property real size: 36
    width: size
    height: size
    radius: size / 2
    readonly property string label: {
        const s = (name || addr || "?").replace(/^["'\s]+/, "");
        // first letter or digit (any script); QML's JS has no \p{L}, so skip punctuation by hand
        for (const ch of s) if (ch.toUpperCase() !== ch.toLowerCase() || /[0-9]/.test(ch)) return ch.toUpperCase();
        return s ? s[0] : "?";
    }
    color: {
        const k = (addr || name || "?").toLowerCase();
        let h = 0;
        for (let i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) % 360;
        return Qt.hsla(h / 360, 0.42, 0.42, 1);
    }
    gradient: Gradient {
        GradientStop { position: 0; color: Qt.lighter(av.color, 1.18) }
        GradientStop { position: 1; color: Qt.darker(av.color, 1.12) }
    }
    Text {
        anchors.centerIn: parent
        text: av.label
        color: "white"
        font.family: av.app.th.font
        font.pixelSize: Math.round(av.size * 0.44)
        font.weight: Font.DemiBold
    }
}
