import QtQuick
import QtQuick.Effects

// The compose card (Gmail-style, bottom right): From, To / Cc / Bcc with address suggestions,
// Subject, the text, attachments. Ctrl+Enter sends (with 5 s to undo), Esc minimises.
// Everything typed is autosaved and survives closing the app.
Item {
    id: cw
    property var app
    readonly property var c: app.compose
    property string activeField: ""            // which address field shows suggestions

    function sync(field, value) { const o = {}; o[field] = value; app.setCompose(o); }
    function lastToken(s) { const i = Math.max(s.lastIndexOf(","), s.lastIndexOf(";")); return s.slice(i + 1).trim(); }
    function pick(field, contact) {
        const f = field === "to" ? toF : field === "cc" ? ccF : bccF;
        const s = f.text;
        const i = Math.max(s.lastIndexOf(","), s.lastIndexOf(";"));
        const v = (i >= 0 ? s.slice(0, i + 1) + " " : "") + app.fmtAddr([contact.name, contact.addr]) + ", ";
        f.text = v;
        sync(field, v);
        app.contacts = [];
        f.input.forceActiveFocus();
        f.input.cursorPosition = v.length;
    }
    onCChanged: {
        if (!c) return;
        // fill the fields when another draft is loaded (reply, restore) without fighting the typing
        if (toF.text !== c.to) toF.text = c.to;
        if (ccF.text !== (c.cc || "")) ccF.text = c.cc || "";
        if (bccF.text !== (c.bcc || "")) bccF.text = c.bcc || "";
        if (subF.text !== c.subject) subF.text = c.subject;
        if (bodyT.text !== c.body) bodyT.text = c.body;
    }
    property string loadedId: ""
    Connections {
        target: cw.app
        function onComposeChanged() {
            const c = cw.app.compose;
            if (!c || c.id === cw.loadedId) return;
            cw.loadedId = c.id;
            Qt.callLater(() => {
                if (!cw.app.compose) return;
                if (cw.app.compose.mode === "new" && !cw.app.compose.to) toF.input.forceActiveFocus();
                else { bodyT.forceActiveFocus(); bodyT.cursorPosition = 0; }
            });
        }
    }

    RectangularShadow { anchors.fill: parent; radius: 20; blur: 40; offset.y: 10; color: Qt.rgba(0, 0, 0, 0.45) }
    Rectangle {
        anchors.fill: parent
        radius: 20
        color: cw.app.th.alpha(cw.app.th.mix(cw.app.th.surface1, cw.app.th.deep, 0.18), 0.96)
        border.color: cw.app.th.alpha("white", 0.10)
    }
    MouseArea { anchors.fill: parent }        // keep clicks from reaching the list underneath

    // ---- title bar
    Item {
        id: title
        width: parent.width
        height: 52
        Text {
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 150
            text: cw.c ? (cw.c.subject.trim() || (cw.c.mode === "forward" ? "Forward" : cw.c.mode && cw.c.mode.startsWith("reply") ? "Reply" : "New message")) : ""
            elide: Text.ElideRight
            color: cw.app.th.text
            font.family: cw.app.th.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Row {
            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
            IconButton { app: cw.app; size: 34; iconSize: 18; icon: cw.app.composeMin ? "chev-up" : "chev-down"; tip: cw.app.composeMin ? "Open" : "Minimise · Esc"; onClicked: cw.app.composeMin = !cw.app.composeMin }
            IconButton { app: cw.app; size: 34; iconSize: 18; icon: "close"; tip: "Save draft and close"; onClicked: { cw.app.saveDraft(); cw.app.compose = null; cw.app.toast("save", "Draft saved — it reopens with the app", ""); } }
        }
        TapHandler { enabled: cw.app.composeMin; onTapped: cw.app.composeMin = false }
    }

    Item {
        id: content
        visible: !cw.app.composeMin
        anchors { top: title.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 16 }

        Keys.onPressed: ev => {
            if ((ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) && (ev.modifiers & Qt.ControlModifier)) { cw.app.sendNow(); ev.accepted = true; }
            else if (ev.key === Qt.Key_Escape) { if (cw.app.contacts.length) cw.app.contacts = []; else { cw.app.composeMin = true; cw.app.rootItem.forceActiveFocus(); } ev.accepted = true; }
        }

        Column {
            id: fields
            width: parent.width
            // From (only with several accounts)
            Item {
                width: parent.width
                height: 40
                visible: cw.app.multi
                Text { id: fromL; y: 11; text: "From"; color: cw.app.th.sub1; font.family: cw.app.th.font; font.pixelSize: 14 }
                Row {
                    anchors { left: fromL.right; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 6
                    Repeater {
                        model: cw.app.accounts
                        Chip {
                            required property var modelData
                            app: cw.app
                            height: 28
                            text: modelData.email
                            active: cw.c && cw.c.acc === modelData.id
                            onClicked: cw.app.setCompose({ acc: modelData.id })
                        }
                    }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: cw.app.th.alpha(cw.app.th.text, 0.08) }
            }
            Field {
                id: toF
                app: cw.app; flat: true; label: "To"; width: parent.width
                input.rightPadding: 60
                onEdited: { cw.sync("to", text); cw.activeField = "to"; cw.app.askContacts(cw.lastToken(text)); }
                input.onActiveFocusChanged: if (!input.activeFocus) Qt.callLater(() => { if (cw.activeField === "to" && !toF.input.activeFocus) cw.app.contacts = []; })
                Keys.onTabPressed: ev => { if (cw.app.contacts.length && cw.activeField === "to") cw.pick("to", cw.app.contacts[0]); else ev.accepted = false; }
                Text {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    visible: cw.c && !cw.c.showCc
                    text: "Cc  Bcc"
                    color: cw.app.th.sub1
                    font.family: cw.app.th.font
                    font.pixelSize: 13
                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: { cw.app.setCompose({ showCc: true }); ccF.input.forceActiveFocus(); } }
                }
            }
            Field {
                id: ccF
                app: cw.app; flat: true; label: "Cc"; width: parent.width
                visible: cw.c && cw.c.showCc
                onEdited: { cw.sync("cc", text); cw.activeField = "cc"; cw.app.askContacts(cw.lastToken(text)); }
            }
            Field {
                id: bccF
                app: cw.app; flat: true; label: "Bcc"; width: parent.width
                visible: cw.c && cw.c.showCc
                onEdited: { cw.sync("bcc", text); cw.activeField = "bcc"; cw.app.askContacts(cw.lastToken(text)); }
            }
            Field {
                id: subF
                app: cw.app; flat: true; placeholder: "Subject"; width: parent.width
                input.font.weight: Font.Medium
                onEdited: cw.sync("subject", text)
                onAccepted: bodyT.forceActiveFocus()
            }
        }

        // the text
        Flickable {
            id: bodyFlick
            anchors { top: fields.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: atts.top; bottomMargin: 8 }
            contentHeight: bodyT.contentHeight + 20
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            function ensureVisible(r) {
                if (contentY >= r.y) contentY = r.y;
                else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height + 8;
            }
            TextEdit {
                id: bodyT
                width: bodyFlick.width
                wrapMode: TextEdit.Wrap
                color: cw.app.th.text
                selectionColor: cw.app.th.alpha(cw.app.th.accent, 0.45)
                selectedTextColor: cw.app.th.text
                font.family: cw.app.th.font
                font.pixelSize: 15
                selectByMouse: true
                textFormat: TextEdit.PlainText
                onTextChanged: if (cw.c && text !== cw.c.body) cw.sync("body", text)
                onCursorRectangleChanged: bodyFlick.ensureVisible(cursorRectangle)
                Text {
                    visible: bodyT.text === "" && !bodyT.preeditText
                    text: "Write your message…"
                    color: cw.app.th.sub1
                    font: bodyT.font
                }
            }
            MouseArea { anchors.fill: parent; z: -1; cursorShape: Qt.IBeamCursor; onClicked: { bodyT.forceActiveFocus(); bodyT.cursorPosition = bodyT.length; } }
        }

        // attachments (own + a forward's originals)
        Flow {
            id: atts
            anchors { left: parent.left; right: parent.right; bottom: aiBar.top; bottomMargin: 10 }
            spacing: 6
            height: visible ? implicitHeight : 0
            visible: !!(cw.c && ((cw.c.attachments || []).length || (cw.c.forwardAtts || []).length))
            Repeater {
                model: cw.c ? (cw.c.forwardAtts || []).filter(a => (cw.c.forward ? cw.c.forward.keep : []).indexOf(a.i) >= 0).map(a => ({ name: a.name, size: a.size, fwd: a.i })).concat((cw.c.attachments || []).map((a, i) => ({ name: a.name, size: a.size, own: i }))) : []
                Rectangle {
                    required property var modelData
                    height: 32
                    width: chipRow.implicitWidth + 20
                    radius: 16
                    color: cw.app.th.alpha(cw.app.th.text, 0.08)
                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 6
                        Icon { app: cw.app; name: "clip"; size: 15; color: cw.app.th.sub0; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData.name + "  ·  " + cw.app.size(modelData.size || 0); color: cw.app.th.text; font.family: cw.app.th.font; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                        Icon {
                            app: cw.app; name: "close"; size: 15; color: cw.app.th.sub1; anchors.verticalCenter: parent.verticalCenter
                            MouseArea {
                                anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.own !== undefined) cw.app.setCompose({ attachments: cw.c.attachments.filter((a, i) => i !== modelData.own) });
                                    else cw.app.setCompose({ forward: Object.assign({}, cw.c.forward, { keep: cw.c.forward.keep.filter(k => k !== modelData.fwd) }) });
                                }
                            }
                        }
                    }
                }
            }
        }

        // AI: write from a prompt, or rewrite what's there (local model)
        Column {
            id: aiBar
            visible: cw.app.aiOn
            anchors { left: parent.left; right: parent.right; bottom: actions.top; bottomMargin: 10 }
            height: visible ? implicitHeight : 0
            spacing: 8
            readonly property bool busy: !!(cw.app.assist && cw.app.assist.loading)
            Rectangle {
                width: parent.width
                height: 40
                radius: 20
                color: cw.app.th.alpha(cw.app.th.accent, aiIn.activeFocus ? 0.16 : 0.09)
                border.color: cw.app.th.alpha(cw.app.th.accent, aiIn.activeFocus ? 0.6 : 0.2)
                Icon { id: aiIc; app: cw.app; x: 14; name: "sparkle"; size: 18; color: cw.app.th.accent; anchors.verticalCenter: parent.verticalCenter; visible: !aiBar.busy }
                Shimmer { app: cw.app; x: 14; width: 18; height: 18; anchors.verticalCenter: parent.verticalCenter; visible: aiBar.busy }
                TextInput {
                    id: aiIn
                    anchors { left: aiIc.right; leftMargin: 10; right: aiBtns.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    enabled: !aiBar.busy
                    color: cw.app.th.text
                    font.family: cw.app.th.font
                    font.pixelSize: 14
                    selectByMouse: true
                    clip: true
                    selectionColor: cw.app.th.alpha(cw.app.th.accent, 0.5)
                    onAccepted: { if (text.trim()) { cw.app.aiCompose("prompt", text.trim()); text = ""; } }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: aiIn.text === "" && !aiIn.preeditText
                        text: aiBar.busy ? (cw.app.aiState === "waking" ? "Waking the local AI…" : "Writing…")
                            : (cw.app.splitBody(cw.c ? cw.c.body || "" : "")[0].trim() ? "Ask AI to change it… (e.g. “say I’ll be late”)" : "Ask AI to write it… (e.g. “thank Lena, I’ll sign by Friday”)")
                        color: cw.app.th.sub1
                        font: aiIn.font
                    }
                }
                Row {
                    id: aiBtns
                    anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                    IconButton { visible: aiBar.busy; app: cw.app; size: 32; iconSize: 17; icon: "stop"; tip: "Stop"; onClicked: cw.app.stopAi(cw.app.assist.rid) }
                    IconButton {
                        visible: !aiBar.busy && !!cw.app.assist && cw.app.assist.before !== undefined && !!cw.c
                        app: cw.app; size: 32; iconSize: 17; icon: "undo"; tip: "Undo the AI change"
                        onClicked: cw.app.undoAssist()
                    }
                }
            }
            Flow {
                width: parent.width
                spacing: 6
                visible: !aiBar.busy && !!cw.c && cw.app.splitBody(cw.c.body || "")[0].trim() !== ""
                Repeater {
                    model: [["improve", "Improve"], ["shorten", "Shorter"], ["formal", "Formal"], ["friendly", "Friendly"], ["fix", "Fix grammar"], ["en", "→ EN"], ["ru", "→ RU"], ["ja", "→ JA"]]
                    Chip {
                        required property var modelData
                        app: cw.app
                        height: 28
                        text: modelData[1]
                        onClicked: cw.app.aiCompose(modelData[0], "")
                    }
                }
            }
        }

        // send bar
        Item {
            id: actions
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 44
            Row {
                spacing: 8
                anchors.verticalCenter: parent.verticalCenter
                PillButton { app: cw.app; filled: true; icon: "send"; text: "Send"; h: 42; onClicked: cw.app.sendNow() }
                IconButton { app: cw.app; icon: "clip"; tip: "Attach files"; anchors.verticalCenter: parent.verticalCenter; onClicked: cw.app.attach() }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Ctrl+Enter"
                    color: cw.app.th.sub1
                    font.family: cw.app.th.font
                    font.pixelSize: 12
                }
            }
            IconButton {
                app: cw.app; icon: "trash"; tip: "Discard draft"
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                onClicked: cw.app.discard()
            }
        }

        // address suggestions under the active field
        Rectangle {
            visible: cw.app.contacts.length > 0 && cw.activeField !== ""
            readonly property var anchorField: cw.activeField === "cc" ? ccF : cw.activeField === "bcc" ? bccF : toF
            x: 40
            y: anchorField.y + anchorField.height + 2
            width: Math.min(420, parent.width - 40)
            height: sugg.height + 10
            radius: 12
            z: 10
            color: cw.app.th.mix(cw.app.th.surface1, cw.app.th.base, 0.15)
            border.color: cw.app.th.alpha("white", 0.09)
            Column {
                id: sugg
                x: 5; y: 5
                width: parent.width - 10
                Repeater {
                    model: cw.app.contacts
                    Rectangle {
                        required property var modelData
                        required property int index
                        width: sugg.width
                        height: 44
                        radius: 9
                        color: cw.app.th.alpha(cw.app.th.text, sHov.hovered || index === 0 ? 0.09 : 0)
                        Avatar { id: sav; app: cw.app; size: 28; x: 8; anchors.verticalCenter: parent.verticalCenter; name: modelData.name; addr: modelData.addr }
                        Column {
                            anchors { left: sav.right; leftMargin: 10; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            Text { width: parent.width; text: modelData.name || modelData.addr; elide: Text.ElideRight; color: cw.app.th.text; font.family: cw.app.th.font; font.pixelSize: 13; font.weight: Font.Medium }
                            Text { width: parent.width; visible: !!modelData.name; text: modelData.addr; elide: Text.ElideRight; color: cw.app.th.sub1; font.family: cw.app.th.font; font.pixelSize: 12 }
                        }
                        HoverHandler { id: sHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: cw.pick(cw.activeField, modelData) }
                    }
                }
            }
        }
    }
}
