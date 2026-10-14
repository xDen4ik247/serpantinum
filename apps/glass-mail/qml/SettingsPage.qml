import QtQuick

// Accounts & settings (over the list + reader): accounts with sign-in state, the add / edit
// form (app passwords, server presets), reading and notification options, keyboard shortcuts.
Item {
    id: sp
    property var app
    property var form: ({})
    property bool advanced: false
    property var guess: null

    Glass {
        anchors.fill: parent
        theme: sp.app.th
        radius: 18
        tintAlpha: 0.22
    }

    function startEdit(a) {
        app.accountResult = null;
        advanced = false;
        if (a && a.id) {
            form = { id: a.id, email: a.email, name: a.name || "", user: a.user || a.email, password: "",
                     imapHost: a.imap.host, imapPort: String(a.imap.port), smtpHost: a.smtp.host,
                     smtpPort: String(a.smtp.port), smtpSecurity: a.smtp.security, signature: a.signature || "" };
        } else form = { email: "", name: "", password: "", signature: "" };
        emailF.text = form.email; nameF.text = form.name; passF.text = "";
        userF.text = form.user || ""; imapF.text = form.imapHost || ""; imapPortF.text = form.imapPort || "";
        smtpF.text = form.smtpHost || ""; smtpPortF.text = form.smtpPort || ""; sigT.text = form.signature || "";
        guess = presetFor(form.email);
        Qt.callLater(() => (form.id ? passF : emailF).input.forceActiveFocus());
    }
    Connections {
        target: sp.app
        function onEditAccountChanged() { if (sp.app.editAccount) sp.startEdit(sp.app.editAccount); }
    }
    Component.onCompleted: if (app.editAccount) startEdit(app.editAccount)

    // the same presets as glassmail/accounts.py, for the hint while typing
    function presetFor(email) {
        const d = (email.split("@")[1] || "").toLowerCase();
        const p = {
            gmail: ["Gmail", "https://myaccount.google.com/apppasswords", "Turn on 2-Step Verification, then create an app password (Google Account → Security → App passwords). Your normal password won’t work."],
            yandex: ["Yandex Mail", "https://id.yandex.ru/security/app-passwords", "Create an app password for Mail (Yandex ID → Security → App passwords) and allow IMAP in Mail settings → Mail clients."],
            mailru: ["Mail.ru", "https://account.mail.ru/user/2-step-auth/passwords", "Create a password for external apps (Mail.ru account → Security)."],
            outlook: ["Outlook", "https://account.live.com/proofs/AppPassword", "Use an app password (Microsoft account → Security → Advanced security options)."],
            icloud: ["iCloud Mail", "https://account.apple.com/account/manage", "Create an app-specific password at account.apple.com → Sign-In and Security."]
        };
        const map = { "gmail.com": "gmail", "googlemail.com": "gmail", "yandex.ru": "yandex", "ya.ru": "yandex", "yandex.com": "yandex",
                      "mail.ru": "mailru", "inbox.ru": "mailru", "list.ru": "mailru", "bk.ru": "mailru",
                      "outlook.com": "outlook", "hotmail.com": "outlook", "live.com": "outlook",
                      "icloud.com": "icloud", "me.com": "icloud" };
        const k = map[d];
        return k ? { label: p[k][0], url: p[k][1], hint: p[k][2] } : (d ? { label: d, url: "", hint: "Use your mail password, or an app password if your provider has two-step sign-in. Check the servers under Advanced." } : null);
    }
    function save() {
        const d = {
            id: form.id || "", email: emailF.text.trim(), name: nameF.text.trim(), password: passF.text,
            signature: sigT.text
        };
        if (advanced || form.id) {
            d.user = userF.text.trim(); d.imapHost = imapF.text.trim(); d.imapPort = imapPortF.text.trim();
            d.smtpHost = smtpF.text.trim(); d.smtpPort = smtpPortF.text.trim(); d.smtpSecurity = form.smtpSecurity || "";
        }
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.email)) { app.accountResult = { ok: false, text: "That doesn’t look like an email address." }; return; }
        if (!d.password && !form.id) { app.accountResult = { ok: false, text: "Enter the (app) password." }; return; }
        app.saveAccount(d);
    }

    // ---- header
    Item {
        id: head
        x: 24; y: 18
        width: parent.width - 48
        height: 44
        Row {
            spacing: 12
            anchors.verticalCenter: parent.verticalCenter
            Icon { app: sp.app; name: "cog"; size: 26; color: sp.app.th.accent; anchors.verticalCenter: parent.verticalCenter }
            Text { text: sp.app.accounts.length ? "Accounts & settings" : "Welcome to Glass Mail"; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 26; font.weight: Font.Bold; anchors.verticalCenter: parent.verticalCenter }
        }
        IconButton {
            visible: sp.app.accounts.length > 0
            app: sp.app; icon: "close"; tip: "Close · Esc"
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            onClicked: sp.app.closeSettings()
        }
    }
    Row {
        id: tabs
        anchors { top: head.bottom; topMargin: 14; left: parent.left; leftMargin: 24 }
        spacing: 6
        visible: sp.app.accounts.length > 0
        Chip { app: sp.app; text: "Accounts"; active: sp.app.settingsTab === "accounts"; onClicked: sp.app.settingsTab = "accounts" }
        Chip { app: sp.app; text: "Reading & notifications"; active: sp.app.settingsTab === "prefs"; onClicked: sp.app.settingsTab = "prefs" }
        Chip { app: sp.app; text: "AI & codes"; active: sp.app.settingsTab === "ai"; onClicked: sp.app.settingsTab = "ai" }
        Chip { app: sp.app; text: "Keyboard"; active: sp.app.settingsTab === "keys"; onClicked: sp.app.settingsTab = "keys" }
    }

    Flickable {
        id: flick
        anchors { top: tabs.bottom; topMargin: 16; left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 24; rightMargin: 12; bottomMargin: 12 }
        contentHeight: col.height + 30
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: Math.min(flick.width - 12, 720)
            spacing: 12

            // ================= accounts
            Column {
                width: parent.width
                spacing: 10
                visible: sp.app.settingsTab === "accounts" && !sp.app.editAccount
                Repeater {
                    model: sp.app.accounts
                    Rectangle {
                        required property var modelData
                        readonly property var st: modelData.status || {}
                        width: col.width
                        height: 72
                        radius: 16
                        color: sp.app.th.alpha(sp.app.th.text, 0.06)
                        Avatar { id: aav; app: sp.app; size: 44; x: 14; anchors.verticalCenter: parent.verticalCenter; name: modelData.name || modelData.email; addr: modelData.email }
                        Rectangle { width: 12; height: 12; radius: 6; x: aav.x + 34; y: aav.y + 32; color: modelData.color; border.color: sp.app.th.base; border.width: 2 }
                        Column {
                            anchors { left: aav.right; leftMargin: 14; right: btns.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            spacing: 3
                            Text { width: parent.width; text: modelData.email; elide: Text.ElideRight; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 15; font.weight: Font.DemiBold }
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: parent.parent.st.state === "auth" ? "Sign-in failed — edit to enter a new password"
                                    : parent.parent.st.state === "offline" ? "Offline · " + (parent.parent.st.text || "")
                                    : (modelData.name ? modelData.name + " · " : "") + modelData.imap.host
                                color: parent.parent.st.state === "auth" ? sp.app.th.bad : sp.app.th.sub1
                                font.family: sp.app.th.font
                                font.pixelSize: 12
                            }
                        }
                        Row {
                            id: btns
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            IconButton { app: sp.app; icon: "pencil-outline"; tip: "Edit"; onClicked: sp.app.editAccount = modelData }
                            IconButton { app: sp.app; icon: "logout"; tip: "Remove from Glass Mail"; onClicked: confirmRemove.target = modelData }
                        }
                    }
                }
                // remove confirmation
                Rectangle {
                    id: confirmRemove
                    property var target: null
                    visible: target !== null
                    width: col.width
                    height: 64
                    radius: 16
                    color: sp.app.th.alpha(sp.app.th.bad, 0.12)
                    Text {
                        anchors { left: parent.left; leftMargin: 16; right: cbtns.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        text: confirmRemove.target ? "Remove " + confirmRemove.target.email + "? Mail stays on the server; only this app forgets it." : ""
                        wrapMode: Text.WordWrap
                        color: sp.app.th.text
                        font.family: sp.app.th.font
                        font.pixelSize: 13
                    }
                    Row {
                        id: cbtns
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        PillButton { app: sp.app; h: 34; text: "Cancel"; onClicked: confirmRemove.target = null }
                        PillButton { app: sp.app; h: 34; text: "Remove"; danger: true; onClicked: { sp.app.send({ cmd: "account-remove", id: confirmRemove.target.id }); confirmRemove.target = null; } }
                    }
                }
                PillButton { app: sp.app; icon: "plus"; text: "Add account"; onClicked: sp.app.editAccount = ({}) }
            }

            // ================= add / edit form
            Column {
                width: parent.width
                spacing: 10
                visible: !!sp.app.editAccount && (sp.app.settingsTab === "accounts" || !sp.app.accounts.length)
                Text {
                    width: parent.width
                    text: sp.form.id ? "Edit " + sp.form.email : (sp.app.accounts.length ? "Add an account" : "Sign in to your mail")
                    color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 18; font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    visible: !sp.form.id
                    wrapMode: Text.WordWrap
                    text: "Gmail, Yandex, Mail.ru, Outlook, iCloud or any IMAP mail. Glass Mail signs in with an app password, kept only on this computer (~/.config/glass-mail, readable by you alone)."
                    color: sp.app.th.sub1; font.family: sp.app.th.font; font.pixelSize: 13
                }
                Field {
                    id: emailF
                    app: sp.app; width: parent.width; placeholder: "you@example.com"
                    enabled: !sp.form.id
                    opacity: enabled ? 1 : 0.6
                    onEdited: sp.guess = sp.presetFor(text)
                    onAccepted: passF.input.forceActiveFocus()
                }
                Field { id: nameF; app: sp.app; width: parent.width; placeholder: "Your name (shown to people you write to)"; onAccepted: passF.input.forceActiveFocus() }
                Field { id: passF; app: sp.app; width: parent.width; password: true; placeholder: sp.form.id ? "New app password (leave empty to keep)" : "App password"; onAccepted: sp.save() }
                // provider hint
                Rectangle {
                    width: parent.width
                    visible: !!sp.guess
                    height: hintCol.implicitHeight + 22
                    radius: 14
                    color: sp.app.th.alpha(sp.app.th.accent, 0.10)
                    Column {
                        id: hintCol
                        x: 14; y: 11
                        width: parent.width - 28
                        spacing: 6
                        Text { width: parent.width; text: sp.guess ? sp.guess.label : ""; color: sp.app.th.accent; font.family: sp.app.th.font; font.pixelSize: 13; font.weight: Font.DemiBold }
                        Text { width: parent.width; text: sp.guess ? sp.guess.hint : ""; wrapMode: Text.WordWrap; color: sp.app.th.sub0; font.family: sp.app.th.font; font.pixelSize: 13 }
                        Text {
                            visible: !!(sp.guess && sp.guess.url)
                            text: "Open the app-password page ↗"
                            color: sp.app.th.accent; font.family: sp.app.th.font; font.pixelSize: 13; font.weight: Font.Medium
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sp.app.openLink(sp.guess.url) }
                        }
                    }
                }
                Text {
                    text: (sp.advanced || sp.form.id ? "▾ " : "▸ ") + "Advanced: servers and user name"
                    color: sp.app.th.sub0; font.family: sp.app.th.font; font.pixelSize: 13
                    visible: !sp.form.id
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sp.advanced = !sp.advanced }
                }
                Column {
                    width: parent.width
                    spacing: 8
                    visible: sp.advanced || !!sp.form.id
                    Field { id: userF; app: sp.app; width: parent.width; label: "User"; placeholder: "same as the address" }
                    Row {
                        spacing: 8
                        Field { id: imapF; app: sp.app; width: col.width - 128; label: "IMAP"; placeholder: "imap.example.com (auto)" }
                        Field { id: imapPortF; app: sp.app; width: 120; label: "Port"; placeholder: "993" }
                    }
                    Row {
                        spacing: 8
                        Field { id: smtpF; app: sp.app; width: col.width - 128; label: "SMTP"; placeholder: "smtp.example.com (auto)" }
                        Field { id: smtpPortF; app: sp.app; width: 120; label: "Port"; placeholder: "465"; onEdited: sp.form = Object.assign({}, sp.form, { smtpSecurity: text === "465" ? "ssl" : text === "587" ? "starttls" : sp.form.smtpSecurity }) }
                    }
                }
                Text { text: "Signature"; color: sp.app.th.sub0; font.family: sp.app.th.font; font.pixelSize: 13; topPadding: 4 }
                Rectangle {
                    width: parent.width
                    height: 90
                    radius: 12
                    color: sp.app.th.alpha(sp.app.th.text, sigT.activeFocus ? 0.12 : 0.07)
                    border.color: sp.app.th.alpha(sigT.activeFocus ? sp.app.th.accent : "white", sigT.activeFocus ? 0.7 : 0.08)
                    TextEdit {
                        id: sigT
                        anchors { fill: parent; margins: 12 }
                        wrapMode: TextEdit.Wrap
                        color: sp.app.th.text
                        font.family: sp.app.th.font
                        font.pixelSize: 14
                        selectByMouse: true
                        clip: true
                        Text { visible: sigT.text === ""; text: "Added under new messages and replies (optional)"; color: sp.app.th.sub1; font: sigT.font }
                    }
                }
                Text {
                    width: parent.width
                    visible: !!(sp.app.accountResult && !sp.app.accountResult.ok)
                    wrapMode: Text.WordWrap
                    text: sp.app.accountResult ? (sp.app.accountResult.text || "") : ""
                    color: sp.app.th.bad; font.family: sp.app.th.font; font.pixelSize: 13
                }
                Row {
                    spacing: 8
                    topPadding: 4
                    PillButton {
                        app: sp.app; filled: true; icon: sp.app.accountBusy ? "refresh" : "login"
                        text: sp.app.accountBusy ? "Signing in…" : (sp.form.id ? "Save" : "Sign in")
                        enabledState: !sp.app.accountBusy
                        onClicked: sp.save()
                    }
                    PillButton { visible: sp.app.accounts.length > 0; app: sp.app; text: "Cancel"; onClicked: sp.app.editAccount = null }
                }
            }

            // ================= preferences
            Column {
                width: parent.width
                spacing: 2
                visible: sp.app.settingsTab === "prefs" && !sp.app.editAccount
                Toggle { app: sp.app; width: parent.width; title: "Mark as read when opened"; on: sp.app.settings.markRead !== false; onToggled: v => sp.app.setSetting("markRead", v) }
                Toggle { app: sp.app; width: parent.width; title: "Open the next message after archiving or deleting"; on: sp.app.settings.openNext !== false; onToggled: v => sp.app.setSetting("openNext", v) }
                Toggle { app: sp.app; width: parent.width; title: "Notifications for new mail"; desc: "Arrives instantly while Glass Mail is open (IMAP IDLE); a background check every few minutes covers the rest."; on: sp.app.settings.notify !== false; onToggled: v => sp.app.setSetting("notify", v) }
                Toggle { app: sp.app; width: parent.width; title: "Always show images"; desc: "Off: remote images wait until you click Show, so senders can’t see when you read their mail. Senders you allowed: " + ((sp.app.settings.imagesFrom || []).length || "none") + "."; on: !!sp.app.settings.imagesAlways; onToggled: v => sp.app.setSetting("imagesAlways", v) }
                Item {
                    width: parent.width
                    height: 52
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Check for mail every"; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 14; font.weight: Font.Medium }
                    Row {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        Repeater {
                            model: [1, 3, 5, 15]
                            Chip { required property var modelData; app: sp.app; text: modelData + " min"; active: (sp.app.settings.pollMinutes || 3) === modelData; onClicked: sp.app.setSetting("pollMinutes", modelData) }
                        }
                    }
                }
            }

            // ================= AI & login codes
            Column {
                width: parent.width
                spacing: 2
                visible: sp.app.settingsTab === "ai" && !sp.app.editAccount
                Rectangle {
                    width: parent.width
                    height: aiInfo.implicitHeight + 24
                    radius: 14
                    color: sp.app.th.alpha(sp.app.th.accent, 0.08)
                    Text {
                        id: aiInfo
                        x: 14; y: 12
                        width: parent.width - 28
                        wrapMode: Text.WordWrap
                        text: "Everything runs on the local model (npu-llm, Qwen on the Arc GPU) — no mail leaves this laptop. "
                            + "It wakes on demand (about 45 s the first time) and sleeps when idle. "
                            + "State: " + ({ idle: "asleep", waking: "waking up…", ready: "ready", off: "not reachable" })[sp.app.aiState]
                        color: sp.app.th.sub0
                        font.family: sp.app.th.font
                        font.pixelSize: 13
                    }
                }
                Item { width: 1; height: 6 }
                Toggle { app: sp.app; width: parent.width; title: "AI features"; desc: "Summaries, smart replies, writing help, translation, Ask your mail, Catch me up."; on: sp.app.settings.aiOn !== false; onToggled: v => sp.app.setSetting("aiOn", v) }
                Toggle { app: sp.app; width: parent.width; title: "Summarize automatically"; desc: "When you stay on a message for a second. Off: click ✨ Summarize."; on: sp.app.settings.aiAuto !== false; onToggled: v => sp.app.setSetting("aiAuto", v) }
                Item {
                    width: parent.width
                    height: 52
                    Text { anchors.verticalCenter: parent.verticalCenter; text: "Translate messages to"; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 14; font.weight: Font.Medium }
                    Row {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        Repeater {
                            model: [["ru", "Russian"], ["en", "English"], ["ja", "Japanese"]]
                            Chip { required property var modelData; app: sp.app; text: modelData[1]; active: (sp.app.settings.translateTo || "ru") === modelData[0]; onClicked: sp.app.setSetting("translateTo", modelData[0]) }
                        }
                    }
                }
                Item { width: 1; height: 10 }
                SectionLabel { app: sp.app; x: 0; text: "Login codes" }
                Toggle { app: sp.app; width: parent.width; title: "Copy login codes automatically"; desc: "Like on iPhone: a new verification code is on the clipboard within seconds (even with the app closed), with a notification; the clipboard clears after 3 minutes."; on: sp.app.settings.autoCopyCodes !== false; onToggled: v => sp.app.setSetting("autoCopyCodes", v) }
                Item {
                    width: parent.width
                    height: 64
                    Column {
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                        spacing: 3
                        Text { text: "After the code is copied, the email…"; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 14; font.weight: Font.Medium }
                        Text { text: "Trash keeps it restorable; starred code mails are never moved."; color: sp.app.th.sub1; font.family: sp.app.th.font; font.pixelSize: 12 }
                    }
                    Row {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 6
                        Repeater {
                            model: [["now", "Trash now"], ["day", "After a day"], ["keep", "Keep"]]
                            Chip {
                                required property var modelData
                                app: sp.app
                                text: modelData[1]
                                active: (sp.app.settings.codesTrash || (sp.app.settings.codesCleanup ? "day" : "now")) === modelData[0]
                                onClicked: sp.app.setSetting("codesTrash", modelData[0])
                            }
                        }
                    }
                }
            }

            // ================= keyboard
            Grid {
                visible: sp.app.settingsTab === "keys" && !sp.app.editAccount
                columns: 2
                columnSpacing: 28
                rowSpacing: 10
                Repeater {
                    model: [["J / K, ↓ / ↑", "Next / previous message"], ["C, Ctrl+N", "Compose"], ["R / A / F", "Reply / reply all / forward"],
                            ["E", "Archive"], ["# or Delete", "Delete (Shift+Delete: forever)"], ["!", "Report spam"], ["S", "Star"],
                            ["U", "Read / unread"], ["X, Ctrl+click", "Select; Shift+click selects a range"], ["Ctrl+A", "Select all"],
                            ["Z, Ctrl+Z", "Undo the last move"], ["/ or Ctrl+F", "Search"], ["Ctrl+R, F5", "Check for mail"],
                            ["Ctrl+Enter", "Send (5 s to undo)"], ["Esc", "Clear / close / minimise"], ["Ctrl+,", "Settings"],
                            ["T", "Translate (AI)"], ["B", "Catch me up (AI)"], ["… ? + Enter", "Ask your mail (AI)"]].reduce((a, p) => a.concat(p), [])
                    Item {
                        required property var modelData
                        required property int index
                        width: index % 2 === 0 ? 170 : 360
                        height: 30
                        Rectangle {
                            visible: parent.index % 2 === 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: kt.implicitWidth + 18; height: 28; radius: 8
                            color: sp.app.th.alpha(sp.app.th.text, 0.09)
                            Text { id: kt; anchors.centerIn: parent; text: parent.parent.modelData; color: sp.app.th.text; font.family: sp.app.th.font; font.pixelSize: 13; font.weight: Font.DemiBold }
                        }
                        Text { visible: parent.index % 2 === 1; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData; color: sp.app.th.sub0; font.family: sp.app.th.font; font.pixelSize: 14 }
                    }
                }
            }
        }
    }
}
