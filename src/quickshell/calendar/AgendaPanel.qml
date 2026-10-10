import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../bar"

// Liquid-glass agenda popout under the bar clock: today + the next 7 days of
// Google Calendar events and Obsidian tasks, today's daily note and quick capture.
// Opened by clicking the bar clock, Mod+C, or a day on the desktop calendar.
PanelWindow {
    id: win

    color: "transparent"
    visible: shown
    property bool shown: false

    anchors { top: true; left: true; right: true; bottom: true }
    exclusiveZone: 0                      // stay below the bar (respects its exclusive zone)
    WlrLayershell.namespace: "qs-agenda"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !Gcal.passive && Gcal.panelOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region { item: Gcal.passive ? card : catcher }
    BackgroundEffect.blurRegion: Region {
        x: Math.round(card.x)
        y: Math.round(card.y)
        width: Math.round(card.width)
        height: Math.round(card.height)
        radius: card.radius
        // the event editor card may reach below a short agenda card
        regions: [
            Region {
                x: Math.round(editor.x)
                y: Math.round(editor.y)
                width: editor.visible ? Math.round(editor.width) : 0
                height: editor.visible ? Math.round(editor.height) : 0
                radius: 22
            }
        ]
    }

    // ── open / close animation ──────────────────────────────────────────
    property real t: 0
    Connections {
        target: Gcal
        function onPanelOpenChanged() {
            if (Gcal.panelOpen) {
                win.shown = true;
                closeAnim.stop();
                openAnim.restart();
                flick.contentY = 0;
                if (!content.focusInput) content.forceActiveFocus();
            } else {
                openAnim.stop();
                closeAnim.restart();
                capBox.input.text = "";
            }
        }
        function onPanelOpenSerialChanged() { flick.contentY = 0; }
        function onEdited(ok, message) {
            if (!win.shown || !ok) return;
            toast.text = message;
            toast.ok = ok;
            toastTimer.restart();
        }
        function onEditorOpenChanged() {
            if (Gcal.editorOpen) { edCloseAnim.stop(); edOpenAnim.restart(); editor.forceActiveFocus(); }
            else { edOpenAnim.stop(); edCloseAnim.restart(); content.forceActiveFocus(); }
        }
        function onCaptured(ok, message) {
            if (!win.shown) return;
            toast.text = message;
            toast.ok = ok;
            toastTimer.restart();
            if (ok) capBox.input.text = "";
        }
    }
    NumberAnimation { id: openAnim; target: win; property: "t"; to: 1; duration: 520; easing.type: Easing.OutQuint }
    SequentialAnimation {
        id: closeAnim
        NumberAnimation { target: win; property: "t"; to: 0; duration: 220; easing.type: Easing.InCubic }
        ScriptAction { script: win.shown = false }
    }

    // click outside the card closes
    MouseArea {
        id: catcher
        anchors.fill: parent
        onClicked: Gcal.close()
    }

    readonly property real fs: 13.5          // base font size of rows
    readonly property real pad: 18
    readonly property var weekKeys: {
        let k = Gcal.todayKey, out = [];
        for (let i = 0; i < 8; i++) out.push(Gcal.shiftKey(k, i));
        return out;
    }
    readonly property bool singleDay: Gcal.focusDay !== "" && weekKeys.indexOf(Gcal.focusDay) < 0
    readonly property var listKeys: singleDay ? [Gcal.focusDay] : weekKeys
    readonly property bool monthMode: Gcal.view === "month"
    // content is laid out at the target width while the glass card animates towards it
    readonly property real targetW: monthMode ? Math.min(1120, win.width - 40) : 468

    Item {
        id: card
        width: win.targetW
        // grows to hold the event editor while it is open (one even glass layer under it)
        height: Math.min(Math.max(content.implicitHeight, win.edT > 0 ? editor.height + 64 + 18 : 0), win.height - 24)
        Behavior on width { enabled: win.shown && !openAnim.running; NumberAnimation { duration: 560; easing.type: Easing.OutQuint } }
        Behavior on height { enabled: win.shown && !openAnim.running; NumberAnimation { duration: 560; easing.type: Easing.OutQuint } }
        x: Math.round((win.width - width) / 2)
        y: Math.round(10 - (1 - win.t) * 16)
        readonly property real radius: 22
        opacity: win.t
        scale: 0.97 + 0.03 * win.t
        transformOrigin: Item.Top

        GlassPill {
            anchors.fill: parent
            radius: card.radius
            tintAlpha: 0.62
            lit: true
        }
        // swallow clicks on the card itself
        MouseArea { anchors.fill: parent; onClicked: {} }

        FocusScope {
            id: content
            anchors.fill: parent
            focus: true
            clip: true
            property bool focusInput: false
            implicitHeight: col.implicitHeight + win.pad * 2
            Keys.onEscapePressed: Gcal.close()
            Keys.onPressed: event => {
                if (!capBox.input.activeFocus) {
                    if (event.key === Qt.Key_Tab) { Gcal.setView(win.monthMode ? "week" : "month"); event.accepted = true; return; }
                    if (win.monthMode) {
                        let k = event.key;
                        if (k === Qt.Key_Left || k === Qt.Key_PageUp) { Gcal.shiftMonth(-1); event.accepted = true; return; }
                        if (k === Qt.Key_Right || k === Qt.Key_PageDown) { Gcal.shiftMonth(1); event.accepted = true; return; }
                        if (k === Qt.Key_Home) { Gcal.goToday(); event.accepted = true; return; }
                    }
                }
                // typing anywhere starts a quick capture
                if (!capBox.input.activeFocus && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                    capBox.input.forceActiveFocus();
                    capBox.input.text += event.text;
                    event.accepted = true;
                }
            }

            Column {
                id: col
                x: Math.round((card.width - win.targetW) / 2) + win.pad
                y: win.pad
                width: win.targetW - win.pad * 2
                // soft crossfade when switching 8 days <-> Month; fades back while the event editor is open
                opacity: win.viewFade * (1 - 0.96 * win.edT)
                transform: Translate { y: (1 - win.viewFade) * 6 }
                spacing: 14

                // ── header ───────────────────────────────────────────
                Item {
                    width: parent.width
                    height: headCol.implicitHeight

                    Column {
                        id: headCol
                        spacing: 1
                        Text {
                            text: Qt.locale().dayName(Gcal.dateOf(Gcal.todayKey).getDay(), Locale.LongFormat)
                            color: ThemeBackend.text
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: 26
                            font.weight: Font.Black
                        }
                        Text {
                            text: {
                                let d = Gcal.dateOf(Gcal.todayKey);
                                return Qt.locale().standaloneMonthName(d.getMonth(), Locale.LongFormat) + " " + d.getDate() + "  ·  " + Qt.formatTime(DateTime.now, DateTime.is12Hour ? "h:mm AP" : "HH:mm");
                            }
                            color: ThemeBackend.subtext0
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 2
                        spacing: 6
                        ViewToggle { anchors.verticalCenter: parent.verticalCenter }
                        Item { width: 4; height: 1 }
                        IconButton {
                            glyph: 0xF0415
                            tip: "New event"
                            onClicked: Gcal.newEvent(win.monthMode ? Gcal.selectedDay : (Gcal.focusDay || Gcal.todayKey))
                        }
                        IconButton {
                            glyph: 0xF0450
                            tip: "Sync now"
                            spinning: Gcal.syncing
                            onClicked: Gcal.refresh(true)
                        }
                        IconButton {
                            glyph: 0xF02AD
                            tip: "Open Google Calendar"
                            onClicked: Gcal.openGoogleDay(win.monthMode ? Gcal.selectedDay : (Gcal.focusDay || Gcal.todayKey))
                        }
                    }
                }

                // ── 8-day strip ──────────────────────────────────────
                Row {
                    id: strip
                    visible: !win.monthMode
                    width: parent.width
                    spacing: 5
                    readonly property real chipW: (width - spacing * 7) / 8
                    Repeater {
                        model: win.weekKeys
                        delegate: Rectangle {
                            id: chip
                            required property string modelData
                            required property int index
                            readonly property bool isToday: modelData === Gcal.todayKey
                            readonly property var info: Gcal.dayInfo(modelData)
                            readonly property bool active: win.highlightKey === modelData
                            width: strip.chipW
                            height: 62
                            radius: 14
                            color: isToday ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, chipMa.containsMouse ? 0.42 : 0.32)
                                 : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, chipMa.containsMouse ? 0.13 : (active ? 0.10 : 0.05))
                            border.width: active && !isToday ? 1 : 0
                            border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.22)
                            Behavior on color { ColorAnimation { duration: 180 } }
                            scale: chipMa.pressed ? 0.94 : 1
                            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }

                            // staggered rise on open
                            opacity: Math.max(0, Math.min(1, win.t * 1.6 - index * 0.07))
                            transform: Translate { y: (1 - chip.opacity) * 8 }

                            Column {
                                anchors.centerIn: parent
                                anchors.verticalCenterOffset: -3
                                spacing: 1
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: Qt.locale().dayName(Gcal.dateOf(chip.modelData).getDay(), Locale.ShortFormat).substring(0, 2)
                                    color: chip.isToday ? ThemeBackend.mauve : ((Gcal.dateOf(chip.modelData).getDay() % 6 === 0) ? ThemeBackend.peach : ThemeBackend.subtext0)
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: Gcal.dateOf(chip.modelData).getDate()
                                    color: ThemeBackend.text
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: 18
                                    font.weight: Font.Black
                                    font.features: { "tnum": 1 }
                                }
                            }
                            DayDots {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 7
                                info: chip.info
                                dot: 5
                            }
                            MouseArea {
                                id: chipMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: win.scrollToDay(chip.modelData)
                            }
                        }
                    }
                }

                // ── single-day header (day picked on the desktop calendar) ──
                Rectangle {
                    visible: win.singleDay && !win.monthMode
                    width: backRow.implicitWidth + 22
                    height: 30
                    radius: 15
                    color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, backMa.containsMouse ? 0.14 : 0.07)
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Row {
                        id: backRow
                        anchors.centerIn: parent
                        spacing: 6
                        Text { text: String.fromCodePoint(0xF004D); color: ThemeBackend.subtext1; font.family: ThemeBackend.iconFont; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: "This week"; color: ThemeBackend.subtext1; font.family: ThemeBackend.fontFamily; font.pixelSize: 12; font.weight: Font.Bold; anchors.verticalCenter: parent.verticalCenter }
                    }
                    MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.focusDay = "" }
                }

                // ── agenda list ──────────────────────────────────────
                Flickable {
                    id: flick
                    visible: !win.monthMode
                    width: parent.width
                    height: Math.min(days.implicitHeight, Math.max(160, win.height * 0.86 - 330))
                    contentHeight: days.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Behavior on contentY { enabled: win.animateScroll; NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

                    Column {
                        id: days
                        width: flick.width
                        spacing: 12
                        Repeater {
                            id: dayRep
                            model: win.listKeys
                            delegate: AgendaDay {
                                required property string modelData
                                required property int index
                                width: days.width
                                dayKey: modelData
                                fontPx: win.fs
                                highlighted: win.highlightKey === modelData
                                opacity: Math.max(0, Math.min(1, win.t * 1.5 - 0.15 - index * 0.06))
                            }
                        }
                    }
                }

                // ── month view (created the first time it is shown) ──
                Loader {
                    id: monthLoader
                    width: parent.width
                    visible: win.monthMode && status === Loader.Ready
                    active: Gcal.monthEverShown
                    asynchronous: true
                    source: "AgendaMonth.qml"
                    height: visible && item ? item.implicitHeight : 0
                    onLoaded: item.width = Qt.binding(() => monthLoader.width)
                    Connections {
                        target: monthLoader.item
                        ignoreUnknownSignals: true
                        function onAddRequested(key) { capBox.input.forceActiveFocus(); }
                    }
                }

                // ── footer: quick capture + today's note ─────────────
                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.09) }

                Row {
                    width: parent.width
                    spacing: 8

                    CaptureBox {
                        id: capBox
                        width: parent.width - noteBtn.width - parent.spacing
                        fs: 14
                        onEscaped: Gcal.close()
                        Connections {
                            target: capBox.input
                            function onActiveFocusChanged() { content.focusInput = capBox.input.activeFocus; }
                        }
                    }

                    Rectangle {
                        id: noteBtn
                        width: noteRow.implicitWidth + 26
                        height: 40
                        radius: 20
                        color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, noteMa.containsMouse ? 0.34 : 0.2)
                        Behavior on color { ColorAnimation { duration: 180 } }
                        scale: noteMa.pressed ? 0.95 : 1
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                        Row {
                            id: noteRow
                            anchors.centerIn: parent
                            spacing: 7
                            Text {
                                text: String.fromCodePoint(Gcal.obsidian.todayExists ? 0xF0EBF : 0xF1612)
                                color: ThemeBackend.mauve
                                font.family: ThemeBackend.iconFont
                                font.pixelSize: 17
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Today's note"
                                color: ThemeBackend.text
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: 13
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea { id: noteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.openDaily(Gcal.todayKey) }
                    }
                }

                // ── status line ──────────────────────────────────────
                Item {
                    width: parent.width
                    height: 16
                    Text {
                        id: toast
                        property bool ok: true
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: connect.visible ? connect.left : parent.right
                        anchors.rightMargin: connect.visible ? 10 : 0
                        text: ""
                        visible: toastTimer.running
                        color: ok ? ThemeBackend.green : ThemeBackend.red
                        elide: Text.ElideRight
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Bold
                    }
                    Timer { id: toastTimer; interval: 2600 }
                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: connect.visible ? connect.left : parent.right
                        anchors.rightMargin: connect.visible ? 10 : 0
                        visible: !toastTimer.running
                        text: Gcal.syncStatus
                        color: Gcal.syncError ? ThemeBackend.red : ThemeBackend.subtext0
                        opacity: Gcal.syncError ? 0.95 : 0.7
                        elide: Text.ElideRight
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 12
                    }
                    Text {
                        id: connect
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Gcal.loaded && (!Gcal.configured || Gcal.syncError)
                        text: Gcal.configured ? "Fix calendars…" : "Connect Google Calendar…"
                        color: connMa.containsMouse ? ThemeBackend.text : ThemeBackend.mauve
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Bold
                        MouseArea { id: connMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.runSetup() }
                    }
                }
            }
        }
    }

    // ── event details / editor over the card ────────────────────────────
    property real edT: 0
    NumberAnimation { id: edOpenAnim; target: win; property: "edT"; to: 1; duration: 460; easing.type: Easing.OutQuint }
    NumberAnimation { id: edCloseAnim; target: win; property: "edT"; to: 0; duration: 200; easing.type: Easing.InCubic }
    Rectangle {
        // dims the agenda behind the editor; a click here closes the editor
        x: card.x
        y: card.y
        width: card.width
        height: card.height
        radius: card.radius
        visible: win.edT > 0
        color: Qt.rgba(0, 0, 0, 0.12 * win.edT)
        MouseArea { anchors.fill: parent; enabled: Gcal.editorOpen; onClicked: Gcal.closeEditor() }
    }
    EventEditor {
        id: editor
        visible: win.edT > 0
        x: Math.round(card.x + (card.width - width) / 2)
        y: Math.round(Math.max(card.y + 10, Math.min(card.y + 64, win.height - height - 16)) - (1 - win.edT) * 14)
        opacity: win.edT
        scale: 0.96 + 0.04 * win.edT
        transformOrigin: Item.Top
    }

    // ── 8 days <-> Month crossfade ──────────────────────────────────────
    property real viewFade: 1
    Connections {
        target: Gcal
        function onViewChanged() { if (win.shown) { viewFadeAnim.stop(); win.viewFade = 0; viewFadeAnim.start(); } }
    }
    NumberAnimation { id: viewFadeAnim; target: win; property: "viewFade"; to: 1; duration: 420; easing.type: Easing.OutCubic }

    // segmented "8 days | Month" switch in the header
    component ViewToggle: Rectangle {
        id: tog
        readonly property real segW: 74
        width: segW * 2 + 6
        height: 34
        radius: 17
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.07)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.06)
        Rectangle {
            x: 3 + (win.monthMode ? tog.segW : 0)
            y: 3
            width: tog.segW
            height: tog.height - 6
            radius: height / 2
            color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.28)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
        }
        Row {
            x: 3
            y: 3
            Repeater {
                model: [{ v: "week", label: "8 days" }, { v: "month", label: "Month" }]
                delegate: Item {
                    required property var modelData
                    readonly property bool on: Gcal.view === modelData.v
                    width: tog.segW
                    height: tog.height - 6
                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: parent.on ? ThemeBackend.text : (segMa.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0)
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        Behavior on color { ColorAnimation { duration: 160 } }
                    }
                    MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.setView(modelData.v) }
                }
            }
        }
    }

    // ── scrolling to a day ──────────────────────────────────────────────
    property string highlightKey: ""
    property bool animateScroll: false
    function scrollToDay(key) {
        if (win.singleDay) Gcal.focusDay = "";
        highlightKey = key;
        hlTimer.restart();
        let idx = win.listKeys.indexOf(key);
        let it = idx >= 0 ? dayRep.itemAt(idx) : null;
        if (!it) return;
        animateScroll = true;
        flick.contentY = Math.max(0, Math.min(it.y, flick.contentHeight - flick.height));
        scrollAnimOff.restart();
    }
    Timer { id: scrollAnimOff; interval: 450; onTriggered: win.animateScroll = false }
    Timer { id: hlTimer; interval: 1600; onTriggered: win.highlightKey = "" }

    // jump to a focused day from the desktop calendar
    Connections {
        target: Gcal
        function onFocusDayChanged() { focusJump.restart(); }
        function onPanelOpenSerialChanged() { focusJump.restart(); }
    }
    // wait for the day sections to lay out before measuring where to scroll
    Timer {
        id: focusJump
        interval: 180
        onTriggered: if (Gcal.focusDay !== "" && win.weekKeys.indexOf(Gcal.focusDay) >= 0) win.scrollToDay(Gcal.focusDay)
    }

    // small round icon button used in the header
    component IconButton: Rectangle {
        id: btn
        property int glyph: 0
        property string tip: ""
        property bool spinning: false
        signal clicked()
        width: 34
        height: 34
        radius: 17
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, bMa.containsMouse ? 0.15 : 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: bMa.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
        Text {
            id: glyphText
            anchors.centerIn: parent
            text: String.fromCodePoint(btn.glyph)
            color: bMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext1
            font.family: ThemeBackend.iconFont
            font.pixelSize: 17
            RotationAnimator on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: btn.spinning }
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: btn.clicked() }
    }
}
