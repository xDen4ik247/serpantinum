import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.Mpris
import "../../../reusables"
import "../../../"
import "../../../media" as Music

// Now-playing pill for the horizontal bar.
//   playing/paused: round cover · "Title — Artist" (marquee when long) · thin progress line;
//                   hovering reveals prev / play / next and the pill grows to fit them.
//   nothing playing: collapses to a small music button that opens the library player.
// Mouse: left = music panel, middle = play/pause, right = library player (rmpc),
//        wheel = player volume (shown on the progress line for a moment).
// Smart shuffle (music-smart): a 󰒝 chip leads the hover controls (and appears next to the
//   idle music button); click = start / re-roll, right-click = leave smart mode. While a smart
//   queue plays, the cover wears an accent ring + 󰒝 badge.
// In glass mode (bar.glass) TopBar paints the island; this face only uses glass chips.
Item {
    id: root

    property var module: null
    property var widget: module

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    readonly property bool moduleActive: module ? module.moduleActive : true
    readonly property bool glass: module ? !!module.glass : false

    function s(val) { return barWindow ? barWindow.s(val) : val; }

    // ── Player ────────────────────────────────────────────────────────────────
    readonly property var player: MprisController.activePlayer
    readonly property bool hasTrack: player !== null && player.playbackState !== MprisPlaybackState.Stopped && (player.trackTitle || "") !== ""
    readonly property bool isPlaying: hasTrack && (player.playbackState === MprisPlaybackState.Playing || player.isPlaying)
    readonly property string title: hasTrack ? (player.trackTitle || "") : ""
    readonly property string artist: hasTrack ? (player.trackArtist || "") : ""
    readonly property string artSource: {
        let u = MprisController.artUrl;
        if (!hasTrack || !u) return "";
        return (u.startsWith("file://") || u.startsWith("http")) ? u : "file://" + u;
    }
    readonly property real trackLength: (hasTrack && player.length > 0) ? player.length : 0
    readonly property real progress: trackLength > 0 ? Math.max(0, Math.min(1, MprisController.livePosition / trackLength)) : 0
    readonly property bool canVolume: hasTrack && player.canControl && player.volumeSupported

    // ── Metrics (same 30 px chips as the other faces in a 40 px island) ───────
    readonly property real faceH: height > 0 ? height : s(isCompact ? 32 : 40)
    readonly property real coverSize: s(isCompact ? 24 : 30)
    readonly property real inset: Math.max(0, Math.round((faceH - coverSize) / 2))
    readonly property real textGap: s(isCompact ? 7 : 9)
    readonly property real textMaxW: s(isCompact ? 150 : 200)
    readonly property real textMinW: s(48)
    readonly property real endPad: s(isCompact ? 10 : 13)
    readonly property real btnSize: coverSize
    readonly property real btnGap: s(2)
    readonly property real controlsW: btnSize * 4 + btnGap * 3
    readonly property real fontSize: s(isCompact ? 11 : 12)

    readonly property real fullTextW: tmTitle.advanceWidth + (artist !== "" ? tmSep.advanceWidth + tmArtist.advanceWidth : 0)
    readonly property real textW: Math.ceil(Math.max(textMinW, Math.min(textMaxW, fullTextW)))

    // Hover reveals the transport buttons; a short hold avoids flicker at the edges.
    property bool hoverHold: false
    readonly property bool hovered: faceHover.hovered || (module ? !!module.hovered : false)
    onHoveredChanged: {
        if (hovered) { unhoverTimer.stop(); hoverHold = true; }
        else unhoverTimer.restart();
    }
    Timer { id: unhoverTimer; interval: 350; onTriggered: root.hoverHold = false }
    readonly property bool controlsShown: hasTrack && hoverHold
    readonly property bool idleExpanded: !hasTrack && hoverHold
    readonly property var smart: Music.SmartShuffle
    readonly property bool smartOn: smart.shown && hasTrack

    property real targetWidth: {
        if (!moduleActive) return 0;
        if (!hasTrack) return idleExpanded ? Math.round(inset * 2 + coverSize * 2 + btnGap * 2) : faceH;
        let w = inset + coverSize + textGap + textW;
        return Math.round(w + (controlsShown ? (s(8) + controlsW + inset) : endPad));
    }
    implicitWidth: targetWidth
    implicitHeight: parent ? parent.height : 0

    readonly property color chipColor: glass ? module.glassChip : (isCompact ? Qt.lighter(ThemeBackend.surface0, 1.18) : ThemeBackend.surface0)
    readonly property color chipHoverColor: glass ? module.glassChipHover : Qt.lighter(chipColor, 1.15)
    readonly property color titleColor: glass ? Qt.alpha(ThemeBackend.text, 0.92) : ThemeBackend.text
    readonly property color dimColor: glass ? Qt.alpha(ThemeBackend.text, 0.58) : ThemeBackend.subtext0

    function openPanel() {
        Quickshell.execDetached(["bash", "-c", Caching.serpantinumDir + "/scripts/qs_manager.sh toggle music"]);
    }
    function openPlayer() {
        Quickshell.execDetached(["bash", "-c", "exec \"$HOME/.local/bin/music-player\""]);
    }

    HoverHandler { id: faceHover }

    TextMetrics { id: tmTitle; font.family: ThemeBackend.fontFamily; font.pixelSize: root.fontSize; font.weight: Font.DemiBold; text: root.title }
    TextMetrics { id: tmSep; font.family: ThemeBackend.fontFamily; font.pixelSize: root.fontSize; font.weight: Font.Medium; text: "  —  " }
    TextMetrics { id: tmArtist; font.family: ThemeBackend.fontFamily; font.pixelSize: root.fontSize; font.weight: Font.Medium; text: root.artist }

    // ── Volume (wheel) ────────────────────────────────────────────────────────
    property real wheelAccum: 0
    property bool volumeFlash: false
    Timer { id: volumeFlashTimer; interval: 1300; onTriggered: root.volumeFlash = false }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: root.canVolume
        onWheel: (event) => {
            let d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y * 2;
            root.wheelAccum += d;
            let steps = Math.trunc(root.wheelAccum / 120);
            if (steps === 0) return;
            root.wheelAccum -= steps * 120;
            let v = Math.max(0, Math.min(1, Math.round((root.player.volume + steps * 0.05) * 100) / 100));
            root.player.volume = v;
            root.volumeFlash = true;
            volumeFlashTimer.restart();
        }
    }

    // ── Collapsed: nothing is playing ─────────────────────────────────────────
    IconButton {
        id: idleButton
        x: root.inset
        anchors.verticalCenter: parent.verticalCenter
        width: root.coverSize
        height: root.coverSize
        cornerRadius: Math.round(root.coverSize / 2)
        buttonIcon: "󰝚"
        iconFontSize: root.s(root.isCompact ? 12 : 14)
        accentColor: isHoveredOrHighlighted ? root.chipHoverColor : root.chipColor
        textColor: isHoveredOrHighlighted ? ThemeBackend.text : root.dimColor
        opacity: root.hasTrack ? 0 : 1
        scale: root.hasTrack ? 0.6 : 1
        visible: opacity > 0.01
        enabled: !root.hasTrack
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
        onClicked: root.openPlayer()

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: root.openPanel()
        }
    }

    // Idle + hover: one click starts a smart queue.
    IconButton {
        width: root.btnSize
        height: root.btnSize
        cornerRadius: Math.round(root.btnSize / 2)
        buttonIcon: "󰒝"
        iconFontSize: root.s(root.isCompact ? 10 : 12)
        accentColor: root.smartOn ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.40 : 0.28)
                                  : (isHoveredOrHighlighted ? root.chipHoverColor : root.chipColor)
        textColor: root.smartOn ? ThemeBackend.mauve : (isHoveredOrHighlighted ? ThemeBackend.text : root.dimColor)
        onClicked: root.smart.start()

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: root.smart.stop()
        }
        x: root.inset + root.coverSize + root.btnGap * 2 + (root.idleExpanded ? 0 : -root.s(8))
        anchors.verticalCenter: parent.verticalCenter
        opacity: root.idleExpanded ? 1 : 0
        visible: opacity > 0.01
        enabled: root.idleExpanded
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }

    // ── Now playing ───────────────────────────────────────────────────────────
    Item {
        id: nowPlaying
        anchors.fill: parent
        opacity: root.hasTrack ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        // Cover + text are one click target: panel / play-pause / library player.
        MouseArea {
            id: infoArea
            width: root.inset + root.coverSize + root.textGap + root.textW + root.s(4)
            height: parent.height
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.MiddleButton) {
                    if (root.player && root.player.canTogglePlaying) root.player.togglePlaying();
                } else if (mouse.button === Qt.RightButton) {
                    root.openPlayer();
                } else {
                    root.openPanel();
                }
            }
        }

        // Round cover, concentric with the island's rounded end.
        Item {
            id: coverBox
            x: root.inset
            anchors.verticalCenter: parent.verticalCenter
            width: root.coverSize
            height: root.coverSize
            scale: infoArea.pressed ? 0.94 : 1.0
            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.chipColor
            }

            Text {
                anchors.centerIn: parent
                text: "󰝚"
                font.family: ThemeBackend.iconFont
                font.pixelSize: root.s(root.isCompact ? 11 : 13)
                color: root.dimColor
                visible: !artA.visibleArt && !artB.visibleArt
            }

            Item {
                id: artLayer
                anchors.fill: parent
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: coverMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }

                property bool showA: true
                property string current: ""
                function swap(src) {
                    if (src === current) return;
                    current = src;
                    if (showA) { artB.source = src; showA = false; }
                    else { artA.source = src; showA = true; }
                }
                Connections {
                    target: root
                    function onArtSourceChanged() { artLayer.swap(root.artSource); }
                }
                Component.onCompleted: swap(root.artSource)

                Image {
                    id: artA
                    readonly property bool visibleArt: artLayer.showA && status === Image.Ready && source != ""
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(root.coverSize * 2, root.coverSize * 2)
                    asynchronous: true
                    opacity: visibleArt ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                }
                Image {
                    id: artB
                    readonly property bool visibleArt: !artLayer.showA && status === Image.Ready && source != ""
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(root.coverSize * 2, root.coverSize * 2)
                    asynchronous: true
                    opacity: visibleArt ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                }
            }

            Item {
                id: coverMask
                anchors.fill: parent
                layer.enabled: true
                visible: false
                Rectangle { anchors.fill: parent; radius: width / 2; color: "black"; antialiasing: true }
            }

            // Paused: the cover dims and shows a pause glyph.
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "#000000"
                opacity: (root.hasTrack && !root.isPlaying) ? 0.45 : 0
                Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            }
            Text {
                anchors.centerIn: parent
                text: "󰏤"
                font.family: ThemeBackend.iconFont
                font.pixelSize: root.s(root.isCompact ? 11 : 13)
                color: "#ffffff"
                opacity: (root.hasTrack && !root.isPlaying) ? 0.95 : 0
                scale: opacity > 0.5 ? 1 : 0.7
                Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
            }

            // Smart shuffle on: accent ring around the cover + a small 󰒝 badge.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -root.s(2)
                radius: width / 2
                color: "transparent"
                border.width: root.s(1.5)
                border.color: Qt.alpha(ThemeBackend.mauve, 0.9)
                opacity: root.smartOn ? 1 : 0
                scale: root.smartOn ? 1 : 0.85
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 600; easing.type: Easing.OutQuint } }
            }
            Rectangle {
                width: Math.round(root.s(root.isCompact ? 10 : 12))
                height: width
                radius: width / 2
                x: parent.width - width + root.s(3)
                y: parent.height - height + root.s(3)
                color: ThemeBackend.mauve
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.base, 0.6)
                opacity: root.smartOn ? 1 : 0
                scale: root.smartOn ? 1 : 0.4
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 600; easing.type: Easing.OutQuint } }
                Text {
                    anchors.centerIn: parent
                    text: "󰒝"
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: Math.round(root.s(root.isCompact ? 7 : 8))
                    color: ThemeBackend.base
                }
            }
        }

        // "Title — Artist" with a seamless marquee and soft edges when it overflows.
        Item {
            id: textBox
            x: root.inset + root.coverSize + root.textGap
            width: root.textW
            height: parent.height

            readonly property real lineY: Math.round(height / 2 - lineA.height / 2 - root.s(2.5))
            readonly property real gapW: root.s(40)
            readonly property bool overflow: lineA.width > width + 1
            readonly property bool canMarquee: overflow && root.isPlaying && root.visible && !root.volumeFlash
            property real offset: 0

            // Text swaps happen behind a short fade so a track change never jumps.
            property string shownTitle: root.title
            property string shownArtist: root.artist
            Connections {
                target: root
                function onTitleChanged() { textBox.queueSwap(); }
                function onArtistChanged() { textBox.queueSwap(); }
            }
            function queueSwap() {
                if (shownTitle === "" || root.title === "") { applySwap(); return; }
                swapAnim.restart();
            }
            function applySwap() {
                shownTitle = root.title;
                shownArtist = root.artist;
                restartMarquee();
            }
            function restartMarquee() {
                marqueeAnim.stop();
                offset = 0;
                if (canMarquee) marqueeAnim.start();
            }
            onCanMarqueeChanged: restartMarquee()
            onWidthChanged: if (!marqueeAnim.running) restartMarquee()

            SequentialAnimation {
                id: swapAnim
                NumberAnimation { target: textContent; property: "opacity"; to: 0; duration: 110; easing.type: Easing.OutQuad }
                ScriptAction { script: textBox.applySwap() }
                NumberAnimation { target: textContent; property: "opacity"; to: 1; duration: 200; easing.type: Easing.OutCubic }
            }

            SequentialAnimation {
                id: marqueeAnim
                loops: Animation.Infinite
                PauseAnimation { duration: 2400 }
                NumberAnimation {
                    target: textBox
                    property: "offset"
                    from: 0
                    to: lineA.width + textBox.gapW
                    duration: Math.max(1200, (lineA.width + textBox.gapW) * 1000 / root.s(30))
                    easing.type: Easing.Linear
                }
                PropertyAction { target: textBox; property: "offset"; value: 0 }
            }

            Item {
                id: textViewport
                anchors.fill: parent
                clip: !textBox.overflow
                layer.enabled: textBox.overflow
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: fadeMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }

                Item {
                    anchors.fill: parent
                    opacity: root.volumeFlash ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 180 } }

                    Item {
                        id: textContent
                        x: -Math.round(textBox.offset)
                        y: textBox.lineY
                        height: lineA.height

                        Row {
                            id: lineA
                            Text {
                                text: textBox.shownTitle
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: root.fontSize
                                font.weight: Font.DemiBold
                                color: root.titleColor
                                opacity: root.isPlaying ? 1 : 0.72
                                Behavior on opacity { NumberAnimation { duration: 300 } }
                            }
                            Text {
                                visible: textBox.shownArtist !== ""
                                text: "  —  " + textBox.shownArtist
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: root.fontSize
                                font.weight: Font.Medium
                                color: root.dimColor
                            }
                        }
                        Row {
                            x: lineA.width + textBox.gapW
                            visible: textBox.overflow
                            Text {
                                text: textBox.shownTitle
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: root.fontSize
                                font.weight: Font.DemiBold
                                color: root.titleColor
                                opacity: root.isPlaying ? 1 : 0.72
                            }
                            Text {
                                visible: textBox.shownArtist !== ""
                                text: "  —  " + textBox.shownArtist
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: root.fontSize
                                font.weight: Font.Medium
                                color: root.dimColor
                            }
                        }
                    }
                }

                // Volume readout replaces the text while the wheel is used.
                Text {
                    x: 0
                    y: textBox.lineY
                    text: "Volume  " + (root.player ? Math.round(root.player.volume * 100) : 0) + "%"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.fontSize
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                    color: root.titleColor
                    opacity: root.volumeFlash ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity { NumberAnimation { duration: 180 } }
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
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        // Left edge fades only while the text scrolls, so the first letter is crisp at rest.
                        GradientStop { position: textBox.offset > 0.5 ? Math.min(0.12, root.s(10) / Math.max(1, textBox.width)) : 0.0001; color: "black" }
                        GradientStop { position: 1.0 - Math.min(0.12, root.s(14) / Math.max(1, textBox.width)); color: "black" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
            }

            // Thin progress line; it shows the volume level while the wheel is used.
            // Normal one-second ticks move it in place; only big jumps glide.
            Item {
                id: progressTrack
                y: Math.round(textBox.height / 2 + root.s(root.isCompact ? 7 : 8))
                width: parent.width
                height: root.s(2)

                readonly property real targetFrac: root.volumeFlash ? (root.player ? root.player.volume : 0) : root.progress
                property real shownFrac: 0
                onTargetFracChanged: {
                    if (Math.abs(targetFrac - shownFrac) * width > root.s(6)) {
                        fracAnim.stop();
                        fracAnim.from = shownFrac;
                        fracAnim.to = targetFrac;
                        fracAnim.start();
                    } else if (!fracAnim.running) {
                        shownFrac = targetFrac;
                    } else {
                        fracAnim.to = targetFrac;
                    }
                }
                Component.onCompleted: shownFrac = targetFrac
                NumberAnimation { id: fracAnim; target: progressTrack; property: "shownFrac"; duration: 340; easing.type: Easing.OutCubic }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: Qt.alpha(ThemeBackend.text, root.glass ? 0.16 : 0.12)
                }
                Rectangle {
                    height: parent.height
                    radius: height / 2
                    width: Math.max(height, parent.width * progressTrack.shownFrac)
                    color: root.volumeFlash ? ThemeBackend.text : (root.isPlaying ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.45))
                    Behavior on color { ColorAnimation { duration: 250 } }
                }
            }
        }

        // Transport buttons, revealed on hover.
        Row {
            id: controls
            x: root.inset + root.coverSize + root.textGap + root.textW + root.s(8) + (root.controlsShown ? 0 : root.s(10))
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.btnGap
            opacity: root.controlsShown ? 1 : 0
            visible: opacity > 0.01
            enabled: root.controlsShown
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

            IconButton {
            width: root.btnSize
            height: root.btnSize
            cornerRadius: Math.round(root.btnSize / 2)
            buttonIcon: "󰒝"
            iconFontSize: root.s(root.isCompact ? 10 : 12)
            accentColor: root.smartOn ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.40 : 0.28)
                                      : (isHoveredOrHighlighted ? root.chipHoverColor : root.chipColor)
            textColor: root.smartOn ? ThemeBackend.mauve : (isHoveredOrHighlighted ? ThemeBackend.text : root.dimColor)
            onClicked: root.smart.start()

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: root.smart.stop()
            }
            }
            IconButton {
                width: root.btnSize
                height: root.btnSize
                cornerRadius: Math.round(root.btnSize / 2)
                buttonIcon: "󰒮"
                iconFontSize: root.s(root.isCompact ? 9 : 10)
                accentColor: isHoveredOrHighlighted ? root.chipHoverColor : root.chipColor
                textColor: isHoveredOrHighlighted ? ThemeBackend.text : root.dimColor
                enabled: root.player !== null && root.player.canGoPrevious
                onClicked: root.player.previous()
            }
            IconButton {
                width: root.btnSize
                height: root.btnSize
                cornerRadius: Math.round(root.btnSize / 2)
                buttonIcon: root.isPlaying ? "󰏤" : "󰐊"
                iconFontSize: root.s(root.isCompact ? 11 : 12)
                accentColor: isHoveredOrHighlighted ? Qt.alpha(ThemeBackend.mauve, 0.34) : Qt.alpha(ThemeBackend.mauve, 0.22)
                textColor: ThemeBackend.text
                enabled: root.player !== null && root.player.canTogglePlaying
                onClicked: root.player.togglePlaying()
            }
            IconButton {
                width: root.btnSize
                height: root.btnSize
                cornerRadius: Math.round(root.btnSize / 2)
                buttonIcon: "󰒭"
                iconFontSize: root.s(root.isCompact ? 9 : 10)
                accentColor: isHoveredOrHighlighted ? root.chipHoverColor : root.chipColor
                textColor: isHoveredOrHighlighted ? ThemeBackend.text : root.dimColor
                enabled: root.player !== null && root.player.canGoNext
                onClicked: root.player.next()
            }
        }
    }
}
