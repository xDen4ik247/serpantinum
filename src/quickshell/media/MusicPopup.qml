import QtQuick
import QtQuick.Window
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "../"
import "../reusables"
import "../bar" as BarGlass
import "."

// Music panel (Mod+M, or a click on the bar's now-playing pill).
//
//   ┌────────────┬──────────────────┐   With synced lyrics: the cover column on the left,
//   │   cover    │  lyric (past)    │   the lyrics on the right; the current line is bright
//   │            │  CURRENT LINE    │   and the view glides with it. Without lyrics the pane
//   │ title …    │  next lines      │   slides away and the cover column moves to the centre
//   │ ━━━━○───── │                  │   and grows. The whole panel sits on a soft blur of
//   │ ⤮ ⏮ ⏯ ⏭ ⟳ │                  │   the cover.
//   └────────────┴──────────────────┘
//
// Keys: Space play/pause · ←/→ seek 5 s · ↑/↓ volume · N/P next/previous · S shuffle ·
//       R repeat · L lyrics · E equalizer · Tab lyrics↔equalizer · G My Vibe · F favourite · Esc closes.
// My Vibe (music-smart, also Mod+S): the style button next to lyrics/EQ/library starts My Vibe in
// its style or re-rolls it (right-click leaves My Vibe; styles: bar chip / Glass Music); ☆ marks the
// track as a favourite. While My Vibe plays, the button glows and the info block shows the style
// and why the current track was picked.
Item {
    id: root

    focus: true

    readonly property bool active: root.visible && (!Window.window || Window.window.visible)

    function s(val) { return Scaler.s(val); }

    function formatTime(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        let m = Math.floor(sec / 60), ss = sec % 60;
        return m + ":" + (ss < 10 ? "0" : "") + ss;
    }

    // ── Players ───────────────────────────────────────────────────────────────
    readonly property var playerList: {
        if (!Mpris.players || !Mpris.players.values) return [];
        let list = [];
        let vals = Mpris.players.values;
        for (let i = 0; i < vals.length; i++) if (vals[i]) list.push(vals[i]);
        return list;
    }
    property var manualPlayer: null
    readonly property var targetPlayer: {
        if (manualPlayer && playerList.indexOf(manualPlayer) >= 0) return manualPlayer;
        return MprisController.activePlayer;
    }
    readonly property bool hasPlayer: targetPlayer !== null
    readonly property bool hasTrack: hasPlayer && targetPlayer.playbackState !== MprisPlaybackState.Stopped && (targetPlayer.trackTitle || "") !== ""
    readonly property bool isPlaying: hasTrack && (targetPlayer.playbackState === MprisPlaybackState.Playing || targetPlayer.isPlaying)
    readonly property real trackLength: (hasTrack && targetPlayer.length > 0) ? targetPlayer.length : 0

    function cyclePlayer() {
        if (playerList.length < 2) return;
        let i = playerList.indexOf(targetPlayer);
        manualPlayer = playerList[(i + 1) % playerList.length];
    }

    readonly property string sourceName: {
        if (!targetPlayer) return "";
        let id = targetPlayer.identity || targetPlayer.desktopEntry || "Media";
        // mpd-mpris calls itself "MPD on <socket path>"; it is the music library.
        if (/^MPD\b/.test(id) || /\.mpd$/.test(targetPlayer.dbusName || "")) return "Library";
        return id;
    }

    // ── Track metadata ────────────────────────────────────────────────────────
    readonly property string title: hasTrack ? (targetPlayer.trackTitle || "") : ""
    readonly property string artist: hasTrack ? (targetPlayer.trackArtist || "") : ""
    readonly property string album: hasTrack ? (targetPlayer.trackAlbum || "") : ""
    readonly property string year: {
        if (!hasTrack || !targetPlayer.metadata) return "";
        let d = targetPlayer.metadata["xesam:contentCreated"];
        let m = d ? String(d).match(/^(\d{4})/) : null;
        return m ? m[1] : "";
    }

    // ── Cover art (the active player's art is prepared by MprisController) ────
    property string localArtUrl: ""
    readonly property bool usesSharedArt: targetPlayer !== null && targetPlayer === MprisController.activePlayer
    readonly property string artPath: usesSharedArt ? MprisController.artUrl : localArtUrl
    readonly property string artSource: (hasTrack && artPath) ? ((artPath.startsWith("file://") || artPath.startsWith("http")) ? artPath : "file://" + artPath) : ""

    Process {
        id: artProc
        command: [
            "bash", Caching.qsDir + "/media/art_fetch.sh",
            root.targetPlayer ? (root.targetPlayer.dbusName || root.targetPlayer.identity || "") : "",
            root.targetPlayer ? (root.targetPlayer.trackArtUrl || "") : "",
            root.targetPlayer ? (root.targetPlayer.trackTitle || "") : "",
            root.targetPlayer ? (root.targetPlayer.trackArtist || "") : ""
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let d = JSON.parse(this.text.trim());
                    root.localArtUrl = d.isPlaceholder === false ? (d.artUrl || "") : "";
                } catch (e) {}
            }
        }
    }

    function refreshArt() {
        if (!targetPlayer || !active) return;
        if (usesSharedArt) {
            if (!MprisController.artUrl) MprisController.queueFetch();
        } else {
            artProc.running = false;
            artProc.running = true;
        }
    }

    // ── Position: read every frame while visible and playing (reads are local) ─
    property real livePos: 0
    function readPos() { livePos = targetPlayer ? Math.max(0, targetPlayer.position || 0) : 0; }
    FrameAnimation {
        running: root.active && root.isPlaying
        onTriggered: root.readPos()
    }

    Connections {
        target: root.targetPlayer
        function onPositionChanged() { root.readPos(); }
        function onPostTrackChanged() { root.readPos(); root.refreshArt(); }
        function onTrackArtUrlChanged() { root.refreshArt(); }
    }

    onTargetPlayerChanged: {
        readPos();
        refreshArt();
        updateLyricsSubscription();
    }

    // ── Lyrics ────────────────────────────────────────────────────────────────
    property bool lyricsSubscribed: false
    function updateLyricsSubscription() {
        if (root.active && !lyricsSubscribed) {
            lyricsSubscribed = true;
            Lyrics.customPlayer = root.targetPlayer;
            Lyrics.subscribe();
        } else if (!root.active && lyricsSubscribed) {
            lyricsSubscribed = false;
            Lyrics.customPlayer = null;
            Lyrics.unsubscribe();
        } else if (root.active) {
            Lyrics.customPlayer = root.targetPlayer;
        }
    }

    // Debounced "has lyrics": a track change briefly clears them while the next .lrc
    // loads, which must not make the pane flap.
    property bool lyricsReady: false
    Timer { id: lyricsOffTimer; interval: 450; onTriggered: root.lyricsReady = false }
    function syncLyricsReady() {
        if (Lyrics.hasLyrics) {
            lyricsOffTimer.stop();
            lyricsReady = true;
        } else if (!Lyrics.loading) {
            if (root.layoutAnimated) lyricsOffTimer.restart();
            else lyricsReady = false;
        }
    }
    Connections {
        target: Lyrics
        function onHasLyricsChanged() { root.syncLyricsReady(); }
        function onLoadingChanged() { root.syncLyricsReady(); }
    }

    // ── Layout state ──────────────────────────────────────────────────────────
    property bool eqOpen: false
    property bool lyricsHidden: false
    readonly property bool lyricsAvailable: lyricsReady && hasTrack
    readonly property string paneMode: eqOpen ? "eq" : ((lyricsAvailable && !lyricsHidden) ? "lyrics" : "none")
    property string paneContent: "lyrics"
    onPaneModeChanged: if (paneMode !== "none") paneContent = paneMode

    // The panel opens straight into its final layout; changes after that animate.
    property bool layoutAnimated: false
    Timer { id: settleTimer; interval: 420; onTriggered: root.layoutAnimated = true }

    property real split: paneMode === "none" ? 0 : 1
    Behavior on split {
        enabled: root.layoutAnimated
        NumberAnimation { duration: 680; easing.type: Easing.OutCubic }
    }

    readonly property real margin: s(22)
    readonly property real colTwoW: s(236)
    readonly property real colOneW: Math.min(width - margin * 2, s(400))
    readonly property real coverOne: Math.max(s(160), Math.min(s(270), height - s(290)))
    readonly property real colW: colOneW + (colTwoW - colOneW) * split
    readonly property real colX: (width - colOneW) / 2 + (margin - (width - colOneW) / 2) * split
    readonly property real coverSize: coverOne + (colTwoW - coverOne) * split
    readonly property real paneX: margin + colTwoW + s(28)
    readonly property real paneW: width - paneX - margin + s(4)

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    // Keys typed in the first moments after opening were meant for another window.
    property real openedAt: 0

    onActiveChanged: {
        updateLyricsSubscription();
        if (active) {
            openedAt = Date.now();
            forceActiveFocus();
            layoutAnimated = false;
            settleTimer.restart();
            syncLyricsReady();
            readPos();
            refreshArt();
        } else {
            settleTimer.stop();
            layoutAnimated = false;
            eqOpen = false;
        }
    }

    Component.onCompleted: {
        if (active) {
            forceActiveFocus();
            updateLyricsSubscription();
            settleTimer.restart();
            readPos();
            refreshArt();
        }
    }

    Component.onDestruction: {
        if (lyricsSubscribed) {
            lyricsSubscribed = false;
            Lyrics.customPlayer = null;
            Lyrics.unsubscribe();
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    function togglePlay() { if (targetPlayer && targetPlayer.canTogglePlaying) targetPlayer.togglePlaying(); }
    function seekBy(sec) {
        if (!hasTrack || !targetPlayer.canSeek) return;
        targetPlayer.position = Math.max(0, Math.min(trackLength - 1, livePos + sec));
    }
    function changeVolume(delta) {
        if (!targetPlayer || !targetPlayer.volumeSupported) return;
        targetPlayer.volume = Math.max(0, Math.min(1, Math.round((targetPlayer.volume + delta) * 100) / 100));
        volumeFlash.restart();
    }
    function toggleShuffle() { if (targetPlayer && targetPlayer.shuffleSupported) targetPlayer.shuffle = !targetPlayer.shuffle; }
    function cycleRepeat() {
        if (!targetPlayer || !targetPlayer.loopSupported) return;
        let l = targetPlayer.loopState;
        targetPlayer.loopState = l === MprisLoopState.None ? MprisLoopState.Playlist
            : (l === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None);
    }
    function openLibrary() {
        Quickshell.execDetached(["bash", "-c", "\"" + Caching.serpantinumDir + "/scripts/qs_manager.sh\" close; exec \"$HOME/.local/bin/glass-music\""]);
    }

    Keys.onPressed: (event) => {
        if (Date.now() - root.openedAt < 600) return;
        let k = event.key;
        if (k === Qt.Key_Space) { togglePlay(); event.accepted = true; }
        else if (k === Qt.Key_Left) { seekBy(-5); event.accepted = true; }
        else if (k === Qt.Key_Right) { seekBy(5); event.accepted = true; }
        else if (k === Qt.Key_Up) { changeVolume(0.05); event.accepted = true; }
        else if (k === Qt.Key_Down) { changeVolume(-0.05); event.accepted = true; }
        else if (k === Qt.Key_N) { if (targetPlayer && targetPlayer.canGoNext) targetPlayer.next(); event.accepted = true; }
        else if (k === Qt.Key_P) { if (targetPlayer && targetPlayer.canGoPrevious) targetPlayer.previous(); event.accepted = true; }
        else if (k === Qt.Key_S) { toggleShuffle(); event.accepted = true; }
        else if (k === Qt.Key_G) { SmartShuffle.start(); event.accepted = true; }
        else if (k === Qt.Key_F) { if (SmartShuffle.onLibrary && SmartShuffle.curFile !== "") SmartShuffle.toggleFav(); event.accepted = true; }
        else if (k === Qt.Key_R) { cycleRepeat(); event.accepted = true; }
        else if (k === Qt.Key_L) { if (eqOpen) eqOpen = false; else lyricsHidden = !lyricsHidden; event.accepted = true; }
        else if (k === Qt.Key_E) { eqOpen = !eqOpen; event.accepted = true; }
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            if (eqOpen) { eqOpen = false; lyricsHidden = false; } else eqOpen = true;
            event.accepted = true;
        }
    }

    // Shared colours
    readonly property color chip: Qt.alpha(ThemeBackend.text, 0.08)
    readonly property color chipHover: Qt.alpha(ThemeBackend.text, 0.16)
    readonly property color dim: Qt.alpha(ThemeBackend.text, 0.6)

    // ── Frame + blurred-cover backdrop ────────────────────────────────────────
    Rectangle {
        id: frame
        anchors.fill: parent
        radius: ThemeBackend.borderRadius
        color: ThemeBackend.base
    }

    Item {
        id: frameMask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: ThemeBackend.borderRadius; color: "black" }
    }

    Item {
        id: backdrop
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: frameMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        Item {
            id: blurSource
            anchors.fill: parent
            anchors.margins: -root.s(40)
            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: 64
                saturation: 0.2
                autoPaddingEnabled: false
            }

            property bool showA: true
            property string current: ""
            function swap(src) {
                if (src === current) return;
                current = src;
                if (showA) { bgB.source = src; showA = false; }
                else { bgA.source = src; showA = true; }
            }
            Connections {
                target: root
                function onArtSourceChanged() { blurSource.swap(root.artSource); }
            }
            Component.onCompleted: swap(root.artSource)

            Image {
                id: bgA
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(160, 160)
                asynchronous: true
                opacity: blurSource.showA && status === Image.Ready && source != "" ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            }
            Image {
                id: bgB
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(160, 160)
                asynchronous: true
                opacity: !blurSource.showA && status === Image.Ready && source != "" ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            }
        }

        // Scrim: keeps text readable on any cover and ties the panel to the theme.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.alpha(ThemeBackend.base, 0.42) }
                GradientStop { position: 0.55; color: Qt.alpha(ThemeBackend.base, 0.58) }
                GradientStop { position: 1.0; color: Qt.alpha(ThemeBackend.base, 0.80) }
            }
        }
    }

    // Liquid-glass edge, the same as the bar islands: a hairline rim that is bright at
    // the top-left and fades to the bottom-right, plus a soft sheen (bar/GlassPill.qml).
    BarGlass.GlassPill {
        anchors.fill: parent
        radius: ThemeBackend.borderRadius
        tintAlpha: 0.0
        raised: false
        lit: true
    }

    // ── Source chip (top right): which player; click to switch when several ──
    Rectangle {
        id: sourceChip
        visible: root.hasPlayer
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: root.s(14)
        anchors.rightMargin: root.s(14)
        height: root.s(24)
        width: sourceRow.implicitWidth + root.s(18)
        radius: height / 2
        color: sourceMouse.containsMouse && root.playerList.length > 1 ? root.chipHover : root.chip
        z: 5
        Behavior on color { ColorAnimation { duration: 180 } }

        Row {
            id: sourceRow
            anchors.centerIn: parent
            spacing: root.s(6)
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.isPlaying ? "󰝚" : "󰎊"
                font.family: ThemeBackend.iconFont
                font.pixelSize: root.s(12)
                color: root.isPlaying ? ThemeBackend.mauve : root.dim
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.sourceName
                font.family: ThemeBackend.fontFamily
                font.pixelSize: root.s(11)
                font.weight: Font.DemiBold
                color: root.dim
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.playerList.length > 1
                text: "󰁔"
                font.family: ThemeBackend.iconFont
                font.pixelSize: root.s(11)
                color: root.dim
            }
        }
        MouseArea {
            id: sourceMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.playerList.length > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.cyclePlayer()
        }
    }

    // ── Cover ─────────────────────────────────────────────────────────────────
    Item {
        id: cover
        x: root.colX + (root.colW - root.coverSize) / 2
        y: root.margin
        width: root.coverSize
        height: root.coverSize
        readonly property real radius: Math.max(root.s(14), root.coverSize * 0.075)

        scale: coverMouse.pressed ? 0.97 : (root.isPlaying || !root.hasTrack ? 1.0 : 0.94)
        Behavior on scale { NumberAnimation { duration: 520; easing.type: Easing.OutQuint } }

        RectangularShadow {
            anchors.fill: parent
            radius: cover.radius
            blur: root.s(34)
            spread: 0
            offset.y: root.s(12)
            color: Qt.rgba(0, 0, 0, 0.5)
            opacity: root.hasTrack ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 400 } }
        }

        Rectangle {
            anchors.fill: parent
            radius: cover.radius
            color: Qt.alpha(ThemeBackend.text, 0.06)
            border.width: 1
            border.color: Qt.alpha(ThemeBackend.text, 0.06)

            Text {
                anchors.centerIn: parent
                text: "󰝚"
                font.family: ThemeBackend.iconFont
                font.pixelSize: parent.width * 0.3
                color: Qt.alpha(ThemeBackend.text, 0.25)
                visible: !coverA.shown && !coverB.shown
            }
        }

        Item {
            id: coverMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: cover.radius; color: "black"; antialiasing: true }
        }

        Item {
            id: coverArt
            anchors.fill: parent
            layer.enabled: true
            layer.smooth: true
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
                if (showA) { coverB.source = src; showA = false; }
                else { coverA.source = src; showA = true; }
            }
            Connections {
                target: root
                function onArtSourceChanged() { coverArt.swap(root.artSource); }
            }
            Component.onCompleted: swap(root.artSource)

            Image {
                id: coverA
                readonly property bool shown: coverArt.showA && status === Image.Ready && source != ""
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                mipmap: true
                opacity: shown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 550; easing.type: Easing.InOutQuad } }
            }
            Image {
                id: coverB
                readonly property bool shown: !coverArt.showA && status === Image.Ready && source != ""
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                mipmap: true
                opacity: shown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 550; easing.type: Easing.InOutQuad } }
            }

            // Hover: a soft scrim with the play/pause glyph.
            Rectangle {
                anchors.fill: parent
                color: "#000000"
                opacity: coverMouse.containsMouse && root.hasPlayer ? 0.32 : 0
                Behavior on opacity { NumberAnimation { duration: 220 } }
            }
        }

        Text {
            anchors.centerIn: parent
            text: root.isPlaying ? "󰏤" : "󰐊"
            font.family: ThemeBackend.iconFont
            font.pixelSize: root.coverSize * 0.2
            color: "#ffffff"
            opacity: coverMouse.containsMouse && root.hasPlayer ? 0.95 : 0
            scale: opacity > 0.5 ? 1 : 0.8
            Behavior on opacity { NumberAnimation { duration: 220 } }
            Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack } }
        }

        // Volume bubble (wheel over the cover, ↑/↓).
        Rectangle {
            id: volumeBubble
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.s(12)
            width: volumeBubbleRow.implicitWidth + root.s(20)
            height: root.s(26)
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.55)
            opacity: volumeFlash.running ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 200 } }
            Row {
                id: volumeBubbleRow
                anchors.centerIn: parent
                spacing: root.s(6)
                Text {
                    text: "󰕾"
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: root.s(13)
                    color: "#ffffff"
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: (root.targetPlayer ? Math.round(root.targetPlayer.volume * 100) : 0) + "%"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.s(12)
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                    color: "#ffffff"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
        Timer { id: volumeFlash; interval: 1200 }

        MouseArea {
            id: coverMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.hasPlayer ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.hasPlayer ? root.togglePlay() : root.openLibrary()
            onWheel: (wheel) => {
                let d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y * 2;
                if (d !== 0) root.changeVolume(d > 0 ? 0.05 : -0.05);
            }
        }
    }

    // ── Title / artist / album ────────────────────────────────────────────────
    Column {
        id: info
        x: root.colX
        y: root.margin + root.coverSize + root.s(18)
        width: root.colW
        spacing: root.s(3)

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.hasTrack ? root.title : (typeof I18n !== "undefined" ? I18n.t("music.nothing_playing", "Nothing playing") : "Nothing playing")
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(19)
            font.weight: Font.Bold
            color: ThemeBackend.text
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            lineHeight: 1.05
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
            text: root.hasTrack ? root.artist : (root.hasPlayer ? "" : "Open the library to pick something")
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(14)
            font.weight: Font.DemiBold
            color: root.hasTrack ? Qt.lighter(ThemeBackend.mauve, 1.05) : root.dim
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
            text: root.album + (root.album !== "" && root.year !== "" ? "  ·  " : "") + root.year
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(12)
            font.weight: Font.Medium
            color: Qt.alpha(ThemeBackend.text, 0.5)
            elide: Text.ElideRight
        }
        // Why smart shuffle picked this track.
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: SmartShuffle.shown && root.hasTrack && SmartShuffle.why !== ""
            text: SmartShuffle.glyphOf(SmartShuffle.style) + "  My Vibe" + (SmartShuffle.style !== "default" ? " · " + SmartShuffle.styleLabel : "") + "  ·  " + SmartShuffle.why
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(11)
            font.weight: Font.Medium
            color: Qt.alpha(ThemeBackend.mauve, 0.85)
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            topPadding: root.s(3)
        }
    }

    // ── Bottom block: progress, transport, utilities ──────────────────────────
    Item {
        id: bottomRow
        x: root.colX
        width: root.colW
        height: root.s(30)
        y: root.height - root.margin - height

        // Volume
        Row {
            id: volumeRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.s(8)
            visible: root.hasPlayer && root.targetPlayer.volumeSupported
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    let v = root.targetPlayer ? root.targetPlayer.volume : 0;
                    return v <= 0.001 ? "󰝟" : (v < 0.34 ? "󰕿" : (v < 0.67 ? "󰖀" : "󰕾"));
                }
                font.family: ThemeBackend.iconFont
                font.pixelSize: root.s(15)
                color: root.dim
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!root.targetPlayer) return;
                        if (root.targetPlayer.volume > 0.001) { volumeRow.lastVolume = root.targetPlayer.volume; root.targetPlayer.volume = 0; }
                        else root.targetPlayer.volume = volumeRow.lastVolume > 0 ? volumeRow.lastVolume : 0.3;
                    }
                }
            }
            MusicSeekBar {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(root.s(60), Math.min(root.s(110), bottomRow.width - actionsRow.width - root.s(40)))
                value: root.targetPlayer ? root.targetPlayer.volume : 0
                from: 0
                to: 1
                trackHeight: root.s(3)
                hoverTrackHeight: root.s(5)
                knobSize: root.s(10)
                fillColor: Qt.alpha(ThemeBackend.text, 0.75)
                onMoved: (v) => { if (root.targetPlayer) root.targetPlayer.volume = Math.round(v * 100) / 100; }
                onCommitted: (v) => { if (root.targetPlayer) root.targetPlayer.volume = Math.round(v * 100) / 100; }
            }
            property real lastVolume: 0.5
        }

        Row {
            id: actionsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.s(4)

            IconButton {
                visible: SmartShuffle.onLibrary && SmartShuffle.curFile !== "" && root.hasTrack
                width: root.s(28)
                height: root.s(28)
                cornerRadius: Math.round(width / 2)
                buttonIcon: SmartShuffle.fav ? "󰓎" : "󰓒"
                iconFontSize: root.s(14)
                accentColor: SmartShuffle.fav ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.4 : 0.28) : (isHoveredOrHighlighted ? root.chipHover : root.chip)
                textColor: SmartShuffle.fav ? ThemeBackend.mauve : (isHoveredOrHighlighted ? ThemeBackend.text : root.dim)
                onClicked: SmartShuffle.toggleFav()
            }
            IconButton {
                readonly property bool on: SmartShuffle.shown
                width: root.s(28)
                height: root.s(28)
                cornerRadius: Math.round(width / 2)
                buttonIcon: SmartShuffle.glyphOf(SmartShuffle.shownStyle)
                iconFontSize: root.s(14)
                accentColor: on ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.4 : 0.28) : (isHoveredOrHighlighted ? root.chipHover : root.chip)
                textColor: on ? ThemeBackend.mauve : (isHoveredOrHighlighted ? ThemeBackend.text : root.dim)
                opacity: SmartShuffle.busy ? 0.6 : 1
                Behavior on opacity { NumberAnimation { duration: 180 } }
                onClicked: SmartShuffle.start()
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: SmartShuffle.stop()
                }
            }
            IconButton {
                visible: root.lyricsAvailable
                width: root.s(28)
                height: root.s(28)
                cornerRadius: Math.round(width / 2)
                buttonIcon: "󰍰"
                iconFontSize: root.s(14)
                accentColor: root.paneMode === "lyrics" ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.4 : 0.28) : (isHoveredOrHighlighted ? root.chipHover : root.chip)
                textColor: root.paneMode === "lyrics" ? ThemeBackend.text : root.dim
                onClicked: { if (root.eqOpen) { root.eqOpen = false; root.lyricsHidden = false; } else root.lyricsHidden = !root.lyricsHidden; }
            }
            IconButton {
                width: root.s(28)
                height: root.s(28)
                cornerRadius: Math.round(width / 2)
                buttonIcon: "󰺢"
                iconFontSize: root.s(14)
                accentColor: root.eqOpen ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.4 : 0.28) : (isHoveredOrHighlighted ? root.chipHover : root.chip)
                textColor: root.eqOpen ? ThemeBackend.text : root.dim
                onClicked: root.eqOpen = !root.eqOpen
            }
            IconButton {
                width: root.s(28)
                height: root.s(28)
                cornerRadius: Math.round(width / 2)
                buttonIcon: "󰲸"
                iconFontSize: root.s(14)
                accentColor: isHoveredOrHighlighted ? root.chipHover : root.chip
                textColor: isHoveredOrHighlighted ? ThemeBackend.text : root.dim
                onClicked: root.openLibrary()
            }
        }
    }

    Row {
        id: transport
        x: root.colX + (root.colW - width) / 2
        y: bottomRow.y - root.s(14) - height
        height: root.s(54)
        spacing: root.s(10)

        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            width: root.s(34)
            height: root.s(34)
            cornerRadius: Math.round(width / 2)
            visible: root.hasPlayer && root.targetPlayer.shuffleSupported
            readonly property bool isOn: root.hasPlayer && root.targetPlayer.shuffle
            buttonIcon: isOn ? "󰒝" : "󰒞"
            iconFontSize: root.s(15)
            accentColor: isOn ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.34 : 0.22) : (isHoveredOrHighlighted ? root.chipHover : "transparent")
            textColor: isOn ? ThemeBackend.mauve : root.dim
            onClicked: root.toggleShuffle()
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            width: root.s(42)
            height: root.s(42)
            cornerRadius: Math.round(width / 2)
            buttonIcon: "󰒮"
            iconFontSize: root.s(16)
            accentColor: isHoveredOrHighlighted ? root.chipHover : root.chip
            textColor: ThemeBackend.text
            enabled: root.hasPlayer && root.targetPlayer.canGoPrevious
            onClicked: root.targetPlayer.previous()
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            width: root.s(54)
            height: root.s(54)
            cornerRadius: Math.round(width / 2)
            buttonIcon: root.isPlaying ? "󰏤" : "󰐊"
            iconFontSize: root.s(22)
            accentColor: isHoveredOrHighlighted ? Qt.lighter(ThemeBackend.mauve, 1.08) : ThemeBackend.mauve
            textColor: ThemeBackend.base
            enabled: root.hasPlayer && root.targetPlayer.canTogglePlaying
            onClicked: root.togglePlay()
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            width: root.s(42)
            height: root.s(42)
            cornerRadius: Math.round(width / 2)
            buttonIcon: "󰒭"
            iconFontSize: root.s(16)
            accentColor: isHoveredOrHighlighted ? root.chipHover : root.chip
            textColor: ThemeBackend.text
            enabled: root.hasPlayer && root.targetPlayer.canGoNext
            onClicked: root.targetPlayer.next()
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            width: root.s(34)
            height: root.s(34)
            cornerRadius: Math.round(width / 2)
            visible: root.hasPlayer && root.targetPlayer.loopSupported
            readonly property int mode: root.hasPlayer ? root.targetPlayer.loopState : MprisLoopState.None
            readonly property bool isOn: mode !== MprisLoopState.None
            buttonIcon: mode === MprisLoopState.Track ? "󰑘" : (isOn ? "󰑖" : "󰑗")
            iconFontSize: root.s(15)
            accentColor: isOn ? Qt.alpha(ThemeBackend.mauve, isHoveredOrHighlighted ? 0.34 : 0.22) : (isHoveredOrHighlighted ? root.chipHover : "transparent")
            textColor: isOn ? ThemeBackend.mauve : root.dim
            onClicked: root.cycleRepeat()
        }
    }

    Item {
        id: timeRow
        x: root.colX
        width: root.colW
        height: root.s(16)
        y: transport.y - root.s(6) - height
        Text {
            anchors.left: parent.left
            text: root.hasTrack ? root.formatTime(seekBar.shownValue) : "0:00"
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(11)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: root.dim
        }
        Text {
            anchors.right: parent.right
            text: root.trackLength > 0 ? "-" + root.formatTime(root.trackLength - seekBar.shownValue) : "0:00"
            font.family: ThemeBackend.fontFamily
            font.pixelSize: root.s(11)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: root.dim
        }
    }

    MusicSeekBar {
        id: seekBar
        x: root.colX
        width: root.colW
        y: timeRow.y - root.s(4) - height
        height: root.s(16)
        from: 0
        to: Math.max(1, root.trackLength)
        value: root.livePos
        interactive: root.hasTrack && root.targetPlayer.canSeek
        trackHeight: root.s(4)
        hoverTrackHeight: root.s(6)
        knobSize: root.s(13)
        fillColor: root.isPlaying ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.6)
        onCommitted: (v) => { if (root.targetPlayer && root.targetPlayer.canSeek) root.targetPlayer.position = v; }
    }

    // ── Right pane: synced lyrics or the equalizer ────────────────────────────
    Item {
        id: pane
        x: root.paneX + root.s(36) * (1 - root.split)
        y: root.margin + root.s(18)
        width: root.paneW
        height: root.height - root.margin * 2 - root.s(18)
        opacity: root.split
        visible: opacity > 0.01

        SyncedLyrics {
            id: lyricsView
            anchors.fill: parent
            player: root.targetPlayer
            fontSize: root.s(19)
            lineSpacing: root.s(13)
            anchorRatio: 0.34
            activeColor: ThemeBackend.text
            inactiveColor: ThemeBackend.text
            accentColor: ThemeBackend.mauve
            opacity: root.paneContent === "lyrics" ? 1 : 0
            visible: opacity > 0.01 && root.lyricsAvailable
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }

        MusicEqPane {
            id: eqPane
            anchors.fill: parent
            anchors.topMargin: root.s(10)
            anchors.bottomMargin: root.s(6)
            active: root.active && root.paneContent === "eq"
            chipColor: root.chip
            chipHoverColor: root.chipHover
            opacity: root.paneContent === "eq" ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
    }
}
