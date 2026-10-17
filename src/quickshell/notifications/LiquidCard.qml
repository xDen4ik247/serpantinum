import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import "../"

// Apple-style Liquid Glass notification banner, used for popups when bar.glass is on
// (NotificationPopups.qml). niri blurs + saturates what is behind it; shaders/liquidglass.frag
// paints the glass (tint, lens edge, specular rim). Layout follows iOS/macOS banners:
// app icon (or the sender's picture with a small app badge), bold title with the time on
// the right, two lines of body. Hover: the close button appears at the top-left, the body
// opens up and the actions slide in as glass capsules. Click runs the default action,
// a sideways swipe dismisses.
Item {
    id: card

    property var model
    property var root
    property var delegateWrapper

    readonly property bool glass: true
    readonly property real cardRadius: s(24)
    property bool expanded: false
    readonly property bool isHovered: hover.containsMouse || closeArea.containsMouse || actionsHovered || isDragging || replying
    readonly property bool isDragging: hover.dragging
    property bool actionsHovered: false
    property real dragX: 0
    property real dragY: 0

    readonly property int urgency: model && model.urgency !== undefined ? model.urgency : 1
    readonly property bool critical: urgency === 2
    readonly property var actions: delegateWrapper && delegateWrapper.actionArray
        ? delegateWrapper.actionArray.filter(a => a.id !== "default") : []
    readonly property var liveNotif: delegateWrapper ? delegateWrapper.realNotif : null
    readonly property bool canReply: !!liveNotif && liveNotif.hasInlineReply === true
    property bool replying: false
    onReplyingChanged: if (root && root.popupWindow) root.popupWindow.replyActive = replying
    readonly property bool showMore: (isHovered || replying) && (actions.length > 0 || canReply || body.truncated || body.lineCount > 2)

    readonly property color ink: Qt.rgba(1, 1, 1, 0.96)
    readonly property color inkSoft: Qt.rgba(1, 1, 1, 0.78)
    readonly property color inkFaint: Qt.rgba(1, 1, 1, 0.5)

    function s(v) { return root && typeof root.s === "function" ? root.s(v) : v; }

    width: parent ? parent.width : 0
    implicitHeight: content.implicitHeight + s(28)
    // animate height changes (hover reveal) only once the card has settled: an animated height
    // while the list is still placing a new card leaves the cards below it overlapping
    property bool settled: false
    Timer { interval: 600; running: true; onTriggered: card.settled = true }
    Behavior on implicitHeight { enabled: card.settled; NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }

    // ── behaviour ─────────────────────────────────────────────────────────────
    function imageUrl(v) {
        let ic = v ? v.toString() : "";
        if (!ic) return "";
        if (/^(file|image|https?):\/\//.test(ic)) return ic;
        return ic.startsWith("/") ? "file://" + ic : "image://icon/" + ic;
    }

    function close() {
        let n = delegateWrapper ? delegateWrapper.realNotif : null;
        if (n && typeof n.dismiss === "function") n.dismiss();
        else if (n && typeof n.close === "function") n.close();
        if (delegateWrapper) delegateWrapper.removeThisNotif();
    }

    function sendReply(text) {
        let t = text.trim();
        if (t === "" || !liveNotif) return;
        liveNotif.sendInlineReply(t);
        replying = false;
        if (delegateWrapper) delegateWrapper.removeThisNotif();
    }

    function invoke(id) {
        let n = delegateWrapper ? delegateWrapper.realNotif : null;
        if (n && n.actions) {
            let hit = null;
            for (let i = 0; i < n.actions.length; i++) {
                if (n.actions[i].identifier === id) { hit = n.actions[i]; break; }
            }
            if (!hit && id === "default" && n.actions.length > 0) hit = n.actions[0];
            if (hit) hit.invoke();
        }
        if (delegateWrapper) delegateWrapper.removeThisNotif();
    }

    property string timeText: "now"
    function updateTime() {
        let sec = Math.floor((Date.now() - (model && model.timestamp ? model.timestamp : Date.now())) / 1000);
        timeText = sec < 60 ? "now" : (sec < 3600 ? Math.floor(sec / 60) + "m ago" : Math.floor(sec / 3600) + "h ago");
    }
    Timer { interval: 30000; running: true; repeat: true; onTriggered: card.updateTime() }

    property bool _soundPlayed: false
    function playSound() {
        if (_soundPlayed || !model) return;
        if (Math.abs(Date.now() - model.timestamp) > 3000) return;
        let cfg = Config.getSetting("notifications", { "sound": true, "soundFile": "", "dnd": false });
        if (cfg.dnd === true || cfg.sound === false || !cfg.soundFile) return;
        if (typeof Sounds !== "undefined") { _soundPlayed = true; Sounds.play(cfg.soundFile); }
    }
    onModelChanged: { updateTime(); Qt.callLater(playSound); }

    RetainableLock {
        object: card.delegateWrapper && card.delegateWrapper.realNotif ? card.delegateWrapper.realNotif : null
        locked: true
    }

    NumberAnimation { id: snapBack; target: card; property: "dragX"; to: 0; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
    NumberAnimation {
        id: flyOut; target: card; property: "dragX"; duration: 220; easing.type: Easing.InCubic
        onFinished: card.close()
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        property real startX: 0
        property bool dragging: false
        onPressed: (m) => { startX = mapToItem(null, m.x, m.y).x; dragging = false; snapBack.stop(); }
        onPositionChanged: (m) => {
            if (!pressed) return;
            let dx = mapToItem(null, m.x, m.y).x - startX;
            if (!dragging && Math.abs(dx) > card.s(6)) { dragging = true; preventStealing = true; }
            // rubber band to the left, free to the right (the side banners leave from)
            if (dragging) card.dragX = dx > 0 ? dx : -Math.sqrt(-dx) * card.s(3);
        }
        onReleased: {
            preventStealing = false;
            if (dragging) {
                dragging = false;
                if (card.dragX > card.width * 0.22) { flyOut.to = card.width * 1.3; flyOut.start(); }
                else snapBack.start();
            } else {
                card.invoke("default");
            }
        }
        onCanceled: { preventStealing = false; dragging = false; snapBack.start(); }
    }

    // ── glass ─────────────────────────────────────────────────────────────────
    Item {
        id: glassLayer
        anchors.fill: parent
        transform: Translate { x: card.dragX }
        opacity: 1.0 - Math.min(1.0, Math.max(0, card.dragX) / (card.width * 0.9))
        scale: hover.pressed && !hover.dragging ? 0.975 : 1.0
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }

        RectangularShadow {
            anchors.fill: parent
            radius: card.cardRadius
            offset.y: card.s(8)
            blur: card.s(28)
            spread: -card.s(6)
            color: Qt.rgba(0, 0, 0, 0.34)
            cached: true
        }

        ShaderEffect {
            anchors.fill: parent
            property size size: Qt.size(width, height)
            property real radius: card.cardRadius
            property vector4d tint: card.critical
                ? Qt.vector4d(0.36, 0.06, 0.09, 0.40)
                : Qt.vector4d(ThemeBackend.base.r * 0.8, ThemeBackend.base.g * 0.8, ThemeBackend.base.b * 0.8, 0.30)
            property real lensWidth: card.s(16)
            property real lens: 0.085
            property real rim: 0.62
            property real glow: card.isHovered && !hover.dragging ? 0.025 : 0.0
            Behavior on glow { NumberAnimation { duration: 260 } }
            fragmentShader: Qt.resolvedUrl("shaders/liquidglass.frag.qsb")
        }

        // ── content ───────────────────────────────────────────────────────────
        ColumnLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: card.s(14) }
            spacing: card.s(10)

            RowLayout {
                Layout.fillWidth: true
                spacing: card.s(12)

                // app icon, or the sender's picture with the app icon as a badge
                Item {
                    id: iconBox
                    Layout.preferredWidth: card.s(40)
                    Layout.preferredHeight: card.s(40)
                    Layout.alignment: Qt.AlignTop

                    readonly property string picture: card.model ? card.imageUrl(card.model.image || "") : ""
                    readonly property string appIcon: card.model ? card.imageUrl(card.model.icon || card.model.iconPath || "") : ""
                    readonly property bool hasPicture: picture !== "" && picture !== appIcon && pictureImg.status === Image.Ready
                    readonly property bool hasAppIcon: appIcon !== "" && appImg.status === Image.Ready
                    readonly property color tileColor: {
                        let pal = [ThemeBackend.blue, ThemeBackend.mauve, ThemeBackend.green, ThemeBackend.peach, ThemeBackend.teal, ThemeBackend.pink];
                        let k = card.model ? (card.model.appName || "") : "";
                        let h = 0;
                        for (let i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) >>> 0;
                        return card.critical ? ThemeBackend.red : pal[h % pal.length];
                    }

                    // fallback tile: app colour gradient + initial
                    Rectangle {
                        anchors.fill: parent
                        visible: !iconBox.hasPicture && !iconBox.hasAppIcon
                        radius: card.s(11)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.lighter(iconBox.tileColor, 1.15) }
                            GradientStop { position: 1.0; color: Qt.darker(iconBox.tileColor, 1.35) }
                        }
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.22)
                        Text {
                            anchors.centerIn: parent
                            text: {
                                let n = card.model ? (card.model.displayName || card.model.appName || "") : "";
                                return card.critical ? "!" : (n ? n.charAt(0).toUpperCase() : "•");
                            }
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.Bold
                            font.pixelSize: card.s(19)
                            color: "white"
                        }
                    }

                    Image {
                        id: pictureImg
                        anchors.fill: parent
                        source: iconBox.picture
                        sourceSize: Qt.size(96, 96)
                        fillMode: Image.PreserveAspectCrop
                        visible: false
                        asynchronous: true
                    }
                    MultiEffect {
                        anchors.fill: parent
                        source: pictureImg
                        visible: iconBox.hasPicture
                        maskEnabled: true
                        maskSource: circleMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }
                    Item {
                        id: circleMask
                        anchors.fill: parent
                        layer.enabled: true
                        visible: false
                        Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
                    }

                    Image {
                        id: appImg
                        readonly property bool badge: iconBox.hasPicture
                        width: badge ? card.s(18) : parent.width
                        height: width
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: badge ? -card.s(3) : 0
                        anchors.bottomMargin: badge ? -card.s(3) : 0
                        source: iconBox.appIcon
                        sourceSize: Qt.size(96, 96)
                        fillMode: Image.PreserveAspectFit
                        visible: status === Image.Ready && source != ""
                        asynchronous: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: card.s(2)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: card.s(8)
                        Text {
                            Layout.fillWidth: true
                            text: card.model ? (card.model.summary || card.model.displayName || card.model.appName || "") : ""
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.DemiBold
                            font.pixelSize: card.s(14.5)
                            color: card.ink
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            textFormat: Text.PlainText
                        }
                        Item {
                            Layout.preferredWidth: Math.max(timeLabel.implicitWidth, card.s(22))
                            Layout.preferredHeight: card.s(20)
                            Text {
                                id: timeLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: card.timeText
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: card.s(11.5)
                                color: card.inkFaint
                                opacity: closeBtn.opacity > 0.5 ? 0 : 1
                                Behavior on opacity { NumberAnimation { duration: 150 } }
                            }
                            // close: a small glass disc where the time was, on hover
                            Rectangle {
                                id: closeBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: card.s(20)
                                height: width
                                radius: width / 2
                                opacity: card.isHovered && !hover.dragging ? 1 : 0
                                scale: opacity > 0.5 ? 1 : 0.6
                                Behavior on opacity { NumberAnimation { duration: 180 } }
                                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                                color: closeArea.containsMouse ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.14)
                                border.width: 1
                                border.color: Qt.rgba(1, 1, 1, 0.26)
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: "✕"
                                    font.pixelSize: card.s(9)
                                    font.weight: Font.Bold
                                    color: card.ink
                                }
                                MouseArea {
                                    id: closeArea
                                    anchors.fill: parent
                                    anchors.margins: -card.s(4)
                                    hoverEnabled: true
                                    enabled: closeBtn.opacity > 0.5
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: card.close()
                                }
                            }
                        }
                    }

                    Text {
                        // app name under the title when the title is something else (a sender, a subject)
                        Layout.fillWidth: true
                        readonly property string app: card.model ? (card.model.displayName || card.model.appName || "") : ""
                        visible: app !== "" && card.model && card.model.summary !== "" && app !== card.model.summary
                        text: app
                        font.family: ThemeBackend.fontFamily
                        font.weight: Font.Medium
                        font.pixelSize: card.s(11)
                        font.letterSpacing: card.s(0.2)
                        color: card.inkFaint
                        elide: Text.ElideRight
                    }

                    Text {
                        id: body
                        Layout.fillWidth: true
                        Layout.topMargin: card.s(1)
                        visible: text !== ""
                        text: card.model ? (card.model.body || "") : ""
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: card.s(13)
                        lineHeight: 1.08
                        color: card.inkSoft
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        maximumLineCount: card.showMore ? 8 : 2
                        textFormat: Text.PlainText
                    }
                }
            }

            // actions: glass capsules, slide in on hover
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: card.showMore && (card.actions.length > 0 || card.canReply) ? card.s(32) : 0
                Layout.topMargin: card.showMore && (card.actions.length > 0 || card.canReply) ? 0 : -card.s(10)
                Behavior on Layout.preferredHeight { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                clip: true
                opacity: card.showMore ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                RowLayout {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: card.s(32)
                    spacing: card.s(8)
                    Rectangle {
                        visible: card.canReply && !card.replying
                        Layout.fillWidth: true
                        Layout.preferredHeight: card.s(32)
                        radius: height / 2
                        color: repArea.pressed ? Qt.rgba(1, 1, 1, 0.24) : (repArea.containsMouse ? Qt.rgba(1, 1, 1, 0.17) : Qt.rgba(1, 1, 1, 0.10))
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, repArea.containsMouse ? 0.30 : 0.16)
                        Text {
                            anchors.centerIn: parent
                            text: "Reply"
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.Medium
                            font.pixelSize: card.s(12.5)
                            color: card.ink
                        }
                        MouseArea {
                            id: repArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: card.actionsHovered = containsMouse
                            onClicked: { card.replying = true; replyField.forceActiveFocus(); }
                        }
                    }
                    Rectangle {
                        visible: card.replying
                        Layout.fillWidth: true
                        Layout.preferredHeight: card.s(32)
                        radius: height / 2
                        color: Qt.rgba(1, 1, 1, 0.12)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.3)
                        TextInput {
                            id: replyField
                            anchors { fill: parent; leftMargin: card.s(14); rightMargin: card.s(14) }
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: card.s(13)
                            color: card.ink
                            selectionColor: Qt.rgba(1, 1, 1, 0.3)
                            clip: true
                            onAccepted: card.sendReply(text)
                            Keys.onEscapePressed: { card.replying = false; text = ""; }
                            Text {
                                visible: !parent.text
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: card.liveNotif && card.liveNotif.inlineReplyPlaceholder ? card.liveNotif.inlineReplyPlaceholder : "Reply…"
                                font: parent.font
                                color: card.inkFaint
                            }
                        }
                    }
                    Repeater {
                        model: card.replying ? [] : card.actions
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: card.s(32)
                            radius: height / 2
                            color: actArea.pressed ? Qt.rgba(1, 1, 1, 0.24) : (actArea.containsMouse ? Qt.rgba(1, 1, 1, 0.17) : Qt.rgba(1, 1, 1, 0.10))
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, actArea.containsMouse ? 0.30 : 0.16)
                            Behavior on color { ColorAnimation { duration: 150 } }
                            Text {
                                anchors.centerIn: parent
                                width: parent.width - card.s(16)
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData.text || "Open"
                                font.family: ThemeBackend.fontFamily
                                font.weight: Font.Medium
                                font.pixelSize: card.s(12.5)
                                color: card.ink
                                elide: Text.ElideRight
                            }
                            MouseArea {
                                id: actArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onContainsMouseChanged: card.actionsHovered = containsMouse
                                onClicked: card.invoke(modelData.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
