import QtQuick

// One message in the list: avatar, sender, date (or hover actions), subject, snippet.
// Click opens it; Ctrl+click / Shift+click select; right-click for the menu.
Item {
    id: row
    property var app
    property var r: null
    readonly property bool unread: r ? !r.seen : false
    readonly property bool current: !!(r && app.cur && app.key(app.cur) === app.key(r))
    readonly property bool picked: !!(r && app.sel[app.key(r)])
    width: parent ? parent.width : 300
    height: 84

    Rectangle {
        anchors { fill: parent; topMargin: 2; bottomMargin: 2 }
        radius: 14
        color: row.picked ? row.app.th.alpha(row.app.th.accent, 0.22)
             : row.current ? row.app.th.alpha(row.app.th.text, 0.12)
             : row.app.th.alpha(row.app.th.text, hover.hovered ? 0.06 : 0)
        Behavior on color { ColorAnimation { duration: 140 } }
        // account colour stripe in merged views
        Rectangle {
            visible: row.r && row.app.multi && row.app.view && (row.app.view.acc === "*" || row.app.view.kind || row.app.searching)
            x: 3; width: 3; radius: 1.5
            anchors { top: parent.top; bottom: parent.bottom; margins: 14 }
            color: row.r ? row.app.accColor(row.r.acc) : "transparent"
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => {
            if (!row.r) return;
            if (m.button === Qt.RightButton) { const p = row.mapToItem(row.app.rootItem, m.x, m.y); row.app.rowMenu(row.r, row, p.x, p.y); }
            else if (m.modifiers & Qt.ControlModifier) row.app.toggleSel(row.r);
            else if (m.modifiers & Qt.ShiftModifier) row.app.selectRange(row.r);
            else row.app.open(row.r);
        }
    }

    // unread dot
    Rectangle {
        visible: row.unread
        width: 8; height: 8; radius: 4
        x: 9
        y: 22
        color: row.app.th.accent
    }

    Item {
        id: avBox
        x: 22
        y: 14
        width: 40; height: 40
        Avatar {
            anchors.fill: parent
            visible: !row.picked
            app: row.app
            size: 40
            name: row.r ? row.r.from_name : ""
            addr: row.r ? row.r.from_addr : ""
        }
        Rectangle {
            anchors.fill: parent
            visible: row.picked
            radius: 20
            color: row.app.th.accent
            Icon { app: row.app; anchors.centerIn: parent; name: "check"; size: 22; color: row.app.th.onAccent }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (row.r) row.app.toggleSel(row.r) }
    }

    Item {
        anchors { left: avBox.right; leftMargin: 14; right: parent.right; rightMargin: 14; top: parent.top; topMargin: 12 }
        height: 60

        // line 1: sender · date
        Text {
            id: who
            anchors { left: parent.left; right: rightBox.left; rightMargin: 10 }
            text: {
                if (!row.r) return "";
                const f = row.app.folderOf(row.r.acc, row.r.folder);
                if (f && (f.role === "sent" || f.role === "drafts") && row.r.rcpt && row.r.rcpt.length)
                    return "To: " + row.r.rcpt.map(p => p[0] || p[1]).join(", ");
                return row.app.sender(row.r);
            }
            elide: Text.ElideRight
            color: row.app.th.text
            font.family: row.app.th.font
            font.pixelSize: 15
            font.weight: row.unread ? Font.Bold : Font.Medium
        }
        Item {
            id: rightBox
            anchors { right: parent.right; top: parent.top }
            width: hover.hovered && !row.picked ? actions.width : dateRow.width
            height: 22
            Row {
                id: dateRow
                anchors.right: parent.right
                spacing: 6
                visible: !(hover.hovered && !row.picked)
                Icon { visible: row.r && row.r.answered; app: row.app; name: "reply"; size: 14; color: row.app.th.sub1; anchors.verticalCenter: parent.verticalCenter }
                Icon { visible: row.r && row.r.att; app: row.app; name: "clip"; size: 15; color: row.app.th.sub1; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: row.r ? row.app.shortDate(row.r.date) : ""
                    color: row.unread ? row.app.th.accent : row.app.th.sub1
                    font.family: row.app.th.font
                    font.pixelSize: 12
                    font.weight: row.unread ? Font.DemiBold : Font.Normal
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Row {
                id: actions
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                visible: hover.hovered && !row.picked
                spacing: 0
                IconButton { app: row.app; size: 30; iconSize: 17; icon: "archive"; tip: "Archive"; onClicked: row.app.act("archive", row.r) }
                IconButton { app: row.app; size: 30; iconSize: 17; icon: "trash"; tip: "Delete"; onClicked: row.app.act("trash", row.r) }
                IconButton { app: row.app; size: 30; iconSize: 17; icon: row.unread ? "mail-open" : "mail-unread"; tip: row.unread ? "Mark as read" : "Mark as unread"; onClicked: row.app.toggleRead(row.r) }
            }
        }

        // line 2: subject (+ star)
        Text {
            id: subj
            anchors { left: parent.left; right: codeChip.visible ? codeChip.left : star.left; rightMargin: 6; top: who.bottom; topMargin: 3 }
            text: row.r ? (row.r.subject || "(no subject)") : ""
            elide: Text.ElideRight
            color: row.unread ? row.app.th.text : row.app.th.sub0
            font.family: row.app.th.font
            font.pixelSize: 14
            font.weight: row.unread ? Font.DemiBold : Font.Normal
        }
        // a login code: one click copies it
        Rectangle {
            id: codeChip
            visible: !!(row.r && row.r.code)
            anchors { right: star.left; rightMargin: 6; verticalCenter: subj.verticalCenter }
            height: 24
            width: visible ? codeRow.implicitWidth + 16 : 0
            radius: 12
            color: row.app.th.alpha(row.app.th.accent, chipHov.hovered ? 0.30 : 0.18)
            Row {
                id: codeRow
                anchors.centerIn: parent
                spacing: 5
                Icon { app: row.app; name: "key"; size: 13; color: row.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
                Text { text: row.r ? row.r.code : ""; color: row.app.th.text; font.family: row.app.th.mono; font.pixelSize: 12; font.weight: Font.Bold; anchors.verticalCenter: parent.verticalCenter }
            }
            HoverHandler { id: chipHov }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.app.copyText(row.r.code, "code") }
        }
        Icon {
            id: star
            anchors { right: parent.right; verticalCenter: subj.verticalCenter }
            app: row.app
            name: row.r && row.r.flagged ? "star" : "star-outline"
            size: 17
            visible: row.r && (row.r.flagged || hover.hovered)
            color: row.r && row.r.flagged ? "#f5c56b" : row.app.th.sub1
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: row.app.toggleStar(row.r) }
        }
        // line 3: snippet
        Text {
            anchors { left: parent.left; right: parent.right; top: subj.bottom; topMargin: 2 }
            text: row.r ? (row.r.snippet || "").trim() : ""
            elide: Text.ElideRight
            maximumLineCount: 1
            color: row.app.th.sub1
            font.family: row.app.th.font
            font.pixelSize: 13
        }
    }

    HoverHandler { id: hover }
}
