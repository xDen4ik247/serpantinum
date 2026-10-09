import QtQuick
import QtQuick.Effects
import "../"

// Synced lyrics for the music panel (data: the Lyrics singleton; for local tracks that is
// the .lrc next to the audio file). The current line is bright and full size, the rest fade
// with distance; the view glides to keep the current line at `anchorRatio` of its height.
// Click a line to seek there. The wheel browses freely and the view glides back after a
// moment. Callers must Lyrics.subscribe() while it is shown.
Item {
    id: root

    property var player: null
    property color activeColor: ThemeBackend.text
    property color inactiveColor: ThemeBackend.text
    property color accentColor: ThemeBackend.mauve
    property string fontFamily: ThemeBackend.fontFamily
    property real fontSize: 18
    property real lineSpacing: 12
    property real anchorRatio: 0.36
    // Highlight a touch before the timestamp: the glide itself takes a moment.
    property real lookAhead: 0.2
    property int alignment: Text.AlignLeft
    property real fadeTop: 0.14
    property real fadeBottom: 0.22

    readonly property var lines: Lyrics.lyrics
    readonly property int current: {
        let l = lines;
        if (!l || l.length === 0) return -1;
        let p = Lyrics.currentPosition + lookAhead;
        let lo = 0, hi = l.length - 1, ans = -1;
        while (lo <= hi) {
            let mid = (lo + hi) >> 1;
            if (l[mid].time <= p) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
        }
        return ans;
    }

    property bool browsing: false
    Timer {
        id: resumeTimer
        interval: 2800
        onTriggered: { root.browsing = false; root.follow(true); }
    }

    function clampY(y) {
        return Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), y));
    }

    function follow(animated) {
        if (browsing || !repeater.count) return;
        let it = repeater.itemAt(Math.max(0, current));
        if (!it) return;
        let target = clampY(column.y + it.y + it.height / 2 - flick.height * anchorRatio);
        if (animated && root.visible) {
            scrollAnim.stop();
            scrollAnim.from = flick.contentY;
            scrollAnim.to = target;
            scrollAnim.start();
        } else {
            scrollAnim.stop();
            flick.contentY = target;
        }
    }

    onCurrentChanged: follow(true)
    onLinesChanged: { browsing = false; resumeTimer.stop(); Qt.callLater(() => root.follow(false)); }
    onHeightChanged: Qt.callLater(() => root.follow(false))
    onVisibleChanged: if (visible) Qt.callLater(() => root.follow(false))

    NumberAnimation {
        id: scrollAnim
        target: flick
        property: "contentY"
        duration: 700
        easing.type: Easing.OutCubic
    }

    Item {
        id: viewport
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: fadeMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: column.y + column.height + height * (1 - root.anchorRatio)
            interactive: false
            clip: false

            Column {
                id: column
                y: flick.height * root.anchorRatio
                width: flick.width
                spacing: root.lineSpacing

                Repeater {
                    id: repeater
                    model: root.lines

                    delegate: Item {
                        id: line
                        required property var modelData
                        required property int index

                        readonly property int dist: root.current < 0 ? index + 1 : index - root.current
                        readonly property bool isCurrent: dist === 0
                        readonly property bool isBreak: !modelData.text || modelData.text.trim() === ""
                        readonly property bool hasWords: !!modelData.words && modelData.words.length > 0

                        width: column.width
                        height: lineText.implicitHeight

                        Text {
                            id: lineText
                            width: parent.width
                            wrapMode: Text.WordWrap
                            horizontalAlignment: root.alignment
                            font.family: root.fontFamily
                            font.pixelSize: line.isBreak ? root.fontSize * 0.9 : root.fontSize
                            font.weight: Font.Bold
                            lineHeight: 1.08
                            textFormat: (line.isCurrent && line.hasWords) ? Text.StyledText : Text.PlainText
                            text: {
                                if (line.isBreak) return "♪";
                                if (line.isCurrent && line.hasWords)
                                    return Lyrics.renderActiveLineText(line.modelData, Lyrics.currentPosition, root.accentColor, root.activeColor);
                                return line.modelData.text;
                            }
                            color: line.isCurrent ? root.activeColor : root.inactiveColor
                            opacity: {
                                if (line.isCurrent) return 1.0;
                                let d = Math.abs(line.dist);
                                let o = line.dist < 0 ? 0.34 : (d === 1 ? 0.6 : 0.46);
                                return Math.max(0.18, o - Math.max(0, d - 2) * 0.06);
                            }
                            scale: line.isCurrent ? 1.0 : 0.93
                            transformOrigin: root.alignment === Text.AlignHCenter ? Item.Center : Item.Left

                            Behavior on opacity { NumberAnimation { duration: 480; easing.type: Easing.OutCubic } }
                            Behavior on scale { NumberAnimation { duration: 560; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 480; easing.type: Easing.OutCubic } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !line.isBreak && !!root.player && root.player.canSeek
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                root.browsing = false;
                                resumeTimer.stop();
                                root.player.position = Math.max(0, line.modelData.time + 0.05);
                            }
                        }
                    }
                }
            }
        }
    }

    // Soft top and bottom edges.
    Item {
        id: fadeMask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: root.fadeTop; color: "black" }
                GradientStop { position: 1.0 - root.fadeBottom; color: "black" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            let d = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 2;
            scrollAnim.stop();
            root.browsing = true;
            flick.contentY = root.clampY(flick.contentY - d);
            resumeTimer.restart();
        }
    }
}
