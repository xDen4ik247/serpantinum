import QtQuick
import QtQuick.Effects

// The big middle island: a floating header (back/forward, search field, menu) over the
// current page. Pages scroll underneath it; the header tints once content passes under.
Item {
    id: pane
    property var app
    readonly property real headerH: 64
    property var page: null
    property string pageKey: ""
    readonly property real scrollY: page && page.flick ? page.flick.contentY - page.flick.originY : 0

    Glass {
        anchors.fill: parent
        theme: pane.app.th
        radius: 18
        tintAlpha: 0.22
    }

    Item {
        id: content
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }

        Item {
            id: holder
            width: parent.width
            height: parent.height
            ParallelAnimation {
                id: enter
                NumberAnimation { target: holder; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
                NumberAnimation { target: holder; property: "y"; from: 14; to: 0; duration: 520; easing.type: Easing.OutQuint }
            }
        }
    }

    Item {
        id: mask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: 18; color: "black" }
    }

    Component { id: homeC; HomePage {} }
    Component { id: searchC; SearchPage {} }
    Component { id: artistsC; ArtistsPage {} }
    Component { id: albumsC; AlbumsPage {} }
    Component { id: listC; TrackListPage {} }
    Component { id: artistC; ArtistPage {} }

    function show() {
        const p = app.nav.page;
        const k = p + "\u0001" + (app.nav.arg || "");
        if (k === pageKey || !app.ready) return;
        pageKey = k;
        const comp = p === "home" ? homeC : p === "search" ? searchC : p === "artists" ? artistsC
            : p === "albums" ? albumsC : p === "artist" ? artistC : listC;
        const old = page;
        const item = comp.createObject(holder, { app: pane.app, arg: pane.app.nav.arg || "", topPad: pane.headerH });
        if (!item) { console.warn("page failed:", p, comp.errorString()); return; }
        console.log("page:", p, item.width, item.height);
        page = item;
        app.pageItem = item;
        if (old) old.destroy();
        const y = app.nav.y;
        if (y !== undefined && item.flick) Qt.callLater(() => { if (item && item.flick) item.flick.contentY = Math.min(y, Math.max(0, item.flick.contentHeight - item.flick.height)); });
        enter.restart();
    }
    Connections {
        target: pane.app
        function onNavChanged() { pane.show() }
        function onReadyChanged() { pane.show() }
    }
    Component.onCompleted: show()

    // ---------------------------------------------------------------- header
    Item {
        id: header
        width: parent.width
        height: pane.headerH
        readonly property bool solid: pane.scrollY > 24
        readonly property bool sticky: !!pane.page && !!pane.page.stickyTitle && pane.scrollY > (pane.page.stickyAt || 260)

        Rectangle {
            anchors.fill: parent
            topLeftRadius: 18
            topRightRadius: 18
            opacity: header.solid ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260 } }
            color: pane.page && pane.page.tint !== undefined && pane.page.tint !== null
                   ? pane.app.th.alpha(pane.app.th.mix(pane.page.tint, pane.app.th.base, 0.55), 0.92)
                   : pane.app.th.alpha(pane.app.th.mix(pane.app.th.base, pane.app.th.surface0, 0.5), 0.9)
            Behavior on color { ColorAnimation { duration: 300 } }
        }

        Row {
            id: navBtns
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            IconButton {
                app: pane.app; icon: "back"; size: 34; iconSize: 22; tip: "Go back"
                enabledState: pane.app.backStack.length > 0
                onClicked: pane.app.back()
                Rectangle { anchors.fill: parent; radius: width / 2; color: pane.app.th.alpha(pane.app.th.base, 0.45); z: -1 }
            }
            IconButton {
                app: pane.app; icon: "forward"; size: 34; iconSize: 22; tip: "Go forward"
                enabledState: pane.app.fwdStack.length > 0
                onClicked: pane.app.forward()
                Rectangle { anchors.fill: parent; radius: width / 2; color: pane.app.th.alpha(pane.app.th.base, 0.45); z: -1 }
            }
        }

        // sticky page title + play (Spotify-style, after the hero scrolls away)
        Row {
            anchors { left: navBtns.right; leftMargin: 14; verticalCenter: parent.verticalCenter }
            spacing: 12
            visible: opacity > 0
            opacity: header.sticky && pane.app.nav.page !== "search" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 220 } }
            IconButton {
                app: pane.app; icon: "play"; filled: true; size: 40; iconSize: 22
                onClicked: if (pane.page && pane.page.playAll) pane.page.playAll(false)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pane.page && pane.page.stickyTitle ? pane.page.stickyTitle : ""
                color: pane.app.th.text
                font.family: pane.app.th.font
                font.pixelSize: 22
                font.weight: Font.Bold
                elide: Text.ElideRight
                width: Math.min(implicitWidth, header.width - 300)
            }
        }

        SearchField {
            id: searchField
            app: pane.app
            visible: pane.app.nav.page === "search"
            anchors { left: navBtns.right; leftMargin: 14; verticalCenter: parent.verticalCenter }
            width: Math.min(420, header.width - navBtns.width - 110)
        }

        IconButton {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            app: pane.app; icon: "dots"; size: 34; tip: "More"
            Rectangle { anchors.fill: parent; radius: width / 2; color: pane.app.th.alpha(pane.app.th.base, 0.45); z: -1 }
            onClicked: m => { const p = mapToItem(pane.app.rootItem, width, height + 4); pane.app.appMenu(pane.app.rootItem, p.x - 250, p.y); }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: !pane.app.ready
        text: "Loading your library…"
        color: pane.app.th.sub1
        font.family: pane.app.th.font
        font.pixelSize: 15
    }
}
