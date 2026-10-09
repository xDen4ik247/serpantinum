import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris
import "../reusables"
import "../media"
import "../bar" as BarGlass
import "../"

PanelWindow {
    id: sideMusicPopout

    screen: SideMusicController.screen

    WlrLayershell.namespace: "sidemusic"
    WlrLayershell.layer: WlrLayer.Top
    focusable: false
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    mask: Region {
        item: (sideMusicPopout.isVisible || menuContainer.animProgress > 0.001) ? menuContainer : null
    }

    // Liquid glass (modular bars): niri blurs what is behind the card; the card itself is a
    // translucent tint with the bar's rim (bar/GlassPill.qml). Solid bars keep upstream's look.
    readonly property bool glassCard: !isSolid
    BackgroundEffect.blurRegion: glassCard ? glassRegion : null
    // Window coordinates of the card (the window is full-screen), so the blur follows the
    // slide-in; an `item:` region would not see its parent moving.
    Region {
        id: glassRegion
        x: Math.round(menuContainer.x)
        y: Math.round(menuContainer.y)
        width: Math.round(menuContainer.width)
        height: Math.round(menuContainer.height)
        radius: sideMusicPopout.cornerRadius
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    function s(val) { return (typeof Scaler !== "undefined") ? Scaler.s(val) : val; }

    property bool isVisible: SideMusicController.isVisible
    property real targetX: SideMusicController.targetX
    property real targetY: SideMusicController.targetY
    property bool alignRight: SideMusicController.alignRight
    property bool alignBottom: SideMusicController.alignBottom
    property bool isSideBar: SideMusicController.isSideBar

    property int configRevision: 0

    Connections {
        target: (typeof Config !== "undefined") ? Config : null
        function onSettingsLoaded() {
            SideMusicController.hide();
            sideMusicPopout.configRevision++;
        }
    }

    property string barStyle: {
        let dummy = configRevision;
        if (typeof Config === "undefined" || !Config.rawSettings || !Config.rawSettings.bar) return "modular";
        let s = Config.rawSettings.bar.style;
        if (typeof s === "string") return s;
        if (s && typeof s === "object") {
            if (s.fill || s.mode === "fill") return "fill";
            if (s.solid || s.mode === "solid") return "solid";
        }
        return "modular";
    }

    onBarStyleChanged: {
        SideMusicController.hide();
    }

    property bool isFill: barStyle === "fill"
    property bool isSolid: barStyle === "solid" || barStyle === "fill"

    property real barHeight: {
        let dummy = configRevision;
        return (typeof Config !== "undefined" && Config.rawSettings && Config.rawSettings.bar && Config.rawSettings.bar.height) ? s(Config.rawSettings.bar.height) : s(40);
    }
    property real cornerRadius: ThemeBackend.borderRadius || s(12)
    property real menuMargin: isSolid ? 0 : s(8)

    visible: isVisible || menuContainer.animProgress > 0.001

    property real menuWidth: s(300)
    property real menuHeight: s(170)

    property var playerList: {
        if (!Mpris.players || !Mpris.players.values) return [];
        let list = [];
        let vals = Mpris.players.values;
        for (let i = 0; i < vals.length; i++) {
            if (vals[i]) list.push(vals[i]);
        }
        return list;
    }

    property var manualPlayer: null

    property var targetPlayer: {
        if (manualPlayer) {
            for (let i = 0; i < playerList.length; i++) {
                if (playerList[i] === manualPlayer) return manualPlayer;
            }
        }
        return MprisController.activePlayer;
    }

    property var playerOptions: {
        let list = playerList;
        let names = [];
        let counts = {};
        for (let i = 0; i < list.length; i++) {
            let base = list[i].identity || list[i].desktopEntry || ("Player " + (i + 1));
            counts[base] = (counts[base] || 0) + 1;
        }
        for (let i = 0; i < list.length; i++) {
            let p = list[i];
            let base = p.identity || p.desktopEntry || ("Player " + (i + 1));
            if (counts[base] > 1 && p.trackTitle) {
                names.push(base + " (" + p.trackTitle + ")");
            } else {
                names.push(base);
            }
        }
        return names;
    }

    property int currentPlayerIndex: {
        if (!targetPlayer) return 0;
        for (let i = 0; i < playerList.length; i++) {
            if (playerList[i] === targetPlayer) return i;
        }
        return 0;
    }

    function selectPlayerByIndex(idx) {
        if (idx >= 0 && idx < playerList.length) {
            manualPlayer = playerList[idx];
        }
    }

    property bool isMediaActive: targetPlayer !== null && targetPlayer.playbackState !== MprisPlaybackState.Stopped && targetPlayer.trackTitle !== ""
    property bool isPlaying: targetPlayer ? (targetPlayer.playbackState === MprisPlaybackState.Playing || targetPlayer.isPlaying) : false
    
    property real currentLivePosition: {
        if (!targetPlayer) return 0.0;
        let pos = (targetPlayer === MprisController.activePlayer) ? MprisController.livePosition : targetPlayer.position;
        return (typeof pos === "number" && !isNaN(pos)) ? pos : 0.0;
    }

    Connections {
        target: sideMusicPopout.targetPlayer
        function onPositionChanged() {
            if (sideMusicPopout.targetPlayer && sideMusicPopout.targetPlayer !== MprisController.activePlayer) {
                let pos = sideMusicPopout.targetPlayer.position;
                sideMusicPopout.currentLivePosition = (typeof pos === "number" && !isNaN(pos)) ? pos : 0.0;
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: sideMusicPopout.visible && sideMusicPopout.targetPlayer !== null && sideMusicPopout.isPlaying && sideMusicPopout.targetPlayer !== MprisController.activePlayer
        onTriggered: {
            if (sideMusicPopout.targetPlayer) {
                if (typeof sideMusicPopout.targetPlayer.positionChanged === "function") {
                    sideMusicPopout.targetPlayer.positionChanged();
                }
                let pos = sideMusicPopout.targetPlayer.position;
                sideMusicPopout.currentLivePosition = (typeof pos === "number" && !isNaN(pos)) ? pos : 0.0;
            }
        }
    }

    function formatTime(sec) {
        sec = Math.floor(sec || 0);
        let m = Math.floor(sec / 60), s = sec % 60;
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
    }

    readonly property string artSource: {
        if (!targetPlayer) return "";
        let u = (targetPlayer === MprisController.activePlayer) ? MprisController.artUrl : (targetPlayer.trackArtUrl || "");
        if (!u) return "";
        return (u.startsWith("file://") || u.startsWith("http")) ? u : "file://" + u;
    }

    // The line being sung, shown while the card is open (Lyrics singleton: the local
    // .lrc for library tracks, online lyrics for other players).
    property bool lyricsSubscribed: false
    onIsVisibleChanged: {
        if (isVisible && !lyricsSubscribed) {
            lyricsSubscribed = true;
            Lyrics.subscribe();
        } else if (!isVisible && lyricsSubscribed) {
            lyricsSubscribed = false;
            Lyrics.unsubscribe();
        }
    }
    Component.onDestruction: if (lyricsSubscribed) Lyrics.unsubscribe()
    readonly property string currentLyric: {
        if (!lyricsSubscribed || !Lyrics.hasLyrics || Lyrics.currentIndex < 0) return "";
        let l = Lyrics.lyrics[Lyrics.currentIndex];
        return (l && l.text) ? l.text : "";
    }

    property real clampedX: {
        let w = menuWidth;
        let x = 0;
        if (isSideBar) {
            if (alignRight) {
                let barEdge = (targetX > sideMusicPopout.width / 2) ? targetX : (sideMusicPopout.width - barHeight);
                x = isSolid ? (sideMusicPopout.width - barHeight - w) : (barEdge - w - menuMargin);
            } else {
                let barEdge = (targetX > 0 && targetX < sideMusicPopout.width / 2) ? targetX : barHeight;
                x = isSolid ? barHeight : (barEdge + menuMargin);
            }
        } else {
            x = targetX - (w / 2);
        }
        let edgeBound = (isSolid && !isSideBar) ? (cornerRadius + s(4)) : s(8);
        return Math.max(edgeBound, Math.min(sideMusicPopout.width - w - edgeBound, x));
    }

    property real clampedY: {
        let h = menuHeight;
        let y = 0;
        if (isSideBar) {
            y = targetY - (h / 2) + s(4);
        } else {
            if (alignBottom) {
                let barEdge = (targetY > sideMusicPopout.height / 2) ? targetY : (sideMusicPopout.height - barHeight);
                y = isSolid ? (sideMusicPopout.height - barHeight - h) : (barEdge - h - menuMargin);
            } else {
                let barEdge = (targetY > 0 && targetY < sideMusicPopout.height / 2) ? targetY : barHeight;
                y = isSolid ? barHeight : (barEdge + menuMargin);
            }
        }
        let edgeBound = (isSolid && isSideBar) ? (cornerRadius + s(4)) : s(8);
        return Math.max(edgeBound, Math.min(sideMusicPopout.height - h - edgeBound, y));
    }

    Item {
        id: menuContainer

        property real animProgress: sideMusicPopout.isVisible ? 1.0 : 0.0
        Behavior on animProgress {
            NumberAnimation {
                duration: sideMusicPopout.isVisible ? 280 : 220
                easing.type: Easing.OutCubic
            }
        }

        x: {
            if (sideMusicPopout.isSolid) {
                if (sideMusicPopout.isSideBar) {
                    if (sideMusicPopout.alignRight) {
                        return sideMusicPopout.clampedX + (sideMusicPopout.menuWidth - width);
                    }
                    return sideMusicPopout.clampedX;
                }
                return sideMusicPopout.clampedX;
            }
            let slideOffset = sideMusicPopout.s(16) * (1.0 - animProgress);
            if (sideMusicPopout.isSideBar) {
                return sideMusicPopout.alignRight ? (sideMusicPopout.clampedX + slideOffset) : (sideMusicPopout.clampedX - slideOffset);
            }
            return sideMusicPopout.clampedX;
        }

        y: {
            if (sideMusicPopout.isSolid) {
                if (!sideMusicPopout.isSideBar) {
                    if (sideMusicPopout.alignBottom) {
                        return sideMusicPopout.clampedY + (sideMusicPopout.menuHeight - height);
                    }
                    return sideMusicPopout.clampedY;
                }
                return sideMusicPopout.clampedY;
            }
            let slideOffset = sideMusicPopout.s(16) * (1.0 - animProgress);
            if (!sideMusicPopout.isSideBar) {
                return sideMusicPopout.alignBottom ? (sideMusicPopout.clampedY + slideOffset) : (sideMusicPopout.clampedY - slideOffset);
            }
            return sideMusicPopout.clampedY;
        }

        width: {
            if (sideMusicPopout.isSolid && sideMusicPopout.isSideBar) {
                return sideMusicPopout.menuWidth * animProgress;
            }
            return sideMusicPopout.menuWidth;
        }

        height: {
            if (sideMusicPopout.isSolid && !sideMusicPopout.isSideBar) {
                return sideMusicPopout.menuHeight * animProgress;
            }
            return sideMusicPopout.menuHeight;
        }

        opacity: animProgress
        scale: !sideMusicPopout.isSolid ? (0.92 + (0.08 * animProgress)) : 1.0

        transformOrigin: {
            if (sideMusicPopout.isSideBar) {
                return sideMusicPopout.alignRight ? Item.Right : Item.Left;
            }
            return sideMusicPopout.alignBottom ? Item.Bottom : Item.Top;
        }

        Shape {
            visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && !sideMusicPopout.alignBottom && menuContainer.height > sideMusicPopout.cornerRadius
            x: -sideMusicPopout.cornerRadius
            y: 0
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: 0
                startY: 0
                PathLine { x: sideMusicPopout.cornerRadius; y: 0 }
                PathLine { x: sideMusicPopout.cornerRadius; y: sideMusicPopout.cornerRadius }
                PathArc {
                    x: 0
                    y: 0
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Counterclockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && !sideMusicPopout.alignBottom && menuContainer.height > sideMusicPopout.cornerRadius
            x: parent.width
            y: 0
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: sideMusicPopout.cornerRadius
                startY: 0
                PathLine { x: 0; y: 0 }
                PathLine { x: 0; y: sideMusicPopout.cornerRadius }
                PathArc {
                    x: sideMusicPopout.cornerRadius
                    y: 0
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Clockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && sideMusicPopout.alignBottom && menuContainer.height > sideMusicPopout.cornerRadius
            x: -sideMusicPopout.cornerRadius
            y: parent.height - sideMusicPopout.cornerRadius
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: 0
                startY: sideMusicPopout.cornerRadius
                PathLine { x: sideMusicPopout.cornerRadius; y: sideMusicPopout.cornerRadius }
                PathLine { x: 0; y: sideMusicPopout.cornerRadius }
                PathArc {
                    x: 0
                    y: sideMusicPopout.cornerRadius
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Clockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && sideMusicPopout.alignBottom && menuContainer.height > sideMusicPopout.cornerRadius
            x: parent.width
            y: parent.height - sideMusicPopout.cornerRadius
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: sideMusicPopout.cornerRadius
                startY: sideMusicPopout.cornerRadius
                PathLine { x: 0; y: sideMusicPopout.cornerRadius }
                PathLine { x: 0; y: 0 }
                PathArc {
                    x: sideMusicPopout.cornerRadius
                    y: sideMusicPopout.cornerRadius
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Counterclockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && !sideMusicPopout.alignRight && menuContainer.width > sideMusicPopout.cornerRadius
            x: 0
            y: -sideMusicPopout.cornerRadius
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: 0
                startY: 0
                PathLine { x: 0; y: sideMusicPopout.cornerRadius }
                PathLine { x: sideMusicPopout.cornerRadius; y: sideMusicPopout.cornerRadius }
                PathArc {
                    x: 0
                    y: 0
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Clockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && !sideMusicPopout.alignRight && menuContainer.width > sideMusicPopout.cornerRadius
            x: 0
            y: parent.height
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: 0
                startY: sideMusicPopout.cornerRadius
                PathLine { x: 0; y: 0 }
                PathLine { x: sideMusicPopout.cornerRadius; y: 0 }
                PathArc {
                    x: 0
                    y: sideMusicPopout.cornerRadius
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Counterclockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && sideMusicPopout.alignRight && menuContainer.width > sideMusicPopout.cornerRadius
            x: parent.width - sideMusicPopout.cornerRadius
            y: -sideMusicPopout.cornerRadius
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: sideMusicPopout.cornerRadius
                startY: 0
                PathLine { x: sideMusicPopout.cornerRadius; y: sideMusicPopout.cornerRadius }
                PathLine { x: 0; y: sideMusicPopout.cornerRadius }
                PathArc {
                    x: sideMusicPopout.cornerRadius
                    y: 0
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Counterclockwise
                }
            }
        }

        Shape {
            visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && sideMusicPopout.alignRight && menuContainer.width > sideMusicPopout.cornerRadius
            x: parent.width - sideMusicPopout.cornerRadius
            y: parent.height
            width: sideMusicPopout.cornerRadius
            height: sideMusicPopout.cornerRadius
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                fillColor: ThemeBackend.base
                strokeColor: "transparent"
                startX: sideMusicPopout.cornerRadius
                startY: sideMusicPopout.cornerRadius
                PathLine { x: sideMusicPopout.cornerRadius; y: 0 }
                PathLine { x: 0; y: 0 }
                PathArc {
                    x: sideMusicPopout.cornerRadius
                    y: sideMusicPopout.cornerRadius
                    radiusX: sideMusicPopout.cornerRadius
                    radiusY: sideMusicPopout.cornerRadius
                    direction: PathArc.Clockwise
                }
            }
        }

        RectangularShadow {
            anchors.fill: menuBox
            visible: sideMusicPopout.glassCard
            radius: sideMusicPopout.cornerRadius
            blur: sideMusicPopout.s(24)
            offset.y: sideMusicPopout.s(6)
            color: Qt.rgba(0, 0, 0, 0.35)
        }

        Rectangle {
            id: menuBox
            anchors.fill: parent
            color: sideMusicPopout.glassCard ? Qt.alpha(ThemeBackend.base, 0.5) : ThemeBackend.base
            radius: sideMusicPopout.cornerRadius
            border.width: 0
            border.color: "transparent"
            clip: true

            Rectangle {
                visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && !sideMusicPopout.alignBottom
                x: 0
                y: 0
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && !sideMusicPopout.alignBottom
                x: parent.width - sideMusicPopout.cornerRadius
                y: 0
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && sideMusicPopout.alignBottom
                x: 0
                y: parent.height - sideMusicPopout.cornerRadius
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && !sideMusicPopout.isSideBar && sideMusicPopout.alignBottom
                x: parent.width - sideMusicPopout.cornerRadius
                y: parent.height - sideMusicPopout.cornerRadius
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && !sideMusicPopout.alignRight
                x: 0
                y: 0
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && !sideMusicPopout.alignRight
                x: 0
                y: parent.height - sideMusicPopout.cornerRadius
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && sideMusicPopout.alignRight
                x: parent.width - sideMusicPopout.cornerRadius
                y: 0
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            Rectangle {
                visible: sideMusicPopout.isSolid && sideMusicPopout.isSideBar && sideMusicPopout.alignRight
                x: parent.width - sideMusicPopout.cornerRadius
                y: parent.height - sideMusicPopout.cornerRadius
                width: sideMusicPopout.cornerRadius
                height: sideMusicPopout.cornerRadius
                color: ThemeBackend.base
            }

            HoverHandler {
                id: menuHoverHandler
                onHoveredChanged: {
                    SideMusicController.menuHovered = hovered;
                    if (hovered) {
                        SideMusicController.cancelHide();
                    } else {
                        SideMusicController.requestHide();
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                preventStealing: true
            }

            // Soft blur of the cover behind the card (modular bars only; the solid
            // style keeps upstream's flush, opaque look).
            Item {
                id: popBackdrop
                anchors.fill: parent
                visible: sideMusicPopout.glassCard
                opacity: (sideMusicPopout.isMediaActive && sideMusicPopout.artSource !== "") ? 0.55 : 0
                Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                layer.enabled: visible
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: popMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }

                Image {
                    anchors.fill: parent
                    anchors.margins: -sideMusicPopout.s(30)
                    source: sideMusicPopout.isMediaActive ? sideMusicPopout.artSource : ""
                    sourceSize: Qt.size(120, 120)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blur: 1.0
                        blurMax: 48
                        autoPaddingEnabled: false
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    color: Qt.alpha(ThemeBackend.base, 0.35)
                }
            }

            BarGlass.GlassPill {
                anchors.fill: parent
                visible: sideMusicPopout.glassCard
                radius: sideMusicPopout.cornerRadius
                tintAlpha: 0.0
                raised: false
                lit: menuHoverHandler.hovered
            }

            Item {
                id: popMask
                anchors.fill: parent
                visible: false
                layer.enabled: true
                Rectangle { anchors.fill: parent; radius: sideMusicPopout.cornerRadius; color: "black" }
            }

            Item {
                id: card
                width: sideMusicPopout.menuWidth - sideMusicPopout.s(28)
                height: sideMusicPopout.menuHeight - sideMusicPopout.s(24)
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: (sideMusicPopout.isSideBar && sideMusicPopout.alignRight) ? undefined : parent.left
                anchors.right: (sideMusicPopout.isSideBar && sideMusicPopout.alignRight) ? parent.right : undefined
                anchors.leftMargin: sideMusicPopout.s(14)
                anchors.rightMargin: sideMusicPopout.s(14)

                // Cover + titles; a click opens the music panel.
                Item {
                    id: header
                    width: parent.width
                    height: sideMusicPopout.s(54)

                    Item {
                        id: thumb
                        width: header.height
                        height: header.height
                        readonly property real radius: sideMusicPopout.s(12)

                        Rectangle {
                            anchors.fill: parent
                            radius: thumb.radius
                            color: Qt.alpha(ThemeBackend.text, 0.08)
                            Text {
                                anchors.centerIn: parent
                                text: "󰝚"
                                font.family: ThemeBackend.iconFont
                                font.pixelSize: sideMusicPopout.s(20)
                                color: Qt.alpha(ThemeBackend.text, 0.4)
                                visible: thumbImg.status !== Image.Ready || !sideMusicPopout.isMediaActive
                            }
                        }
                        Image {
                            id: thumbImg
                            anchors.fill: parent
                            source: sideMusicPopout.isMediaActive ? sideMusicPopout.artSource : ""
                            sourceSize: Qt.size(sideMusicPopout.s(108), sideMusicPopout.s(108))
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: false
                        }
                        Item {
                            id: thumbMask
                            anchors.fill: parent
                            visible: false
                            layer.enabled: true
                            Rectangle { anchors.fill: parent; radius: thumb.radius; color: "black"; antialiasing: true }
                        }
                        MultiEffect {
                            anchors.fill: parent
                            source: thumbImg
                            maskEnabled: true
                            maskSource: thumbMask
                            maskThresholdMin: 0.5
                            maskSpreadAtMin: 1.0
                            visible: thumbImg.status === Image.Ready && sideMusicPopout.isMediaActive
                        }
                    }

                    Column {
                        x: thumb.width + sideMusicPopout.s(11)
                        width: header.width - x
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: sideMusicPopout.s(2)

                        Item {
                            id: titleClipArea
                            width: parent.width
                            height: titleMainText.implicitHeight
                            clip: true

                            property int marqueeSpacing: sideMusicPopout.s(40)

                            Item {
                                id: marqueeTrack
                                height: parent.height

                                Row {
                                    spacing: titleClipArea.marqueeSpacing

                                    Text {
                                        id: titleMainText
                                        text: sideMusicPopout.isMediaActive ? (sideMusicPopout.targetPlayer ? sideMusicPopout.targetPlayer.trackTitle : "") : I18n.t("music.nothing_playing")
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: sideMusicPopout.s(14)
                                        color: ThemeBackend.text

                                        onTextChanged: {
                                            marqueeTrack.x = 0;
                                            if (implicitWidth > titleClipArea.width) titleScrollAnimation.restart();
                                            else titleScrollAnimation.stop();
                                        }
                                    }

                                    Text {
                                        text: titleMainText.text
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: sideMusicPopout.s(14)
                                        color: ThemeBackend.text
                                        visible: titleMainText.implicitWidth > titleClipArea.width
                                    }
                                }

                                SequentialAnimation on x {
                                    id: titleScrollAnimation
                                    loops: Animation.Infinite
                                    running: titleMainText.implicitWidth > titleClipArea.width && menuHoverHandler.hovered

                                    onRunningChanged: {
                                        if (!running) marqueeTrack.x = 0;
                                    }

                                    PauseAnimation { duration: 2500 }
                                    NumberAnimation {
                                        from: 0
                                        to: -(titleMainText.implicitWidth + titleClipArea.marqueeSpacing)
                                        duration: (titleMainText.implicitWidth + titleClipArea.marqueeSpacing) * 25
                                    }
                                    PropertyAction { target: marqueeTrack; property: "x"; value: 0 }
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: sideMusicPopout.targetPlayer && sideMusicPopout.targetPlayer.trackArtist ? sideMusicPopout.targetPlayer.trackArtist : (sideMusicPopout.targetPlayer ? sideMusicPopout.targetPlayer.identity : "")
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.DemiBold
                            font.pixelSize: sideMusicPopout.s(12)
                            color: Qt.lighter(ThemeBackend.mauve, 1.05)
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            visible: text !== ""
                            text: sideMusicPopout.isMediaActive && sideMusicPopout.targetPlayer ? (sideMusicPopout.targetPlayer.trackAlbum || "") : ""
                            font.family: ThemeBackend.fontFamily
                            font.weight: Font.Medium
                            font.pixelSize: sideMusicPopout.s(11)
                            color: Qt.alpha(ThemeBackend.text, 0.5)
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (Caching.serpantinumDir) {
                                Quickshell.execDetached(["bash", "-c", Caching.serpantinumDir + "/scripts/qs_manager.sh toggle music"]);
                            }
                        }
                    }
                }

                // The lyric line being sung (local .lrc or online lyrics).
                Text {
                    id: lyricLine
                    y: header.height + sideMusicPopout.s(8)
                    width: parent.width
                    height: sideMusicPopout.s(17)
                    text: sideMusicPopout.currentLyric !== "" ? sideMusicPopout.currentLyric : " "
                    font.family: ThemeBackend.fontFamily
                    font.weight: Font.DemiBold
                    font.pixelSize: sideMusicPopout.s(12)
                    color: Qt.alpha(ThemeBackend.text, 0.85)
                    elide: Text.ElideRight
                    opacity: sideMusicPopout.currentLyric !== "" ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 300 } }
                }

                MusicSeekBar {
                    id: popupProgBar
                    y: lyricLine.y + lyricLine.height + sideMusicPopout.s(6)
                    width: parent.width
                    height: sideMusicPopout.s(12)
                    from: 0
                    to: (sideMusicPopout.targetPlayer && sideMusicPopout.targetPlayer.length > 0) ? sideMusicPopout.targetPlayer.length : 1
                    value: sideMusicPopout.currentLivePosition
                    interactive: sideMusicPopout.isMediaActive && sideMusicPopout.targetPlayer !== null && sideMusicPopout.targetPlayer.canSeek
                    trackHeight: sideMusicPopout.s(3)
                    hoverTrackHeight: sideMusicPopout.s(5)
                    knobSize: sideMusicPopout.s(11)
                    fillColor: sideMusicPopout.isPlaying ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.6)
                    onDraggingChanged: dragging ? SideMusicController.cancelHide() : SideMusicController.requestHide()
                    onCommitted: (v) => { if (sideMusicPopout.targetPlayer && sideMusicPopout.targetPlayer.canSeek) sideMusicPopout.targetPlayer.position = v; }
                }

                Item {
                    id: timesRow
                    y: popupProgBar.y + popupProgBar.height + sideMusicPopout.s(1)
                    width: parent.width
                    height: sideMusicPopout.s(13)
                    Text {
                        anchors.left: parent.left
                        text: sideMusicPopout.formatTime(popupProgBar.shownValue)
                        color: Qt.alpha(ThemeBackend.text, 0.55)
                        font.family: ThemeBackend.fontFamily
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        font.pixelSize: sideMusicPopout.s(10)
                    }
                    Text {
                        anchors.right: parent.right
                        text: sideMusicPopout.formatTime(sideMusicPopout.targetPlayer ? sideMusicPopout.targetPlayer.length : 0)
                        color: Qt.alpha(ThemeBackend.text, 0.55)
                        font.family: ThemeBackend.fontFamily
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        font.pixelSize: sideMusicPopout.s(10)
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    spacing: sideMusicPopout.s(8)

                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        width: sideMusicPopout.s(32)
                        height: sideMusicPopout.s(32)
                        cornerRadius: Math.round(width / 2)
                        buttonIcon: "󰒮"
                        iconFontSize: sideMusicPopout.s(12)
                        accentColor: isHoveredOrHighlighted ? Qt.alpha(ThemeBackend.text, 0.16) : Qt.alpha(ThemeBackend.text, 0.08)
                        textColor: ThemeBackend.text
                        enabled: sideMusicPopout.targetPlayer !== null && sideMusicPopout.targetPlayer.canGoPrevious
                        onClicked: sideMusicPopout.targetPlayer.previous()
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        width: sideMusicPopout.s(38)
                        height: sideMusicPopout.s(38)
                        cornerRadius: Math.round(width / 2)
                        buttonIcon: sideMusicPopout.isPlaying ? "󰏤" : "󰐊"
                        iconFontSize: sideMusicPopout.s(15)
                        accentColor: isHoveredOrHighlighted ? Qt.lighter(ThemeBackend.mauve, 1.08) : ThemeBackend.mauve
                        textColor: ThemeBackend.base
                        enabled: sideMusicPopout.targetPlayer !== null && sideMusicPopout.targetPlayer.canTogglePlaying
                        onClicked: sideMusicPopout.targetPlayer.togglePlaying()
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        width: sideMusicPopout.s(32)
                        height: sideMusicPopout.s(32)
                        cornerRadius: Math.round(width / 2)
                        buttonIcon: "󰒭"
                        iconFontSize: sideMusicPopout.s(12)
                        accentColor: isHoveredOrHighlighted ? Qt.alpha(ThemeBackend.text, 0.16) : Qt.alpha(ThemeBackend.text, 0.08)
                        textColor: ThemeBackend.text
                        enabled: sideMusicPopout.targetPlayer !== null && sideMusicPopout.targetPlayer.canGoNext
                        onClicked: sideMusicPopout.targetPlayer.next()
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: sideMusicPopout.playerList.length > 1
                        width: sideMusicPopout.s(28)
                        height: sideMusicPopout.s(28)
                        cornerRadius: Math.round(width / 2)
                        buttonIcon: "󰁔"
                        iconFontSize: sideMusicPopout.s(12)
                        accentColor: isHoveredOrHighlighted ? Qt.alpha(ThemeBackend.text, 0.16) : "transparent"
                        textColor: Qt.alpha(ThemeBackend.text, 0.6)
                        onClicked: sideMusicPopout.selectPlayerByIndex((sideMusicPopout.currentPlayerIndex + 1) % sideMusicPopout.playerList.length)
                    }
                }
            }
        }
    }
}
