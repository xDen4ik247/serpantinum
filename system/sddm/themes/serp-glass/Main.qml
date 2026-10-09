import QtQuick
import QtQuick.Effects
import QtQml.Models
import "components"

// serp-glass — liquid-glass SDDM greeter matching the niri + Serpantinum desktop.
// Wallpaper + Matugen palette come from theme.conf.user (written by
// ~/.local/bin/greeter-sync); everything is sized from the screen height so it is
// crisp on the 2880x1800 panel under both the X11 (DPR 1) and Wayland greeters.
Item {
    id: root
    width: 1920
    height: 1200

    // ---------------------------------------------------------------- scale
    readonly property real u: Math.max(0.5, Math.min(width / 1920, height / 1200))
    function px(v) { return Math.round(v * u) }

    // ---------------------------------------------------------------- config
    function cfg(k, d) {
        var v = (typeof config !== "undefined" && config) ? config[k] : undefined
        return (v === undefined || v === null || String(v) === "") ? d : String(v)
    }
    function fileUrl(p) { return p.indexOf("/") === 0 ? "file://" + p : p }

    readonly property color cBase:     cfg("base", "#0e1415")
    readonly property color cMantle:   cfg("mantle", "#161d1d")
    readonly property color cText:     cfg("text", "#dde4e4")
    readonly property color cSubtext:  cfg("subtext", "#bec8c9")
    readonly property color cMuted:    cfg("muted", "#899393")
    readonly property color cAccent:   cfg("accent", "#80d4db")
    readonly property color cAccent2:  cfg("accent2", "#b7c7ea")
    readonly property color cOnAccent: cfg("accentInk", "#004f54")
    readonly property color cError:    cfg("error", "#ffb4ab")
    readonly property bool idleSharp:  cfg("idleSharp", "true") !== "false"
    readonly property int idleSeconds: parseInt(cfg("idleSeconds", "40"))

    readonly property string fontSans: cfg("font", "Google Sans")
    readonly property string fontIcon: cfg("iconFont", "JetBrainsMono Nerd Font")

    // Nerd Font (Material Design) glyphs
    readonly property string icLock:    "\u{F033E}"
    readonly property string icArrow:   "\u{F0054}"
    readonly property string icPower:   "\u{F0425}"
    readonly property string icReboot:  "\u{F0709}"
    readonly property string icSleep:   "\u{F0904}"
    readonly property string icKbd:     "\u{F030C}"
    readonly property string icSession: "\u{F0379}"
    readonly property string icChevUp:  "\u{F0143}"
    readonly property string icCheck:   "\u{F012C}"
    readonly property string icCaps:    "\u{F0632}"
    readonly property string icAlert:   "\u{F0028}"
    readonly property string icSwap:    "\u{F04E1}"

    // ---------------------------------------------------------------- sddm glue
    readonly property bool hasSddm: typeof sddm !== "undefined" && sddm !== null
    readonly property var kb: (typeof keyboard !== "undefined" && keyboard) ? keyboard : null
    readonly property bool kbAvailable: kb !== null && kb.layouts !== undefined && kb.layouts.length > 0
    readonly property bool capsOn: kb !== null && kb.capsLock === true

    property int userIndex: (typeof userModel !== "undefined" && userModel.lastIndex >= 0) ? userModel.lastIndex : 0
    property int sessionIndex: 0
    readonly property var curUser: userInst.count > 0 ? userInst.objectAt(Math.min(userIndex, userInst.count - 1)) : null
    readonly property var curSession: sessionInst.count > 0 ? sessionInst.objectAt(Math.min(sessionIndex, sessionInst.count - 1)) : null
    readonly property string userLogin: curUser ? curUser.login : ""
    readonly property string userName: curUser ? (curUser.real !== "" ? curUser.real : curUser.login) : "user"

    Instantiator {
        id: userInst
        model: typeof userModel !== "undefined" ? userModel : null
        delegate: QtObject {
            required property var model
            readonly property string login: model.name || ""
            readonly property string real: model.realName || ""
            readonly property string icon: model.icon || ""
        }
    }
    Instantiator {
        id: sessionInst
        model: typeof sessionModel !== "undefined" ? sessionModel : null
        delegate: QtObject {
            required property var model
            readonly property string name: model.name || ""
            readonly property string file: model.file || ""
        }
        onObjectAdded: root.pickSession()
    }
    // niri is the default; otherwise remember SDDM's last session
    function pickSession() {
        for (var i = 0; i < sessionInst.count; i++) {
            var o = sessionInst.objectAt(i)
            if (o && (o.file.toLowerCase().indexOf("niri") >= 0 || o.name.toLowerCase() === "niri")) {
                sessionIndex = i; return
            }
        }
        if (typeof sessionModel !== "undefined" && sessionModel.lastIndex >= 0) sessionIndex = sessionModel.lastIndex
    }

    // ---------------------------------------------------------------- state
    property bool awake: false
    property bool busy: false
    property bool failed: false
    property bool sessionsOpen: false
    property real t: awake ? 1 : 0                 // 0 = clock view, 1 = login view
    Behavior on t { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }

    function wake() {
        if (!awake) awake = true
        idleTimer.restart()
    }
    function login() {
        if (busy) return
        wake()
        if (pwd.text.length === 0) { field.shake(); return }
        busy = true
        failed = false
        if (hasSddm) sddm.login(userLogin, pwd.text, sessionIndex)
    }

    Timer {
        id: idleTimer
        interval: root.idleSeconds * 1000
        onTriggered: {
            if (pwd.text.length === 0 && !root.busy && !root.sessionsOpen) root.awake = false
            else restart()
        }
    }

    Connections {
        target: root.hasSddm ? sddm : null
        ignoreUnknownSignals: true
        function onLoginFailed() {
            root.busy = false
            root.failed = true
            pwd.text = ""
            field.shake()
            pwd.forceActiveFocus()
        }
        function onLoginSucceeded() {
            outro.start()
        }
    }

    Component.onCompleted: {
        pickSession()
        intro.start()
        pwd.forceActiveFocus()
    }

    // ================================================================ background
    Rectangle { anchors.fill: parent; color: root.cBase }

    Item {
        id: bgLayer
        anchors.fill: parent
        property real zoom: 1.06
        scale: zoom + 0.025 * root.t
        transformOrigin: Item.Center

        Image {
            id: bgSharp
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: false
            smooth: true
            source: root.fileUrl(root.cfg("background", "assets/bg.jpg"))
            onStatusChanged: if (status === Image.Error && source != "assets/bg.jpg") source = "assets/bg.jpg"
            visible: root.idleSharp && bgBlur.opacity < 1
        }
        Image {
            id: bgBlur
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            smooth: true
            source: root.fileUrl(root.cfg("backgroundBlur", "assets/bg-blur.jpg"))
            onStatusChanged: if (status === Image.Error && source != "assets/bg-blur.jpg") source = "assets/bg-blur.jpg"
            opacity: root.idleSharp ? root.t : 1
        }
    }

    // legibility: dim + soft top/bottom gradients (Matugen base)
    Rectangle {
        anchors.fill: parent
        color: root.cBase
        opacity: 0.10 + 0.22 * root.t
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.45) }
            GradientStop { position: 0.38; color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.0) }
            GradientStop { position: 0.70; color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.55) }
        }
    }

    // any pointer activity wakes the greeter
    // (ignore the first event: X11 reports the parked cursor when the greeter maps)
    HoverHandler {
        property point last: Qt.point(-1, -1)
        onPointChanged: {
            var p = point.position
            if (last.x >= 0 && (Math.abs(p.x - last.x) + Math.abs(p.y - last.y)) > 3) root.wake()
            last = p
        }
    }
    TapHandler { onTapped: { root.sessionsOpen = false; root.wake(); pwd.forceActiveFocus() } }

    // ================================================================ content
    Item {
        id: content
        anchors.fill: parent
        opacity: 0

        // ------------------------------------------------------------ clock
        Item {
            id: clockBox
            width: clockCol.width
            height: clockCol.height
            anchors.horizontalCenter: parent.horizontalCenter
            readonly property real idleY: root.height * 0.40 - height / 2
            readonly property real awakeY: root.height * 0.205 - height / 2
            y: idleY + (awakeY - idleY) * root.t
            transformOrigin: Item.Center

            // soft dark halo so the clock reads on bright wallpapers
            RectangularShadow {
                anchors.centerIn: parent
                width: parent.width * 0.9
                height: parent.height * 0.75
                radius: height / 2
                blur: root.px(150)
                spread: 0
                color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.55 - 0.35 * root.t)
                cached: true
            }

            Column {
                id: clockCol
                spacing: -root.px(14 - 8 * root.t)
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: Qt.rgba(0, 0, 0, 0.5)
                    shadowBlur: 0.9
                    shadowVerticalOffset: root.px(3)
                    autoPaddingEnabled: true
                }

                Text {
                    id: timeText
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: root.fontSans
                    font.pixelSize: Math.round(root.u * (200 - 84 * root.t))
                    font.weight: Font.DemiBold
                    font.letterSpacing: -root.u * (6 - 3 * root.t)
                    font.features: { "tnum": 1 }
                    color: root.cText
                    text: Qt.formatTime(clock.now, "HH:mm")
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: root.fontSans
                    font.pixelSize: Math.round(root.u * (30 - 10 * root.t))
                    font.weight: Font.DemiBold
                    color: root.cText
                    opacity: 0.92
                    text: Qt.formatDate(clock.now, "dddd, MMMM d")
                }
            }
        }

        QtObject {
            id: clock
            property date now: new Date()
        }
        Timer {
            interval: 1000; running: true; repeat: true
            onTriggered: clock.now = new Date()
        }

        // idle hint (glass pill)
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.height - root.px(110) + root.px(20) * root.t
            width: hintRow.width + root.px(36)
            height: root.px(44)
            opacity: 1 - root.t
            visible: opacity > 0.01
            Glass {
                anchors.fill: parent
                tintColor: root.cBase
                tintAlpha: 0.40
                shadowBlur: root.px(16)
                shadowY: root.px(3)
                rimWidth: Math.max(1, root.u)
            }
            Row {
                id: hintRow
                anchors.centerIn: parent
                spacing: root.px(10)
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: root.fontIcon
                    font.pixelSize: root.px(16)
                    color: root.cAccent
                    text: root.icLock
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: root.fontSans
                    font.pixelSize: root.px(15)
                    font.weight: Font.Medium
                    color: root.cText
                    text: "Start typing to sign in"
                }
            }
        }

        // ------------------------------------------------------------ login card
        Item {
            id: card
            width: root.px(420)
            height: cardCol.height + root.px(36) + root.px(14)
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.height * 0.585 - height / 2 + root.px(56) * (1 - root.t)
            opacity: root.t
            scale: 0.94 + 0.06 * root.t
            visible: opacity > 0.01
            enabled: root.awake

            Glass {
                anchors.fill: parent
                radius: root.px(28)
                tintColor: root.cBase
                tintAlpha: 0.40
                shadowBlur: root.px(36)
                shadowY: root.px(10)
                shadowAlpha: 0.35
                rimWidth: Math.max(1, root.u)
                sheen: 0.06
            }

            Column {
                id: cardCol
                y: root.px(36)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 0

                // avatar
                Item {
                    id: avatar
                    width: root.px(112); height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property string src: {
                        var a = root.cfg("avatar", "")
                        if (a !== "") return root.fileUrl(a)
                        if (root.curUser && root.curUser.icon !== "" && root.curUser.icon.indexOf("root.face") < 0
                                && root.curUser.icon.indexOf("/.face.icon") < 0) return root.fileUrl(root.curUser.icon)
                        return ""
                    }
                    readonly property bool hasImage: src !== "" && avImg.status === Image.Ready

                    // glowing accent halo
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + root.px(14); height: width; radius: width / 2
                        color: "transparent"
                        border.width: Math.max(1, root.px(2))
                        border.color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, field.focused ? 0.55 : 0.28)
                        Behavior on border.color { ColorAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    }
                    // monogram fallback
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        visible: !avatar.hasImage
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0; color: Qt.lighter(root.cAccent, 1.08) }
                            GradientStop { position: 1; color: root.cAccent2 }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: root.userName.length > 0 ? root.userName.charAt(0).toUpperCase() : "?"
                            font.family: root.fontSans
                            font.pixelSize: root.px(50)
                            font.weight: Font.Bold
                            color: root.cOnAccent
                        }
                    }
                    Image {
                        id: avImg
                        anchors.fill: parent
                        source: avatar.src
                        sourceSize.width: width * 2
                        fillMode: Image.PreserveAspectCrop
                        visible: false
                        smooth: true
                        mipmap: true
                    }
                    MultiEffect {
                        anchors.fill: parent
                        source: avImg
                        visible: avatar.hasImage
                        maskEnabled: true
                        maskSource: avMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }
                    Item {
                        id: avMask
                        anchors.fill: parent
                        layer.enabled: true
                        visible: false
                        Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
                    }
                }

                Item { width: 1; height: root.px(18) }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: root.fontSans
                    font.pixelSize: root.px(15)
                    font.weight: Font.Medium
                    color: root.cSubtext
                    text: {
                        var h = clock.now.getHours()
                        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
                    }
                }
                Item { width: 1; height: root.px(2) }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: root.px(8)
                    Text {
                        id: nameText
                        font.family: root.fontSans
                        font.pixelSize: root.px(30)
                        font.weight: Font.Bold
                        color: root.cText
                        text: root.userName
                    }
                    Text {   // switch user (only when there is more than one)
                        visible: userInst.count > 1
                        anchors.verticalCenter: nameText.verticalCenter
                        font.family: root.fontIcon
                        font.pixelSize: root.px(18)
                        color: swapMouse.containsMouse ? root.cAccent : root.cMuted
                        text: root.icSwap
                        MouseArea {
                            id: swapMouse
                            anchors.fill: parent; anchors.margins: -root.px(6)
                            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.userIndex = (root.userIndex + 1) % userInst.count; pwd.forceActiveFocus() }
                        }
                    }
                }

                Item { width: 1; height: root.px(24) }

                // ---------------------------------------------- password field
                Item {
                    id: field
                    width: root.px(336)
                    height: root.px(56)
                    anchors.horizontalCenter: parent.horizontalCenter
                    readonly property bool focused: pwd.activeFocus && root.awake
                    property real shakeX: 0
                    transform: Translate { x: field.shakeX }

                    function shake() { shakeAnim.restart() }
                    SequentialAnimation {
                        id: shakeAnim
                        NumberAnimation { target: field; property: "shakeX"; to: -root.px(16); duration: 60; easing.type: Easing.OutCubic }
                        NumberAnimation { target: field; property: "shakeX"; to: root.px(13); duration: 80; easing.type: Easing.InOutCubic }
                        NumberAnimation { target: field; property: "shakeX"; to: -root.px(9); duration: 80; easing.type: Easing.InOutCubic }
                        NumberAnimation { target: field; property: "shakeX"; to: root.px(5); duration: 80; easing.type: Easing.InOutCubic }
                        NumberAnimation { target: field; property: "shakeX"; to: 0; duration: 160; easing.type: Easing.OutQuint }
                    }

                    // focus glow
                    RectangularShadow {
                        anchors.fill: parent
                        radius: height / 2
                        blur: root.px(22)
                        spread: 0
                        color: root.failed ? root.cError : root.cAccent
                        opacity: root.failed ? 0.40 : (field.focused ? 0.30 : 0)
                        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 300 } }
                    }
                    Glass {
                        anchors.fill: parent
                        radius: height / 2
                        tintColor: root.cMantle
                        tintAlpha: field.focused ? 0.62 : 0.48
                        raised: false
                        lit: field.focused || root.failed
                        rimColor: root.failed ? root.cError : (field.focused ? Qt.lighter(root.cAccent, 1.25) : "white")
                        rimWidth: Math.max(1, root.u * 1.1)
                        sheen: 0.04
                        Behavior on rimColor { ColorAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }

                    Text {
                        id: lockIcon
                        x: root.px(20)
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: root.fontIcon
                        font.pixelSize: root.px(19)
                        color: root.failed ? root.cError : (field.focused ? root.cAccent : root.cMuted)
                        text: root.icLock
                        Behavior on color { ColorAnimation { duration: 300 } }
                    }

                    // dots area
                    Item {
                        id: dotsArea
                        anchors.left: lockIcon.right
                        anchors.leftMargin: root.px(14)
                        anchors.right: submit.left
                        anchors.rightMargin: root.px(10)
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        clip: true

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: root.fontSans
                            font.pixelSize: root.px(16)
                            color: root.failed ? root.cError : root.cMuted
                            opacity: pwd.text.length === 0 ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            text: root.failed ? "Wrong password, try again" : "Password"
                        }

                        Row {
                            id: dots
                            anchors.verticalCenter: parent.verticalCenter
                            x: Math.min(0, dotsArea.width - width)
                            spacing: root.px(7)
                            Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                            Repeater {
                                model: dotModel
                                delegate: Rectangle {
                                    width: root.px(10); height: width; radius: width / 2
                                    color: root.cText
                                    scale: 0
                                    Component.onCompleted: popIn.start()
                                    NumberAnimation on scale { id: popIn; running: false; from: 0; to: 1; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
                                }
                            }
                        }
                    }
                    ListModel { id: dotModel }

                    TextInput {
                        id: pwd
                        anchors.fill: dotsArea
                        echoMode: TextInput.Password
                        color: "transparent"
                        selectionColor: "transparent"
                        selectedTextColor: "transparent"
                        cursorVisible: false
                        cursorDelegate: Item {}
                        font.pixelSize: root.px(16)
                        verticalAlignment: TextInput.AlignVCenter
                        enabled: !root.busy
                        focus: true
                        passwordMaskDelay: 0
                        onTextChanged: {
                            while (dotModel.count > text.length) dotModel.remove(dotModel.count - 1)
                            while (dotModel.count < text.length) dotModel.append({})
                            if (text.length > 0) { root.failed = false; root.wake() }
                        }
                        Keys.onPressed: function (event) {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                root.login(); event.accepted = true
                            } else if (event.key === Qt.Key_Escape) {
                                if (root.sessionsOpen) root.sessionsOpen = false
                                else if (text.length > 0) text = ""
                                else root.awake = false
                                event.accepted = true
                            } else {
                                root.wake()
                            }
                        }
                    }

                    // submit button
                    Item {
                        id: submit
                        width: root.px(44); height: width
                        anchors.right: parent.right
                        anchors.rightMargin: root.px(6)
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property bool ready: pwd.text.length > 0 || root.busy
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: submit.ready ? root.cAccent : Qt.rgba(1, 1, 1, subMouse.containsMouse ? 0.16 : 0.08)
                            scale: subMouse.pressed ? 0.92 : 1
                            Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        }
                        Text {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: submit.ready ? 0 : -root.px(1)
                            font.family: root.fontIcon
                            font.pixelSize: root.px(22)
                            color: submit.ready ? root.cOnAccent : root.cMuted
                            text: root.icArrow
                            opacity: root.busy ? 0 : 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        // spinner while authenticating (only runs while busy)
                        Item {
                            anchors.fill: parent
                            anchors.margins: root.px(11)
                            opacity: root.busy ? 1 : 0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                            Rectangle {
                                anchors.fill: parent; radius: width / 2
                                color: "transparent"
                                border.width: Math.max(2, root.px(2.5))
                                border.color: Qt.rgba(root.cOnAccent.r, root.cOnAccent.g, root.cOnAccent.b, 0.25)
                            }
                            Item {
                                id: spinArc
                                anchors.fill: parent
                                clip: true
                                Item {
                                    width: parent.width / 2; height: parent.height / 2
                                    clip: true
                                    Rectangle {
                                        width: spinArc.width; height: spinArc.height; radius: width / 2
                                        color: "transparent"
                                        border.width: Math.max(2, root.px(2.5))
                                        border.color: root.cOnAccent
                                    }
                                }
                                RotationAnimator on rotation {
                                    from: 0; to: 360; duration: 900; loops: Animation.Infinite
                                    running: root.busy
                                }
                            }
                        }
                        MouseArea {
                            id: subMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.login()
                        }
                    }
                }

                // message slot (fixed height: no layout jumps)
                Item {
                    width: field.width
                    height: root.px(42)
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        id: capsChip
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: root.capsOn ? root.px(2) : -root.px(6)
                        height: root.px(28)
                        width: capsRow.width + root.px(24)
                        radius: height / 2
                        color: Qt.rgba(root.cAccent2.r, root.cAccent2.g, root.cAccent2.b, 0.18)
                        border.width: Math.max(1, root.u)
                        border.color: Qt.rgba(root.cAccent2.r, root.cAccent2.g, root.cAccent2.b, 0.35)
                        opacity: root.capsOn ? 1 : 0
                        visible: opacity > 0.01
                        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
                        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 450; easing.type: Easing.OutQuint } }
                        Row {
                            id: capsRow
                            anchors.centerIn: parent
                            spacing: root.px(7)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: root.fontIcon; font.pixelSize: root.px(14)
                                color: root.cAccent2; text: root.icCaps
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: root.fontSans; font.pixelSize: root.px(13); font.weight: Font.DemiBold
                                color: root.cAccent2; text: "Caps Lock is on"
                            }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------ bottom-left: session + keyboard
        Item {
            id: leftIsland
            x: root.px(28)
            y: root.height - height - root.px(28) + root.px(30) * (1 - root.t)
            width: leftRow.width + root.px(12)
            height: root.px(52)
            opacity: root.t
            visible: opacity > 0.01
            enabled: root.awake

            Glass {
                anchors.fill: parent
                tintColor: root.cBase
                tintAlpha: 0.45
                shadowBlur: root.px(16)
                shadowY: root.px(3)
                rimWidth: Math.max(1, root.u)
            }
            Row {
                id: leftRow
                anchors.centerIn: parent
                spacing: root.px(6)
                Chip {
                    id: sessionChip
                    u: root.u
                    icon: root.icSession
                    label: root.curSession ? root.curSession.name : "Session"
                    trailing: root.icChevUp
                    showLabel: true
                    fg: root.cText
                    iconFont: root.fontIcon; textFont: root.fontSans
                    onClicked: { root.sessionsOpen = !root.sessionsOpen; root.wake() }
                }
                Chip {
                    visible: root.kbAvailable
                    u: root.u
                    icon: root.icKbd
                    label: root.kbAvailable ? String(root.kb.layouts[Math.max(0, root.kb.currentLayout)].shortName).toUpperCase() : ""
                    showLabel: true
                    fg: root.cText
                    iconFont: root.fontIcon; textFont: root.fontSans
                    onClicked: {
                        if (root.kbAvailable && root.kb.layouts.length > 1)
                            root.kb.currentLayout = (root.kb.currentLayout + 1) % root.kb.layouts.length
                        root.wake(); pwd.forceActiveFocus()
                    }
                }
            }
        }

        // session popup
        MouseArea {      // click-away catcher
            anchors.fill: parent
            visible: root.sessionsOpen
            onClicked: root.sessionsOpen = false
        }
        Item {
            id: sessionPop
            x: leftIsland.x
            width: Math.max(root.px(240), sessCol.width + root.px(16))
            height: sessCol.height + root.px(16)
            y: leftIsland.y - height - root.px(10) + (root.sessionsOpen ? 0 : root.px(14))
            opacity: root.sessionsOpen ? 1 : 0
            scale: root.sessionsOpen ? 1 : 0.96
            transformOrigin: Item.BottomLeft
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 450; easing.type: Easing.OutQuint } }
            Behavior on y { NumberAnimation { duration: 450; easing.type: Easing.OutQuint } }

            Glass {
                anchors.fill: parent
                radius: root.px(20)
                tintColor: root.cBase
                tintAlpha: 0.62
                shadowBlur: root.px(24)
                shadowY: root.px(6)
                rimWidth: Math.max(1, root.u)
            }
            Column {
                id: sessCol
                x: root.px(8); y: root.px(8)
                Repeater {
                    model: sessionInst.count
                    delegate: Rectangle {
                        required property int index
                        readonly property var s: sessionInst.objectAt(index)
                        readonly property bool current: index === root.sessionIndex
                        width: Math.max(root.px(224), rowS.width + root.px(28))
                        height: root.px(42)
                        radius: root.px(14)
                        color: current ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.20)
                                       : Qt.rgba(1, 1, 1, sMouse.containsMouse ? 0.10 : 0)
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Row {
                            id: rowS
                            x: root.px(14)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: root.px(10)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: root.fontIcon; font.pixelSize: root.px(16)
                                color: current ? root.cAccent : root.cMuted
                                text: current ? root.icCheck : root.icSession
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: root.fontSans; font.pixelSize: root.px(15)
                                font.weight: current ? Font.DemiBold : Font.Medium
                                color: root.cText
                                text: s ? s.name : ""
                            }
                        }
                        MouseArea {
                            id: sMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.sessionIndex = index; root.sessionsOpen = false; pwd.forceActiveFocus() }
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------ bottom-right: power
        Item {
            id: powerIsland
            x: root.width - width - root.px(28)
            y: root.height - height - root.px(28) + root.px(30) * (1 - root.t)
            width: powerRow.width + root.px(12)
            height: root.px(52)
            opacity: root.t
            visible: opacity > 0.01
            enabled: root.awake

            property string armedAction: ""
            Timer { id: disarm; interval: 3500; onTriggered: powerIsland.armedAction = "" }
            function act(name, fn) {
                root.wake()
                if (name === "suspend") { fn(); return }
                if (armedAction === name) { armedAction = ""; disarm.stop(); fn() }
                else { armedAction = name; disarm.restart() }
            }

            Glass {
                anchors.fill: parent
                tintColor: root.cBase
                tintAlpha: 0.45
                shadowBlur: root.px(16)
                shadowY: root.px(3)
                rimWidth: Math.max(1, root.u)
            }
            Row {
                id: powerRow
                anchors.centerIn: parent
                spacing: root.px(6)
                layoutDirection: Qt.RightToLeft
                Chip {
                    u: root.u; fg: root.cText; armedColor: root.cError
                    iconFont: root.fontIcon; textFont: root.fontSans
                    visible: !root.hasSddm || sddm.canPowerOff !== false
                    icon: root.icPower
                    armed: powerIsland.armedAction === "poweroff"
                    label: armed ? "Shut down?" : "Shut down"
                    onClicked: powerIsland.act("poweroff", function () { if (root.hasSddm) sddm.powerOff() })
                }
                Chip {
                    u: root.u; fg: root.cText; armedColor: root.cAccent2
                    iconFont: root.fontIcon; textFont: root.fontSans
                    visible: !root.hasSddm || sddm.canReboot !== false
                    icon: root.icReboot
                    armed: powerIsland.armedAction === "reboot"
                    label: armed ? "Restart?" : "Restart"
                    onClicked: powerIsland.act("reboot", function () { if (root.hasSddm) sddm.reboot() })
                }
                Chip {
                    u: root.u; fg: root.cText
                    iconFont: root.fontIcon; textFont: root.fontSans
                    visible: !root.hasSddm || sddm.canSuspend !== false
                    icon: root.icSleep
                    label: "Sleep"
                    onClicked: powerIsland.act("suspend", function () { if (root.hasSddm) sddm.suspend() })
                }
            }
        }

        // ------------------------------------------------------------ top-right: host
        Text {
            anchors.right: parent.right
            anchors.rightMargin: root.px(36)
            y: root.px(30)
            font.family: root.fontSans
            font.pixelSize: root.px(14)
            font.weight: Font.DemiBold
            font.letterSpacing: root.px(1.5)
            color: root.cText
            opacity: 0.55 * root.t
            visible: opacity > 0.01
            text: root.hasSddm && sddm.hostName ? String(sddm.hostName).toUpperCase() : ""
        }
    }

    // ================================================================ intro / outro
    ParallelAnimation {
        id: intro
        NumberAnimation { target: content; property: "opacity"; from: 0; to: 1; duration: 900; easing.type: Easing.OutCubic }
        NumberAnimation { target: bgLayer; property: "zoom"; from: 1.08; to: 1.0; duration: 1600; easing.type: Easing.OutQuint }
    }
    Rectangle {
        id: blackout
        anchors.fill: parent
        color: "black"
        opacity: 0
        visible: opacity > 0
    }
    ParallelAnimation {
        id: outro
        NumberAnimation { target: blackout; property: "opacity"; to: 1; duration: 500; easing.type: Easing.OutCubic }
        NumberAnimation { target: content; property: "scale"; to: 1.04; duration: 500; easing.type: Easing.OutCubic }
    }
}
