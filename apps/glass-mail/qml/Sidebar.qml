import QtQuick

// Left column: Compose, then All inboxes / Starred, then each account's folders with unread
// counts, and Accounts & settings at the bottom. Collapses to icons in narrow windows.
Item {
    id: side
    property var app
    property bool collapsed: false

    Glass {
        anchors.fill: parent
        theme: side.app.th
        radius: 18
        tintAlpha: 0.26
    }

    // Compose
    Rectangle {
        id: compose
        x: 10; y: 12
        width: parent.width - 20
        height: 52
        radius: 18
        color: hov.hovered ? Qt.lighter(side.app.th.accent, 1.07) : side.app.th.accent
        scale: tap.pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 160 } }
        Row {
            anchors.centerIn: parent
            spacing: 10
            Icon { app: side.app; name: "pencil"; size: 21; color: side.app.th.onAccent; anchors.verticalCenter: parent.verticalCenter }
            Text {
                visible: !side.collapsed
                text: "Compose"
                color: side.app.th.onAccent
                font.family: side.app.th.font
                font.pixelSize: 15
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
        TapHandler { id: tap; onTapped: side.app.newMessage() }
        ToolTipLite { app: side.app; text: "Compose · C"; shown: hov.hovered && side.collapsed; below: true }
    }

    Flickable {
        id: flick
        anchors { top: compose.bottom; topMargin: 12; left: parent.left; right: parent.right; bottom: foot.top; leftMargin: 6; rightMargin: 6 }
        contentHeight: col.height + 8
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: flick.width
            spacing: 1

            FolderItem {
                visible: side.app.multi
                app: side.app; collapsed: side.collapsed
                icon: "inboxes"; title: "All inboxes"
                count: side.app.unread.unread || 0
                active: !side.app.searching && side.app.page === "" && side.app.view && side.app.view.acc === "*"
                onClicked: side.app.setView({ acc: "*", role: "inbox" })
            }
            FolderItem {
                app: side.app; collapsed: side.collapsed
                icon: "star"; title: "Starred"
                active: !side.app.searching && side.app.page === "" && side.app.view && side.app.view.kind === "starred"
                onClicked: side.app.setView({ kind: "starred" })
            }

            Repeater {
                model: side.app.accounts
                Column {
                    id: accCol
                    required property var modelData
                    width: col.width
                    readonly property var acc: modelData
                    readonly property var st: modelData.status || {}
                    property bool open: true
                    Item { width: 1; height: 10 }
                    // account header: colour dot, address, state
                    Item {
                        width: parent.width
                        height: 30
                        visible: !side.collapsed
                        Rectangle { id: dot; x: 12; width: 8; height: 8; radius: 4; color: accCol.acc.color; anchors.verticalCenter: parent.verticalCenter }
                        Text {
                            anchors { left: dot.right; leftMargin: 9; right: stIcon.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            text: accCol.acc.email
                            elide: Text.ElideMiddle
                            color: side.app.th.sub1
                            font.family: side.app.th.font
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.3
                        }
                        Icon {
                            id: stIcon
                            app: side.app
                            anchors { right: chev.left; rightMargin: 2; verticalCenter: parent.verticalCenter }
                            visible: accCol.st.state === "offline" || accCol.st.state === "auth"
                            name: accCol.st.state === "auth" ? "warn" : "offline"
                            size: 15
                            color: accCol.st.state === "auth" ? side.app.th.bad : side.app.th.sub1
                            HoverHandler { id: stHov }
                            ToolTipLite { app: side.app; text: accCol.st.text || ""; shown: stHov.hovered && text !== "" }
                            TapHandler { onTapped: if (accCol.st.state === "auth") { side.app.openSettings(); side.app.editAccount = accCol.acc; } }
                        }
                        Icon {
                            id: chev
                            app: side.app
                            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            name: accCol.open ? "chev-down" : "chev-right"
                            size: 16
                            color: side.app.th.sub1
                        }
                        TapHandler { onTapped: accCol.open = !accCol.open }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                    Rectangle {
                        visible: side.collapsed
                        width: parent.width - 24; x: 12; height: 1
                        color: side.app.th.alpha(side.app.th.text, 0.08)
                    }
                    Repeater {
                        model: accCol.open || side.collapsed ? (side.app.folders[accCol.acc.id] || []) : []
                        FolderItem {
                            required property var modelData
                            app: side.app; collapsed: side.collapsed
                            visible: !side.collapsed || ["inbox", "sent", "drafts", "archive", "trash"].indexOf(modelData.role) >= 0
                            icon: side.app.roleIcon(modelData.role)
                            title: modelData.name
                            depth: modelData.depth
                            count: modelData.role === "sent" || modelData.role === "trash" || modelData.role === "all" ? 0
                                 : modelData.role === "drafts" ? modelData.total : modelData.unread
                            strong: modelData.role === "inbox" || modelData.role === "junk" ? modelData.unread > 0 : false
                            tint: side.app.multi ? accCol.acc.color : side.app.th.accent
                            active: !side.app.searching && side.app.page === "" && side.app.view && side.app.view.acc === accCol.acc.id && side.app.view.folder === modelData.path
                            onClicked: side.app.setView({ acc: accCol.acc.id, folder: modelData.path })
                        }
                    }
                }
            }
        }
    }

    // bottom: accounts & settings
    Item {
        id: foot
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 6 }
        height: 52
        FolderItem {
            anchors.verticalCenter: parent.verticalCenter
            app: side.app; collapsed: side.collapsed
            icon: "cog"; title: "Accounts & settings"
            active: side.app.page === "settings"
            onClicked: side.app.page === "settings" ? side.app.closeSettings() : side.app.openSettings()
        }
    }
}
