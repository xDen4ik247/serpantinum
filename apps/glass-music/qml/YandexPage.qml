import QtQuick

// Yandex Music & downloads: account, where downloads go (~/Music or a temp cache), quality,
// lyrics embedding (lrcput) and the likes / playlist sync that the daily timer also runs.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: fl
    readonly property var ym: app.ym
    readonly property var conf: ym.conf || ({})
    function scrollTop() { fl.contentY = 0; }
    Component.onCompleted: { app.ymSend({ cmd: "status" }); if (ym.signed) app.ymSend({ cmd: "playlists" }); }

    function mb(n) { return n >= 1024 ? (n / 1024).toFixed(n % 1024 ? 1 : 0) + " GB" : n + " MB"; }
    function ago(ts) {
        if (!ts) return "never";
        const s = Date.now() / 1000 - ts;
        return s < 90 ? "just now" : s < 3600 ? Math.round(s / 60) + " min ago" : s < 86400 ? Math.round(s / 3600) + " h ago" : Math.round(s / 86400) + " days ago";
    }

    component Section: Column {
        property string title: ""
        property string hint: ""
        width: parent.width
        spacing: 10
        Text { text: parent.title; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 20; font.weight: Font.Bold }
        Text {
            visible: parent.hint !== ""
            width: parent.width
            text: parent.hint
            color: pg.app.th.sub1
            font.family: pg.app.th.font
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }
    }
    component Btn: Rectangle {
        id: b
        property string text: ""
        property string icon: ""
        property bool primary: false
        signal clicked()
        height: 36
        width: row.implicitWidth + 28
        radius: 18
        color: primary ? (h.hovered ? Qt.lighter(pg.app.th.accent, 1.08) : pg.app.th.accent) : pg.app.th.alpha(pg.app.th.text, h.hovered ? 0.16 : 0.09)
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 8
            Icon { visible: b.icon !== ""; app: pg.app; name: b.icon; size: 18; color: b.primary ? pg.app.th.onAccent : pg.app.th.text; anchors.verticalCenter: parent.verticalCenter }
            Text { text: b.text; color: b.primary ? pg.app.th.onAccent : pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 14; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
        HoverHandler { id: h; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: b.clicked() }
    }
    component Toggle: Item {
        id: tg
        property string text: ""
        property string sub: ""
        property bool on: false
        signal toggled(bool v)
        width: parent.width
        height: Math.max(40, col.implicitHeight + 12)
        Column {
            id: col
            anchors { left: parent.left; right: sw.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 2
            Text { width: parent.width; text: tg.text; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 15; elide: Text.ElideRight }
            Text { visible: tg.sub !== ""; width: parent.width; text: tg.sub; color: pg.app.th.sub1; font.family: pg.app.th.font; font.pixelSize: 12; wrapMode: Text.WordWrap }
        }
        Rectangle {
            id: sw
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: 44; height: 24; radius: 12
            color: tg.on ? pg.app.th.accent : pg.app.th.alpha(pg.app.th.text, 0.18)
            Behavior on color { ColorAnimation { duration: 160 } }
            Rectangle {
                width: 18; height: 18; radius: 9
                y: 3; x: tg.on ? parent.width - width - 3 : 3
                color: tg.on ? pg.app.th.onAccent : pg.app.th.text
                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: tg.toggled(!tg.on) }
    }

    Flickable {
        id: fl
        anchors.fill: parent
        contentHeight: col.height + pg.topPad + 60
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 32
            y: pg.topPad + 12
            width: Math.min(760, fl.width - 64)
            spacing: 34

            Column {
                width: parent.width
                spacing: 6
                Text { text: "Yandex Music"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 40; font.weight: Font.Black; font.letterSpacing: -1 }
                Text {
                    width: parent.width
                    text: "Search all of Yandex Music from Search (Ctrl+F). Every song you play is first downloaded with yandex-music-downloader, then MPD plays the local file. Nothing streams."
                    color: pg.app.th.sub0
                    font.family: pg.app.th.font
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                }
            }

            // ---- activity
            Rectangle {
                visible: !!pg.app.ymBusy
                width: parent.width
                height: 56
                radius: 14
                color: pg.app.th.alpha(pg.app.th.accent, 0.14)
                Icon { id: dlI; x: 16; anchors.verticalCenter: parent.verticalCenter; app: pg.app; name: "download"; size: 22; color: pg.app.th.accent }
                Text {
                    anchors { left: dlI.right; leftMargin: 12; right: stopB.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: pg.app.ymBusyText()
                    color: pg.app.th.text
                    elide: Text.ElideRight
                    font.family: pg.app.th.font
                    font.pixelSize: 14
                }
                Btn {
                    id: stopB
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "Stop"; icon: "close"
                    onClicked: pg.app.ymCancelAll()
                }
            }

            // ---- account
            Section {
                title: "Account"
                hint: pg.ym.available === false ? (pg.ym.error || "Yandex Music support is not installed.")
                    : pg.ym.signed ? "" : "Sign in once: open the sign-in page, log in, then copy the address of the page you land on (it contains access_token=…) and paste it here. The token is stored only in ~/.config/glass-music/yandex.json."
                Row {
                    visible: pg.ym.signed
                    spacing: 12
                    Rectangle {
                        width: 44; height: 44; radius: 22
                        color: pg.app.th.alpha(pg.app.th.accent, 0.25)
                        Icon { anchors.centerIn: parent; app: pg.app; name: "account"; size: 24; color: pg.app.th.accent }
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text { text: pg.ym.name || "Signed in"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 16; font.weight: Font.DemiBold }
                        Text {
                            text: pg.ym.error ? pg.ym.error : pg.ym.plus ? "Yandex Plus · lossless available" : "No Yandex Plus: Yandex only allows 30-second previews"
                            color: pg.ym.error ? pg.app.th.bad : pg.app.th.sub1
                            font.family: pg.app.th.font
                            font.pixelSize: 13
                        }
                    }
                    Item { width: 12; height: 1 }
                    Btn { anchors.verticalCenter: parent.verticalCenter; text: "Sign out"; icon: "logout"; onClicked: pg.app.ymSend({ cmd: "logout" }) }
                }
                Column {
                    visible: !pg.ym.signed && pg.ym.available !== false
                    width: parent.width
                    spacing: 10
                    Btn { text: "Open sign-in page"; icon: "login"; primary: true; onClicked: Qt.openUrlExternally(pg.ym.signin) }
                    Rectangle {
                        width: parent.width
                        height: 44
                        radius: 22
                        color: pg.app.th.alpha(pg.app.th.text, tok.activeFocus ? 0.13 : 0.075)
                        border.width: 1
                        border.color: pg.app.th.alpha("white", tok.activeFocus ? 0.4 : 0.08)
                        TextInput {
                            id: tok
                            anchors { left: parent.left; leftMargin: 18; right: goBtn.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            color: pg.app.th.text
                            font.family: pg.app.th.font
                            font.pixelSize: 14
                            clip: true
                            echoMode: TextInput.Password
                            onAccepted: if (text.trim() !== "") { pg.app.ymSend({ cmd: "login", token: text }); text = ""; }
                            Text { anchors.verticalCenter: parent.verticalCenter; visible: tok.text === ""; text: "Paste the address (or token) here, then Enter"; color: pg.app.th.sub1; font: tok.font }
                        }
                        IconButton {
                            id: goBtn
                            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            app: pg.app; icon: "forward"; size: 34; iconSize: 20
                            onClicked: if (tok.text.trim() !== "") { pg.app.ymSend({ cmd: "login", token: tok.text }); tok.text = ""; }
                        }
                    }
                }
            }

            // ---- storage
            Section {
                title: "Where songs go"
                hint: pg.conf.storage === "temp"
                    ? "Songs you play are kept in a temporary cache (" + (pg.ym.temp || "") + ") and the oldest are deleted past the limit. ⬇ or “Save to library” still keeps one in ~/Music."
                    : "Songs you play are saved into your library (~/Music, Artist/Album/N - Title), like the rest of your music."
                Row {
                    spacing: 8
                    Chip { app: pg.app; text: "Library (~/Music)"; active: pg.conf.storage !== "temp"; onClicked: pg.app.ymSet("storage", "library") }
                    Chip { app: pg.app; text: "Temporary"; active: pg.conf.storage === "temp"; onClicked: pg.app.ymSet("storage", "temp") }
                }
                Row {
                    visible: pg.conf.storage === "temp"
                    spacing: 8
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Keep up to"; color: pg.app.th.sub0; font.family: pg.app.th.font; font.pixelSize: 14 }
                    Repeater {
                        model: [1024, 2048, 5120, 10240]
                        Chip { required property var modelData; app: pg.app; text: pg.mb(modelData); active: (pg.conf.temp_limit_mb || 2048) === modelData; onClicked: pg.app.ymSet("temp_limit_mb", modelData) }
                    }
                }
                Row {
                    spacing: 12
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Temporary cache: " + pg.mb(Math.round((pg.ym.tempSize || 0) / 1048576)); color: pg.app.th.sub1; font.family: pg.app.th.font; font.pixelSize: 13 }
                    Btn { visible: (pg.ym.tempSize || 0) > 0; text: "Clear"; icon: "delete"; onClicked: pg.app.ymSend({ cmd: "cleartemp" }) }
                }
            }

            Section {
                title: "Quality"
                Row {
                    spacing: 8
                    Chip { app: pg.app; text: "Lossless (FLAC)"; active: pg.conf.quality === 2; onClicked: pg.app.ymSet("quality", 2) }
                    Chip { app: pg.app; text: "High (AAC 192)"; active: pg.conf.quality === 1; onClicked: pg.app.ymSet("quality", 1) }
                    Chip { app: pg.app; text: "Low (AAC 64)"; active: pg.conf.quality === 0; onClicked: pg.app.ymSet("quality", 0) }
                }
            }

            Section {
                title: "Lyrics"
                Toggle {
                    text: "Embed lyrics into the files (lrcput)"
                    sub: "After every download the synced .lrc is written into the song’s tags, so phones and other players show it too. The .lrc file stays next to the song."
                    on: pg.conf.embed_lyrics !== false
                    onToggled: v => pg.app.ymSet("embed_lyrics", v)
                }
            }

            // ---- sync
            Section {
                title: "Sync"
                hint: "Downloads new songs from these into ~/Music (already downloaded ones are skipped). Last sync: " + pg.ago(pg.conf.last_sync)
                      + (pg.conf.last_sync ? " · " + pg.app.n(pg.conf.last_sync_new || 0, "new song") : "")
                Toggle {
                    text: "Sync every day"
                    sub: "A systemd user timer runs it once a day (and catches up after the laptop was off)."
                    on: pg.conf.auto_sync !== false
                    onToggled: v => pg.app.ymSet("auto_sync", v)
                }
                Repeater {
                    model: pg.app.ymPlaylists
                    Toggle {
                        required property var modelData
                        text: modelData.n + "  ·  " + pg.app.n(modelData.nt || 0, "song")
                        sub: modelData.kind === "likes" ? "Your “Мне нравится” playlist" : ""
                        on: modelData.kind === "likes" ? pg.conf.sync_likes !== false : (pg.conf.sync_playlists || []).indexOf(modelData.id) >= 0
                        onToggled: v => {
                            if (modelData.kind === "likes") pg.app.ymSet("sync_likes", v);
                            else {
                                const l = (pg.conf.sync_playlists || []).filter(x => x !== modelData.id);
                                if (v) l.push(modelData.id);
                                pg.app.ymSet("sync_playlists", l);
                            }
                            const p = pg.app.ymPlaylists.map(x => x.id === modelData.id ? Object.assign({}, x, { sync: v }) : x);
                            pg.app.ymPlaylists = p;
                        }
                    }
                }
                Row {
                    spacing: 10
                    Btn { text: "Sync now"; icon: "sync"; primary: true; onClicked: pg.app.ymSync() }
                    Btn { text: "Liked on Yandex"; icon: "heart"; onClicked: pg.app.ymOpen("likes", "likes") }
                }
            }
        }
    }
}
