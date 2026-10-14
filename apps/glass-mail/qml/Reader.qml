import QtQuick

// The right island: the open message in a calm reader view (HTML rewritten into themed text
// and images by the backend), attachments, the rest of the conversation, quick reply.
Item {
    id: rd
    property var app
    property bool stacked: false
    property string hoverLink: ""
    readonly property var m: app.msg
    readonly property var r: app.cur
    readonly property real bodyW: Math.min(flick.width - 64, 820)

    Glass {
        anchors.fill: parent
        theme: rd.app.th
        radius: 18
        tintAlpha: 0.20
    }

    // ---- empty state
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: !rd.r
        Icon {
            app: rd.app
            anchors.horizontalCenter: parent.horizontalCenter
            name: rd.app.unread.unread ? "mail-outline" : "mailbox"
            size: 72
            color: rd.app.th.alpha(rd.app.th.text, 0.18)
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: rd.app.accounts.length === 0 ? "Welcome to Glass Mail"
                : rd.app.unread.unread ? rd.app.n(rd.app.unread.unread, "unread message") : "You’re all caught up"
            color: rd.app.th.sub0
            font.family: rd.app.th.font
            font.pixelSize: 20
            font.weight: Font.DemiBold
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "J / K to move · E archive · # delete · R reply · C compose"
            color: rd.app.th.sub1
            font.family: rd.app.th.font
            font.pixelSize: 13
        }
        PillButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: rd.app.aiOn && rd.app.accounts.length > 0 && rd.app.unread.unread > 0
            app: rd.app; filled: true; icon: "bolt"; text: "Catch me up"
            onClicked: rd.app.brief()
        }
    }

    // ---- toolbar
    Item {
        id: bar
        visible: !!rd.r
        x: 12; y: 12
        width: parent.width - 24
        height: 44
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            IconButton { visible: rd.stacked; app: rd.app; icon: "back"; tip: "Back · Esc"; onClicked: rd.app.closeMsg() }
            IconButton { app: rd.app; icon: "archive"; tip: "Archive · E"; onClicked: rd.app.act("archive") }
            IconButton { app: rd.app; icon: "trash"; tip: "Delete · #"; onClicked: rd.app.act("trash") }
            IconButton { app: rd.app; icon: rd.r && rd.r.seen ? "mail-unread" : "mail-open"; tip: rd.r && rd.r.seen ? "Mark as unread · U" : "Mark as read · U"; onClicked: rd.app.toggleRead() }
            IconButton {
                id: moveBtn
                app: rd.app; icon: "folder"; tip: "Move to…"
                onClicked: { const p = moveBtn.mapToItem(rd.app.rootItem, 0, 40); rd.app.moveMenu([rd.r], moveBtn, p.x, p.y); }
            }
        }
        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 2
            IconButton {
                app: rd.app; icon: rd.r && rd.r.flagged ? "star" : "star-outline"; tip: "Star · S"
                fg: rd.r && rd.r.flagged ? "#f5c56b" : (hovered ? rd.app.th.text : rd.app.th.sub0)
                onClicked: rd.app.toggleStar()
            }
            IconButton {
                visible: rd.app.aiOn
                app: rd.app; icon: "translate"; tip: "Translate · T"
                active: !!(rd.app.translation && rd.r && rd.app.translation.key === rd.app.key(rd.r) && rd.app.translation.on)
                enabledState: !!rd.m && !rd.m.error
                onClicked: rd.app.translate()
            }
            IconButton { app: rd.app; icon: "reply"; tip: "Reply · R"; enabledState: !!rd.m && !rd.m.error; onClicked: rd.app.reply(false) }
            IconButton { app: rd.app; icon: "reply-all"; tip: "Reply all · A"; enabledState: !!rd.m && !rd.m.error; onClicked: rd.app.reply(true) }
            IconButton { app: rd.app; icon: "forward"; tip: "Forward · F"; enabledState: !!rd.m && !rd.m.error; onClicked: rd.app.forward() }
            IconButton {
                id: more
                app: rd.app; icon: "dots-v"; tip: "More"
                onClicked: { const p = more.mapToItem(rd.app.rootItem, 0, 0); rd.app.msgMenu(more, p.x - 230, p.y + 40); }
            }
        }
    }

    // ---- the message
    Flickable {
        id: flick
        visible: !!rd.r
        anchors { top: bar.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6 }
        contentHeight: body.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Connections { target: rd.app; function onMsgChanged() { flick.contentY = 0; } }

        Column {
            id: body
            x: 32
            width: rd.bodyW
            spacing: 16
            topPadding: 14

            // subject
            Text {
                width: parent.width
                text: rd.m && rd.m.subject !== undefined ? (rd.m.subject || "(no subject)") : (rd.r ? (rd.r.subject || "") : "")
                wrapMode: Text.Wrap
                color: rd.app.th.text
                font.family: rd.app.th.font
                font.pixelSize: 26
                font.weight: Font.Bold
                lineHeight: 1.1
            }
            // folder / account chips
            Row {
                spacing: 6
                visible: !!rd.r
                Rectangle {
                    height: 24; radius: 12
                    width: fl.implicitWidth + 20
                    color: rd.app.th.alpha(rd.app.th.text, 0.08)
                    Text {
                        id: fl
                        anchors.centerIn: parent
                        text: { const f = rd.r ? rd.app.folderOf(rd.r.acc, rd.r.folder) : null; return f ? f.name : (rd.r ? rd.r.folder : ""); }
                        color: rd.app.th.sub0
                        font.family: rd.app.th.font
                        font.pixelSize: 12
                    }
                }
                Rectangle {
                    visible: rd.app.multi
                    height: 24; radius: 12
                    width: ac.implicitWidth + 30
                    color: rd.app.th.alpha(rd.r ? rd.app.accColor(rd.r.acc) : rd.app.th.accent, 0.16)
                    Rectangle { x: 10; width: 7; height: 7; radius: 3.5; anchors.verticalCenter: parent.verticalCenter; color: rd.r ? rd.app.accColor(rd.r.acc) : "transparent" }
                    Text {
                        id: ac
                        x: 22
                        anchors.verticalCenter: parent.verticalCenter
                        text: rd.r && rd.app.account(rd.r.acc) ? rd.app.account(rd.r.acc).email : ""
                        color: rd.app.th.sub0
                        font.family: rd.app.th.font
                        font.pixelSize: 12
                    }
                }
            }

            // sender block
            Item {
                width: parent.width
                height: 52
                visible: !!rd.m && !rd.m.error
                Avatar {
                    id: av
                    app: rd.app
                    size: 46
                    name: rd.m && rd.m.from && rd.m.from.length ? rd.m.from[0][0] : ""
                    addr: rd.m && rd.m.from && rd.m.from.length ? rd.m.from[0][1] : ""
                }
                Column {
                    anchors { left: av.right; leftMargin: 14; right: dateT.left; rightMargin: 12; verticalCenter: av.verticalCenter }
                    spacing: 3
                    Row {
                        width: parent.width
                        spacing: 8
                        Text {
                            id: nameT
                            text: rd.m && rd.m.from && rd.m.from.length ? (rd.m.from[0][0] || rd.m.from[0][1]) : ""
                            color: rd.app.th.text
                            font.family: rd.app.th.font
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, parent.width * 0.6)
                        }
                        Text {
                            anchors.baseline: nameT.baseline
                            visible: rd.m && rd.m.from && rd.m.from.length && rd.m.from[0][0] !== ""
                            text: rd.m && rd.m.from && rd.m.from.length ? "<" + rd.m.from[0][1] + ">" : ""
                            color: rd.app.th.sub1
                            font.family: rd.app.th.font
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, parent.width - nameT.width - 8)
                        }
                    }
                    Text {
                        width: parent.width
                        text: {
                            if (!rd.m || !rd.m.to) return "";
                            const me = rd.app.myAddrs();
                            const fmt = p => me.indexOf((p[1] || "").toLowerCase()) >= 0 ? "me" : (p[0] || p[1]);
                            let s = "to " + (rd.m.to.length ? rd.m.to.map(fmt).join(", ") : "undisclosed recipients");
                            if (rd.m.cc && rd.m.cc.length) s += " · cc " + rd.m.cc.map(fmt).join(", ");
                            return s;
                        }
                        elide: Text.ElideRight
                        color: rd.app.th.sub1
                        font.family: rd.app.th.font
                        font.pixelSize: 13
                    }
                }
                Column {
                    id: dateT
                    anchors { right: parent.right; verticalCenter: av.verticalCenter }
                    spacing: 4
                    Text {
                        anchors.right: parent.right
                        text: rd.m ? rd.app.fullDate(rd.m.date) : ""
                        color: rd.app.th.sub1
                        font.family: rd.app.th.font
                        font.pixelSize: 12
                    }
                    Text {
                        anchors.right: parent.right
                        visible: !!(rd.m && rd.m.unsub)
                        text: "Unsubscribe"
                        color: rd.app.th.accent
                        font.family: rd.app.th.font
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: rd.app.unsubscribe() }
                    }
                }
            }

            // a login code: big and one click away
            Rectangle {
                width: parent.width
                height: 64
                radius: 18
                visible: !!(rd.m && rd.m.code)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: rd.app.th.alpha(rd.app.th.accent, 0.22) }
                    GradientStop { position: 1; color: rd.app.th.alpha(rd.app.th.accent2, 0.12) }
                }
                border.color: rd.app.th.alpha(rd.app.th.accent, 0.3)
                Icon { id: keyIc; app: rd.app; x: 18; name: "key"; size: 24; color: rd.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
                Column {
                    anchors { left: keyIc.right; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    Text { text: "Login code"; color: rd.app.th.sub1; font.family: rd.app.th.font; font.pixelSize: 12 }
                    Text {
                        text: rd.m && rd.m.code ? rd.m.code : ""
                        color: rd.app.th.text
                        font.family: rd.app.th.mono
                        font.pixelSize: 24
                        font.weight: Font.Bold
                        font.letterSpacing: 3
                    }
                }
                PillButton {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    app: rd.app; filled: true; icon: "copy"; text: "Copy"; h: 38
                    onClicked: rd.app.copyText(rd.m.code, "code")
                }
            }

            AiCard { app: rd.app; width: parent.width }

            // remote images are blocked until asked
            Rectangle {
                width: parent.width
                height: 46
                radius: 14
                visible: !!(rd.m && rd.m.remote > 0 && !rd.app.showImages)
                color: rd.app.th.alpha(rd.app.th.accent2, 0.12)
                Icon { id: imgOff; x: 14; app: rd.app; name: "image-off"; size: 19; color: rd.app.th.accent2; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    anchors { left: imgOff.right; leftMargin: 10; right: imgBtns.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: "Images are hidden so senders can’t track you."
                    elide: Text.ElideRight
                    color: rd.app.th.sub0
                    font.family: rd.app.th.font
                    font.pixelSize: 13
                }
                Row {
                    id: imgBtns
                    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    spacing: 4
                    PillButton { app: rd.app; h: 32; fontSize: 13; text: "Show"; onClicked: rd.app.allowImages(false) }
                    PillButton { app: rd.app; h: 32; fontSize: 13; text: rd.bodyW > 640 ? "Always from sender" : "Always"; onClicked: rd.app.allowImages(true) }
                }
            }

            // loading / error
            Text {
                visible: rd.app.msgLoading
                text: "Opening…"
                color: rd.app.th.sub1
                font.family: rd.app.th.font
                font.pixelSize: 14
            }
            Text {
                visible: !!(rd.m && rd.m.error)
                width: parent.width
                wrapMode: Text.Wrap
                text: rd.m && rd.m.error ? rd.m.error : ""
                color: rd.app.th.bad
                font.family: rd.app.th.font
                font.pixelSize: 14
            }

            // translation (streamed) instead of the original
            readonly property bool translated: !!(rd.app.translation && rd.r && rd.app.translation.key === rd.app.key(rd.r) && rd.app.translation.on)
            Rectangle {
                visible: body.translated
                width: parent.width
                height: 34
                radius: 12
                color: rd.app.th.alpha(rd.app.th.text, 0.06)
                Row {
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 8
                    Icon { app: rd.app; name: "translate"; size: 16; color: rd.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
                    Shimmer { app: rd.app; width: 15; height: 15; visible: !!(rd.app.translation && rd.app.translation.loading); anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: rd.app.translation ? (rd.app.translation.loading && !rd.app.translation.text ? rd.app.aiWaitText() : "Translated to " + rd.app.langName(rd.app.translation.target) + " by the local AI") : ""
                        color: rd.app.th.sub0
                        font.family: rd.app.th.font
                        font.pixelSize: 13
                    }
                }
                Text {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: "Show original"
                    color: rd.app.th.accent
                    font.family: rd.app.th.font
                    font.pixelSize: 13
                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: rd.app.translate() }
                }
            }
            TextEdit {
                visible: body.translated
                width: parent.width
                text: rd.app.translation ? (rd.app.translation.error || rd.app.translation.text) : ""
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: rd.app.translation && rd.app.translation.error ? rd.app.th.bad : rd.app.th.text
                selectionColor: rd.app.th.alpha(rd.app.th.accent, 0.45)
                font.family: rd.app.th.font
                font.pixelSize: 15
            }

            // body
            Repeater {
                model: rd.m && rd.m.blocks && !body.translated ? rd.m.blocks : []
                delegate: Loader {
                    required property var modelData
                    width: body.width
                    sourceComponent: modelData.t === "text" ? textC : modelData.t === "img" ? imgC : hrC
                    property var b: modelData
                }
            }

            // attachments
            Flow {
                width: parent.width
                spacing: 10
                visible: !!(rd.m && rd.m.attachments && rd.m.attachments.length)
                topPadding: 6
                Repeater {
                    model: rd.m && rd.m.attachments ? rd.m.attachments : []
                    AttachmentChip {
                        required property var modelData
                        app: rd.app
                        a: modelData
                    }
                }
            }

            // the rest of the conversation
            Column {
                width: parent.width
                spacing: 4
                visible: !!(rd.m && rd.m.thread && rd.m.thread.length)
                topPadding: 10
                SectionLabel { app: rd.app; x: 0; text: "In this conversation" }
                Repeater {
                    model: rd.m && rd.m.thread ? rd.m.thread : []
                    Rectangle {
                        required property var modelData
                        width: body.width
                        height: 48
                        radius: 12
                        color: rd.app.th.alpha(rd.app.th.text, thHov.hovered ? 0.08 : 0.04)
                        Avatar { id: tav; app: rd.app; size: 30; x: 10; anchors.verticalCenter: parent.verticalCenter; name: modelData.from_name; addr: modelData.from_addr }
                        Text {
                            anchors { left: tav.right; leftMargin: 12; right: tdate.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: "<b>" + rd.app.sender(modelData).replace(/</g, "&lt;") + "</b>&nbsp;&nbsp;<span style='color:" + rd.app.th.hex(rd.app.th.sub1) + "'>" + (modelData.snippet || modelData.subject || "").replace(/</g, "&lt;") + "</span>"
                            textFormat: Text.StyledText
                            elide: Text.ElideRight
                            color: rd.app.th.text
                            font.family: rd.app.th.font
                            font.pixelSize: 13
                        }
                        Text {
                            id: tdate
                            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            text: rd.app.shortDate(modelData.date)
                            color: rd.app.th.sub1
                            font.family: rd.app.th.font
                            font.pixelSize: 12
                        }
                        HoverHandler { id: thHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: rd.app.open(modelData) }
                    }
                }
            }

            // quick reply
            Row {
                spacing: 8
                topPadding: 8
                visible: !!(rd.m && !rd.m.error && rd.m.blocks)
                PillButton { app: rd.app; icon: "reply"; text: "Reply"; onClicked: rd.app.reply(false) }
                PillButton { app: rd.app; icon: "reply-all"; text: "Reply all"; visible: !!(rd.m && rd.m.to && (rd.m.to.length + (rd.m.cc ? rd.m.cc.length : 0)) > 1); onClicked: rd.app.reply(true) }
                PillButton { app: rd.app; icon: "forward"; text: "Forward"; onClicked: rd.app.forward() }
            }
        }
    }

    // where a hovered link goes (like a browser's status bubble)
    Rectangle {
        visible: rd.hoverLink !== ""
        anchors { left: parent.left; bottom: parent.bottom; margins: 12 }
        width: Math.min(linkT.implicitWidth + 20, parent.width - 24)
        height: 28
        radius: 8
        color: rd.app.th.alpha(rd.app.th.surface2, 0.96)
        Text {
            id: linkT
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            verticalAlignment: Text.AlignVCenter
            text: rd.hoverLink
            elide: Text.ElideMiddle
            color: rd.app.th.sub0
            font.family: rd.app.th.font
            font.pixelSize: 12
        }
    }

    Component {
        id: textC
        TextEdit {
            readonly property var b: parent ? parent.b : null
            width: parent ? parent.width : 100
            leftPadding: b && b.q ? 14 : 0
            text: b ? b.html : ""
            textFormat: TextEdit.RichText
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            color: rd.app.th.text
            selectionColor: rd.app.th.alpha(rd.app.th.accent, 0.45)
            selectedTextColor: rd.app.th.text
            font.family: rd.app.th.font
            font.pixelSize: 15
            onLinkActivated: link => rd.app.openLink(link)
            onLinkHovered: link => rd.hoverLink = link
            Rectangle {
                visible: !!(parent.b && parent.b.q)
                width: 3; radius: 1.5
                height: parent.height
                color: rd.app.th.alpha(rd.app.th.text, 0.16)
            }
            HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
        }
    }
    Component {
        id: imgC
        Item {
            id: ib
            readonly property var b: parent ? parent.b : null
            readonly property string source: b ? (b.src || (rd.app.showImages && b.url ? b.url : "")) : ""
            readonly property real natW: b && b.w > 0 ? b.w : (img.sourceSize.width > 0 ? img.sourceSize.width : 0)
            width: parent ? parent.width : 100
            height: source === "" ? (b && b.alt ? 30 : 0) : (img.status === Image.Ready ? img.height : 60)
            Image {
                id: img
                visible: ib.source !== ""
                source: ib.source
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                width: Math.min(ib.width, ib.natW || ib.width)
                height: sourceSize.width > 0 ? width * sourceSize.height / sourceSize.width : 60
                smooth: true
                mipmap: true
                MouseArea {
                    anchors.fill: parent
                    enabled: !!(ib.b && ib.b.href)
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    hoverEnabled: true
                    onEntered: if (ib.b && ib.b.href) rd.hoverLink = ib.b.href
                    onExited: rd.hoverLink = ""
                    onClicked: rd.app.openLink(ib.b.href)
                }
            }
            Rectangle {
                visible: img.visible && img.status !== Image.Ready
                width: Math.min(ib.width, ib.natW || 240); height: 60; radius: 10
                color: rd.app.th.alpha(rd.app.th.text, 0.05)
            }
            // hidden remote image: just its alt text, quietly
            Row {
                visible: ib.source === "" && !!(ib.b && ib.b.alt)
                spacing: 6
                height: 30
                Icon { app: rd.app; name: "image-outline"; size: 15; color: rd.app.th.sub1; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ib.b ? ib.b.alt : ""
                    color: rd.app.th.sub1
                    font.family: rd.app.th.font
                    font.pixelSize: 12
                    font.italic: true
                }
            }
        }
    }
    Component {
        id: hrC
        Item {
            width: parent ? parent.width : 100
            height: 9
            Rectangle { anchors.centerIn: parent; width: parent.width; height: 1; color: rd.app.th.alpha(rd.app.th.text, 0.1) }
        }
    }
}
