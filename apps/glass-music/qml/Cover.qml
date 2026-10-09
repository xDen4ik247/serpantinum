import QtQuick

// Album art for an album key: the lazily cached 256 px thumbnail (or the original cover
// when `hires`), rounded/cropped in one shader pass, with a tinted placeholder meanwhile.
Item {
    id: c
    property var app
    property string albumKey: ""
    property bool hires: false
    property real radius: 8
    property bool circle: false
    property real dim: 0
    property bool shadow: false
    readonly property var album: albumKey !== "" ? app.albumByKey[albumKey] : undefined
    readonly property var thumb: albumKey !== "" ? app.thumbs[albumKey] : undefined
    readonly property string src: !album || !album.c ? "" : ((hires || !app.thumbsEnabled) ? "file://" + album.c : (thumb ? "file://" + thumb.p : ""))
    readonly property bool ready: img.status === Image.Ready
    readonly property real r: circle ? Math.min(width, height) / 2 : radius

    function ask() { if (album && album.c && !thumb && !hires) app.requestThumb(albumKey); }
    onAlbumKeyChanged: ask()
    Component.onCompleted: ask()

    Rectangle {
        anchors.fill: parent
        visible: !c.ready || shader.opacity < 1
        radius: c.r
        gradient: Gradient {
            GradientStop { position: 0; color: c.app.th.mix(c.app.th.surface2, c.app.colorFor(c.albumKey), 0.35) }
            GradientStop { position: 1; color: c.app.th.surface0 }
        }
        Icon {
            app: c.app
            anchors.centerIn: parent
            name: c.circle ? "account" : "note"
            size: Math.max(14, Math.min(c.width, c.height) * 0.36)
            color: c.app.th.alpha(c.app.th.text, 0.35)
        }
    }
    Image {
        id: img
        visible: false
        source: c.src
        asynchronous: true
        cache: true
        smooth: true
        mipmap: c.hires
        sourceSize: c.hires ? Qt.size(800, 800) : Qt.size(256, 256)
    }
    ShaderEffect {
        id: shader
        anchors.fill: parent
        visible: c.ready
        opacity: c.ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        property var source: img
        property size size: Qt.size(width, height)
        property real radius: c.r
        property real dim: c.dim
        property vector4d crop: {
            const iw = img.implicitWidth, ih = img.implicitHeight;
            if (!iw || !ih || !width || !height) return Qt.vector4d(0, 0, 1, 1);
            const ai = iw / ih, ab = width / height;
            if (ai > ab) { const sx = ab / ai; return Qt.vector4d((1 - sx) / 2, 0, sx, 1); }
            const sy = ai / ab; return Qt.vector4d(0, (1 - sy) / 2, 1, sy);
        }
        fragmentShader: Qt.resolvedUrl("shaders/round.frag.qsb")
    }
}
