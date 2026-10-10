import QtQuick
import QtQuick.Effects

// My Vibe: one big glass play button for an endless smart queue (music-smart) and a style
// picker under it. Default style = what you play most; the others are Favourites, Discover,
// Reggae and the moods. The aura and ripples move only while My Vibe itself is playing and
// the window is shown; otherwise everything is static.
Item {
    id: hero
    property var app
    readonly property string cur: app.curStyle
    readonly property var info: app.styleInfo(cur)
    readonly property bool on: app.vibeOn
    readonly property bool mine: on && app.smart.style === cur
    property bool shown: true             // the page passes false while the hero is scrolled away
    readonly property bool live: mine && app.playing && hero.visible && shown
    readonly property color tint: app.styleColor(cur)
    readonly property bool empty: info.n !== undefined && info.n === 0
    readonly property bool narrow: width < 760
    implicitHeight: chips.y + chips.height + 26

    Glass {
        anchors.fill: parent
        theme: hero.app.th
        radius: 22
        tintAlpha: 0.20
        lit: hero.mine
    }
    // the style's colour washes in from the left and follows the picked style
    Rectangle {
        anchors.fill: parent
        radius: 22
        opacity: 0.9
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: hero.app.th.alpha(hero.tint, 0.34); Behavior on color { ColorAnimation { duration: 700; easing.type: Easing.OutCubic } } }
            GradientStop { position: 0.55; color: hero.app.th.alpha(hero.tint, 0.08); Behavior on color { ColorAnimation { duration: 700; easing.type: Easing.OutCubic } } }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    // ---------------------------------------------------------------- the orb
    Item {
        id: orb
        x: hero.narrow ? 14 : 26
        y: 18
        width: hero.narrow ? 160 : 196
        height: width

        // soft aura: three blurred blobs (rendered once; only transformed while live)
        Item {
            id: aura
            anchors.centerIn: parent
            width: parent.width * 0.86
            height: width
            opacity: hero.live ? 0.95 : (hero.mine ? 0.7 : 0.5)
            Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48; autoPaddingEnabled: true }
            Rectangle {
                width: parent.width * 0.62; height: width; radius: width / 2
                x: parent.width * 0.06; y: parent.height * 0.10
                color: hero.app.th.alpha(hero.tint, 0.95)
                Behavior on color { ColorAnimation { duration: 700 } }
            }
            Rectangle {
                width: parent.width * 0.56; height: width; radius: width / 2
                x: parent.width * 0.38; y: parent.height * 0.18
                color: hero.app.th.alpha(hero.app.th.mix(hero.tint, hero.app.th.accent2, hero.cur === "default" ? 0.85 : 0.55), 0.85)
                Behavior on color { ColorAnimation { duration: 700 } }
            }
            Rectangle {
                width: parent.width * 0.52; height: width; radius: width / 2
                x: parent.width * 0.22; y: parent.height * 0.42
                color: hero.app.th.alpha(hero.cur === "default" ? hero.app.th.mix(hero.app.th.deep, "#ffffff", 0.25) : hero.app.th.mix(hero.tint, "#ffffff", 0.35), 0.8)
                Behavior on color { ColorAnimation { duration: 700 } }
            }
            RotationAnimator on rotation {
                from: 0; to: 360; duration: 16000
                loops: Animation.Infinite
                running: hero.live
            }
            SequentialAnimation on scale {
                running: hero.live
                loops: Animation.Infinite
                NumberAnimation { to: 1.09; duration: 2600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.97; duration: 2600; easing.type: Easing.InOutSine }
            }
        }

        // ripples: the "wave" going out while it plays
        Repeater {
            model: 3
            Rectangle {
                id: ring
                required property int index
                anchors.centerIn: parent
                width: playBtn.width; height: width; radius: width / 2
                color: "transparent"
                border.width: 1.5
                border.color: hero.app.th.alpha("white", 0.55)
                opacity: 0
                SequentialAnimation {
                    running: hero.live
                    PauseAnimation { duration: ring.index * 1000 }
                    SequentialAnimation {
                        loops: Animation.Infinite
                        ParallelAnimation {
                            NumberAnimation { target: ring; property: "scale"; from: 1.0; to: 1.9; duration: 3000; easing.type: Easing.OutCubic }
                            NumberAnimation { target: ring; property: "opacity"; from: 0.6; to: 0; duration: 3000; easing.type: Easing.OutQuad }
                        }
                    }
                    onRunningChanged: if (!running) { ring.opacity = 0; ring.scale = 1; }
                }
            }
        }

        // the button
        Item {
            id: playBtn
            anchors.centerIn: parent
            width: hero.narrow ? 82 : 96
            height: width
            scale: tapArea.pressed ? 0.93 : (playHover.hovered ? 1.05 : 1)
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
            opacity: hero.empty ? 0.5 : 1
            RectangularShadow {
                anchors.fill: parent
                radius: width / 2
                blur: 26; spread: 0; offset.y: 8
                color: Qt.rgba(0, 0, 0, 0.35)
            }
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.97) }
                    GradientStop { position: 1; color: hero.app.th.mix("#ffffff", hero.tint, 0.18) }
                }
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.6)
            }
            Icon {
                app: hero.app
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: hero.mine && hero.app.playing ? 0 : 3
                name: hero.mine && hero.app.playing ? "pause" : "play"
                size: parent.width * 0.48
                color: hero.app.th.mix(hero.app.th.base, hero.tint, 0.25)
            }
            HoverHandler { id: playHover; cursorShape: hero.empty ? Qt.ArrowCursor : Qt.PointingHandCursor }
            MouseArea {
                id: tapArea
                anchors.fill: parent
                enabled: !hero.empty
                onClicked: hero.app.vibePlay(hero.cur)
            }
            ToolTipLite {
                app: hero.app
                below: true
                text: hero.mine ? (hero.app.playing ? "Pause" : "Play") : "Play My Vibe · " + hero.info.label
                shown: playHover.hovered
            }
        }
    }

    // ---------------------------------------------------------------- the words
    Column {
        id: words
        anchors { left: orb.right; leftMargin: hero.narrow ? 14 : 22; right: covers.visible ? covers.left : parent.right; rightMargin: 26; verticalCenter: orb.verticalCenter }
        spacing: 6
        Row {
            spacing: 8
            Text {
                text: "MY VIBE"
                color: hero.app.th.alpha(hero.app.th.text, 0.72)
                font.family: hero.app.th.font
                font.pixelSize: 12
                font.weight: Font.Bold
                font.letterSpacing: 1.6
            }
            Rectangle {
                visible: hero.on
                anchors.verticalCenter: parent.verticalCenter
                width: onText.implicitWidth + 14; height: 18; radius: 9
                color: hero.app.th.alpha(hero.app.styleColor(hero.app.smart.style || "default"), 0.85)
                Text {
                    id: onText
                    anchors.centerIn: parent
                    text: hero.mine ? "ON" : "ON · " + (hero.app.smart.styleLabel || "")
                    color: "white"
                    font.family: hero.app.th.font
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                }
            }
        }
        Text {
            width: parent.width
            text: hero.info.label
            color: "white"
            font.family: hero.app.th.font
            font.pixelSize: hero.narrow ? 40 : 54
            font.weight: Font.Black
            font.letterSpacing: -1
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: hero.empty && hero.cur === "favourites"
                  ? "Star (☆) the songs you love most — My Vibe plays favourites more often, and this style plays only them."
                  : (hero.info.desc || "") + (hero.info.n !== undefined && hero.cur !== "default" && hero.cur !== "discover" ? "  ·  " + hero.app.n(hero.info.n, "song") : "")
            color: hero.app.th.sub0
            font.family: hero.app.th.font
            font.pixelSize: 15
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Item { width: 1; height: 4 }
        Row {
            spacing: 8
            height: 32
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, words.width - (rerollBtn.visible ? 90 : 0))
                elide: Text.ElideRight
                text: hero.mine ? (hero.app.smart.why ? "Now: " + hero.app.smart.why : "Endless: it tops itself up as you listen")
                      : hero.on ? "Playing " + (hero.app.smart.styleLabel || "My Vibe") + " · press play to switch"
                      : "Endless, fresh every time · Mod+S anywhere"
                color: hero.app.th.sub1
                font.family: hero.app.th.font
                font.pixelSize: 13
            }
            IconButton {
                id: rerollBtn
                visible: hero.mine
                anchors.verticalCenter: parent.verticalCenter
                app: hero.app; icon: "dice"; size: 32; iconSize: 18
                tip: "Re-roll · a fresh mix in this style (Mod+S)"
                onClicked: hero.app.vibeReroll()
            }
            IconButton {
                visible: hero.on
                anchors.verticalCenter: parent.verticalCenter
                app: hero.app; icon: "close"; size: 32; iconSize: 18
                tip: "Leave My Vibe (the queue keeps playing)"
                onClicked: hero.app.vibeStop()
            }
        }
    }

    // ---------------------------------------------------------------- what it plays
    // Up next while this style plays, otherwise a taste of the style: a small fan of covers.
    readonly property var sampleAlbums: {
        const seen = {}, out = [];
        const add = i => { if (i < 0 || out.length >= 5) return; const k = app.lib.tracks[i].k; const a = app.albumByKey[k]; if (a && a.c && !seen[k]) { seen[k] = 1; out.push(k); } };
        if (mine) {
            const q = app.queue, p = Math.max(0, app.status.pos);
            for (let j = p; j < q.length && out.length < 5; j++) add(q[j].i);
            return out;
        }
        let idx;
        if (cur === "default") idx = app.idxOfFiles(app.home.most.concat(app.home.recent));
        else if (cur === "discover") {
            idx = [];
            const played = app.home.counts;
            for (let j = 0; j < app.lib.tracks.length && idx.length < 400; j += 7) if (!played[app.lib.tracks[j].f]) idx.push(j);
        } else idx = app.styleTracks(cur);
        for (let j = 0; j < idx.length && out.length < 5; j++) add(idx[(j * 7) % idx.length]);
        return out;
    }
    Item {
        id: covers
        visible: !hero.narrow && hero.width > 1060 && hero.sampleAlbums.length > 0
        readonly property real cs: 132
        readonly property real step: 74
        width: cs + step * Math.max(0, hero.sampleAlbums.length - 1) + 20
        height: cs + 30
        anchors { right: parent.right; rightMargin: 34; verticalCenter: orb.verticalCenter }
        Text {
            x: 0; y: -4
            text: hero.mine ? "Up next" : "In this style"
            color: hero.app.th.alpha(hero.app.th.text, 0.6)
            font.family: hero.app.th.font
            font.pixelSize: 12
            font.weight: Font.Bold
            font.letterSpacing: 1.2
        }
        Repeater {
            model: hero.sampleAlbums
            Item {
                id: fan
                required property int index
                required property string modelData
                width: covers.cs; height: covers.cs
                x: index * covers.step
                y: 24 + (index % 2 ? 6 : 0)
                z: 10 - index
                rotation: (index - (hero.sampleAlbums.length - 1) / 2) * 2.5
                scale: fanHover.hovered ? 1.05 : (1 - index * 0.035)
                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
                Behavior on x { NumberAnimation { duration: 520; easing.type: Easing.OutQuint } }
                RectangularShadow {
                    anchors.fill: parent
                    radius: 10; blur: 22; spread: -2; offset.y: 6
                    color: Qt.rgba(0, 0, 0, 0.42)
                }
                Cover {
                    anchors.fill: parent
                    app: hero.app
                    albumKey: fan.modelData
                    radius: 10
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.14)
                }
                HoverHandler { id: fanHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: hero.app.goAlbum(fan.modelData) }
            }
        }
    }

    // ---------------------------------------------------------------- styles
    Flow {
        id: chips
        x: hero.narrow ? 16 : 28
        y: orb.y + orb.height + 8
        width: parent.width - x * 2
        spacing: 8
        Repeater {
            model: hero.app.styleList()
            StyleChip {
                required property var modelData
                app: hero.app
                style: modelData
                active: modelData.id === hero.cur
                live: hero.on && hero.app.smart.style === modelData.id
                onClicked: hero.app.vibePick(modelData.id)
            }
        }
    }
}
