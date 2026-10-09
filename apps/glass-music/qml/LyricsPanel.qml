import QtQuick
import QtQuick.Effects

// Synced lyrics (ported from the shell's media/SyncedLyrics.qml): the current line is bright
// and full size, others fade with distance, the view glides to keep it at ~36 % height.
// Click a line to seek there; the wheel browses and the view glides back after a moment.
Item {
    id: root
    property var app
    readonly property var lines: app.lyrics.file === app.status.file ? app.lyrics.lines : []
    property real anchorRatio: 0.36
    property real lookAhead: 0.2
    readonly property int current: {
        const l = lines;
        if (!l || !l.length) return -1;
        const p = app.position + lookAhead;
        let lo = 0, hi = l.length - 1, ans = -1;
        while (lo <= hi) { const mid = (lo + hi) >> 1; if (l[mid].t <= p) { ans = mid; lo = mid + 1; } else hi = mid - 1; }
        return ans;
    }
    property bool browsing: false
    Timer { id: resumeTimer; interval: 2800; onTriggered: { root.browsing = false; root.follow(true); } }

    function clampY(y) { return Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), y)); }
    function follow(animated) {
        if (browsing || !repeater.count) return;
        const it = repeater.itemAt(Math.max(0, current));
        if (!it) return;
        const target = clampY(column.y + it.y + it.height / 2 - flick.height * anchorRatio);
        scrollAnim.stop();
        if (animated && root.visible) { scrollAnim.from = flick.contentY; scrollAnim.to = target; scrollAnim.start(); }
        else flick.contentY = target;
    }
    onCurrentChanged: follow(true)
    onLinesChanged: { browsing = false; resumeTimer.stop(); Qt.callLater(() => root.follow(false)); }
    onHeightChanged: Qt.callLater(() => root.follow(false))
    onWidthChanged: Qt.callLater(() => root.follow(false))
    onVisibleChanged: if (visible) Qt.callLater(() => root.follow(false))

    NumberAnimation { id: scrollAnim; target: flick; property: "contentY"; duration: 700; easing.type: Easing.OutCubic }

    Column {
        anchors.centerIn: parent
        visible: root.lines.length === 0
        width: parent.width
        spacing: 10
        Icon { anchors.horizontalCenter: parent.horizontalCenter; app: root.app; name: "lyrics"; size: 40; color: root.app.th.sub1 }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: !root.app.status.file ? "Play something to see its lyrics." : "No synced lyrics for this song."
            color: root.app.th.sub0
            font.family: root.app.th.font
            font.pixelSize: 15
        }
        Text {
            width: parent.width
            visible: !!root.app.status.file
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Lyrics come from the .lrc file next to the track."
            color: root.app.th.sub1
            font.family: root.app.th.font
            font.pixelSize: 12
        }
    }

    Item {
        id: viewport
        anchors.fill: parent
        visible: root.lines.length > 0
        layer.enabled: true
        layer.effect: MultiEffect { maskEnabled: true; maskSource: fadeMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: column.y + column.height + height * (1 - root.anchorRatio)
            interactive: false
            Column {
                id: column
                y: flick.height * root.anchorRatio
                width: flick.width
                spacing: 14
                Repeater {
                    id: repeater
                    model: root.lines
                    delegate: Item {
                        id: line
                        required property var modelData
                        required property int index
                        readonly property int dist: root.current < 0 ? index + 1 : index - root.current
                        readonly property bool isCurrent: dist === 0
                        readonly property bool isBreak: !modelData.x || modelData.x.trim() === ""
                        width: column.width
                        height: lineText.implicitHeight
                        Text {
                            id: lineText
                            width: parent.width
                            wrapMode: Text.WordWrap
                            font.family: root.app.th.font
                            font.pixelSize: line.isBreak ? 20 : 23
                            font.weight: Font.Bold
                            lineHeight: 1.08
                            text: line.isBreak ? "♪" : line.modelData.x
                            color: line.isCurrent ? "white" : root.app.th.text
                            opacity: {
                                if (line.isCurrent) return 1.0;
                                const d = Math.abs(line.dist);
                                const o = line.dist < 0 ? 0.34 : (d === 1 ? 0.6 : 0.46);
                                return Math.max(0.18, o - Math.max(0, d - 2) * 0.06);
                            }
                            scale: line.isCurrent ? 1.0 : 0.93
                            transformOrigin: Item.Left
                            Behavior on opacity { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
                            Behavior on scale { NumberAnimation { duration: 560; easing.type: Easing.OutCubic } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !line.isBreak
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.browsing = false; resumeTimer.stop(); root.app.seek(Math.max(0, line.modelData.t + 0.05)); }
                        }
                    }
                }
            }
        }
    }
    Item {
        id: fadeMask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.12; color: "black" }
                GradientStop { position: 0.80; color: "black" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
    }
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
            const d = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 2;
            scrollAnim.stop();
            root.browsing = true;
            flick.contentY = root.clampY(flick.contentY - d);
            resumeTimer.restart();
        }
    }
}
