import QtQuick

// The middle island: search, the folder title with filter chips, and the message list
// (date groups, hover actions, multi-select). Scrolling near the end loads older mail.
Item {
    id: pane
    property var app
    readonly property var rows: app.rows()

    Glass {
        anchors.fill: parent
        theme: pane.app.th
        radius: 18
        tintAlpha: 0.22
    }

    // ---- header: search + refresh + menu
    Item {
        id: head
        x: 12; y: 12
        width: parent.width - 24
        height: 44
        SearchField {
            id: sf
            app: pane.app
            anchors { left: parent.left; right: refreshBtn.left; rightMargin: 6 }
        }
        IconButton {
            id: refreshBtn
            app: pane.app; icon: "refresh"; tip: "Check mail · Ctrl+R"
            anchors { right: menuBtn.left; verticalCenter: parent.verticalCenter }
            onClicked: pane.app.refresh()
            RotationAnimator on rotation { running: pane.app.loadingOlder; from: 0; to: 360; loops: Animation.Infinite; duration: 900 }
        }
        IconButton {
            id: menuBtn
            app: pane.app; icon: "dots-v"; tip: "More"
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            onClicked: m => pane.app.appMenu(menuBtn, menuBtn.mapToItem(pane.app.rootItem, 0, 0).x - 230, menuBtn.mapToItem(pane.app.rootItem, 0, 0).y + 40)
        }
    }

    // ---- title + chips (or the selection bar)
    Item {
        id: titleRow
        anchors { top: head.bottom; topMargin: 14; left: parent.left; right: parent.right; leftMargin: 18; rightMargin: 14 }
        height: 36
        visible: pane.app.selCount === 0
        Row {
            spacing: 10
            anchors.verticalCenter: parent.verticalCenter
            Icon { app: pane.app; name: pane.app.searching ? "search" : pane.app.viewIcon(); size: 24; color: pane.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: pane.app.viewTitle()
                color: pane.app.th.text
                font.family: pane.app.th.font
                font.pixelSize: 24
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                text: {
                    if (pane.app.searching) return pane.app.searchPending ? "searching the server…" : pane.app.n(pane.app.searchResults().length, "result");
                    const v = pane.app.view;
                    if (!v || v.acc === "*" || v.kind) return "";
                    const f = pane.app.folderOf(v.acc, v.folder);
                    return f && f.unread && f.role !== "sent" ? f.unread + " unread" : "";
                }
                color: pane.app.th.sub1
                font.family: pane.app.th.font
                font.pixelSize: 13
            }
        }
    }
    Row {
        id: chips
        anchors { top: titleRow.bottom; topMargin: 10; left: parent.left; leftMargin: 16 }
        spacing: 6
        visible: pane.app.selCount === 0
        Repeater {
            model: [["all", "All"], ["people", "People"], ["unread", "Unread"], ["starred", "Starred"], ["updates", "Updates"], ["news", "News"]]
            Chip {
                required property var modelData
                app: pane.app
                text: modelData[1]
                active: pane.app.filter === modelData[0]
                onClicked: pane.app.filter = modelData[0]
            }
        }
    }
    // selection bar replaces title + chips
    Rectangle {
        id: selBar
        visible: pane.app.selCount > 0
        anchors { top: head.bottom; topMargin: 14; left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12 }
        height: 78
        radius: 14
        color: pane.app.th.alpha(pane.app.th.accent, 0.14)
        Row {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 2
            IconButton { app: pane.app; icon: "close"; tip: "Clear selection · Esc"; onClicked: pane.app.sel = ({}) }
            Text {
                text: pane.app.selCount + " selected"
                color: pane.app.th.text
                font.family: pane.app.th.font
                font.pixelSize: 15
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
                rightPadding: 10
            }
            IconButton { app: pane.app; icon: "archive"; tip: "Archive · E"; onClicked: pane.app.act("archive") }
            IconButton { app: pane.app; icon: "trash"; tip: "Delete · #"; onClicked: pane.app.act("trash") }
            IconButton { app: pane.app; icon: "mail-open"; tip: "Read / unread · U"; onClicked: pane.app.toggleRead() }
            IconButton { app: pane.app; icon: "star-outline"; tip: "Star · S"; onClicked: pane.app.toggleStar() }
            IconButton {
                id: moveBtn
                app: pane.app; icon: "folder"; tip: "Move to…"
                onClicked: { const p = moveBtn.mapToItem(pane.app.rootItem, 0, 40); pane.app.moveMenu(Object.values(pane.app.sel), moveBtn, p.x, p.y); }
            }
        }
    }

    // ---- the list
    ListView {
        id: lv
        anchors { top: chips.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 6; rightMargin: 6; bottomMargin: 6 }
        clip: true
        model: pane.rows
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 800
        delegate: Loader {
            id: dl
            required property var modelData
            required property int index
            width: lv.width
            sourceComponent: modelData.ask !== undefined ? askC : modelData.header !== undefined ? headerC : rowC
        }
        onContentYChanged: if (contentY + height > contentHeight - 600) pane.app.loadOlder()
        footer: Item {
            width: lv.width
            height: pane.app.loadingOlder || (!pane.app.complete && !pane.app.searching) ? 56 : 24
            Text {
                anchors.centerIn: parent
                visible: pane.app.loadingOlder
                text: "Loading older mail…"
                color: pane.app.th.sub1
                font.family: pane.app.th.font
                font.pixelSize: 13
            }
        }
        Connections {
            target: pane.app
            function onScrollToCurrent() {
                const k = pane.app.key(pane.app.cur);
                for (let i = 0; i < pane.rows.length; i++) if (pane.rows[i].header === undefined && pane.rows[i].ask === undefined && pane.app.key(pane.rows[i]) === k) { lv.positionViewAtIndex(i, ListView.Contain); break; }
            }
        }
    }

    Component {
        id: headerC
        Item {
            height: 34
            Text {
                x: 14
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                text: parent.parent ? parent.parent.modelData.header : ""
                color: pane.app.th.sub1
                font.family: pane.app.th.font
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
                font.capitalization: Font.AllUppercase
            }
        }
    }
    Component {
        id: askC
        Rectangle {
            readonly property string q: parent ? parent.modelData.ask : ""
            height: 52
            radius: 14
            color: pane.app.th.alpha(pane.app.th.accent, askHov.hovered ? 0.18 : 0.10)
            border.color: pane.app.th.alpha(pane.app.th.accent, 0.25)
            Icon { id: askIc; app: pane.app; x: 16; name: "sparkle"; size: 20; color: pane.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors { left: askIc.right; leftMargin: 12; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                text: "<b>Ask AI</b>&nbsp;&nbsp;“" + parent.q.replace(/</g, "&lt;") + "”" + (parent.q.endsWith("?") ? "&nbsp;&nbsp;·&nbsp;Enter" : "")
                textFormat: Text.StyledText
                elide: Text.ElideRight
                color: pane.app.th.text
                font.family: pane.app.th.font
                font.pixelSize: 14
            }
            HoverHandler { id: askHov; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: pane.app.ask(parent.q) }
        }
    }
    Component {
        id: rowC
        MessageRow {
            app: pane.app
            r: parent ? parent.modelData : null
        }
    }

    // ---- empty states
    Column {
        anchors.centerIn: lv
        spacing: 10
        visible: lv.count === 0
        Icon {
            app: pane.app
            anchors.horizontalCenter: parent.horizontalCenter
            name: pane.app.searching ? "search" : (pane.app.filter !== "all" ? "mails" : (pane.app.view && pane.app.view.kind === "starred" ? "star-outline" : "check-all"))
            size: 54
            color: pane.app.th.alpha(pane.app.th.text, 0.25)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: pane.app.searching ? (pane.app.searchPending ? "Searching…" : "Nothing found")
                : !pane.app.view ? (pane.app.accounts.length ? "Loading…" : "Add an account to start")
                : pane.app.filter !== "all" ? "Nothing here with this filter"
                : pane.app.view.kind === "starred" ? "Star messages to find them here"
                : "All done here"
            color: pane.app.th.sub1
            font.family: pane.app.th.font
            font.pixelSize: 15
        }
    }
}
