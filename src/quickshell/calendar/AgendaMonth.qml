import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Month view of the agenda panel (loaded lazily the first time it is shown):
// a 6×7 grid with colored event chips and Obsidian tasks per day, and a detail
// list for the selected day. Wheel / ←→ / PgUp PgDn change the month.
// Months inside events.json's window use Gcal's data directly; others are
// fetched once from the cached feeds with `gcal-sync range FROM TO`.
Item {
    id: mv

    property real gap: 4
    property real sideW: 336
    property real cellH: 92
    readonly property int weekStart: 1               // Monday
    signal addRequested(string key)                  // "+" on a cell / detail pane

    readonly property real gridW: width - sideW - 18
    readonly property real cellW: (gridW - gap * 6) / 7
    implicitHeight: gridCol.implicitHeight

    // ── model ───────────────────────────────────────────────────────────
    readonly property string monthKey: Gcal.monthKey
    readonly property date monthDate: { let p = monthKey.split("-"); return new Date(+p[0], +p[1] - 1, 1); }
    readonly property var cellKeys: {
        let first = monthDate;
        let lead = (first.getDay() - weekStart + 7) % 7;
        let out = [];
        for (let i = 0; i < 42; i++) out.push(Gcal.keyOf(new Date(first.getFullYear(), first.getMonth(), 1 - lead + i)));
        return out;
    }
    readonly property string fromKey: cellKeys[0]
    readonly property string toKey: cellKeys[41]
    readonly property var docRange: (Gcal.doc && Gcal.doc.range) ? Gcal.doc.range : ["", ""]
    readonly property bool inWindow: Gcal.loaded && fromKey >= docRange[0] && toKey <= docRange[1]

    // cached results of `gcal-sync range` (cleared whenever events.json changes)
    property var ext: ({})
    property int extRev: 0
    Connections {
        target: Gcal
        function onRevisionChanged() { mv.ext = ({}); mv.extRev++; mv.ensureData(); }
        function onPanelOpenChanged() { mv.ensureData(); }
        function onViewChanged() { mv.ensureData(); }
    }
    readonly property var extData: { let r = extRev; return ext[fromKey] || null; }
    readonly property bool loading: !inWindow && extData === null

    onFromKeyChanged: ensureData()
    Component.onCompleted: ensureData()
    function ensureData() {
        // only while the Month view is actually on screen (no background `range` runs)
        if (!Gcal.panelOpen || Gcal.view !== "month") return;
        if (inWindow || ext[fromKey] || !Gcal.loaded) return;
        if (rangeProc.running) { rangeProc.pending = true; return; }
        rangeProc.want = fromKey;
        rangeProc.command = [Gcal.syncBin, "range", fromKey, toKey];
        rangeProc.running = true;
    }
    Process {
        id: rangeProc
        property string want: ""
        property bool pending: false
        stdout: StdioCollector { id: rangeOut }
        onExited: (code, status) => {
            let d = { events: [], tasks: [], daily: {} };
            if (code === 0) { try { d = JSON.parse(rangeOut.text); } catch (e) {} }
            let m = Object.assign({}, mv.ext);
            m[want] = d;
            mv.ext = m;
            mv.extRev++;
            if (pending) { pending = false; mv.ensureData(); }
        }
    }

    // key -> { evs: [], tks: [], note: bool }
    readonly property var buckets: {
        let r = Gcal.revision, x = extRev;
        let src = inWindow ? { events: Gcal.events, tasks: Gcal.tasks, daily: Gcal.dailyNotes } : (extData || { events: [], tasks: [], daily: {} });
        let b = {};
        for (let k of cellKeys) b[k] = { evs: [], tks: [], note: !!(src.daily && src.daily[k]) };
        for (let e of src.events) {
            if (e.endDate < fromKey || e.startDate > toKey) continue;
            let k = e.startDate < fromKey ? fromKey : e.startDate;
            for (let i = 0; i < 60 && k <= e.endDate && k <= toKey; i++) {
                b[k].evs.push(e);
                k = Gcal.shiftKey(k, 1);
            }
        }
        for (let t of src.tasks) if (b[t.due]) b[t.due].tks.push(t);
        for (let k of cellKeys) b[k].evs.sort((a, c) => (a.allDay === c.allDay ? a.startMs - c.startMs : (a.allDay ? -1 : 1)));
        return b;
    }
    readonly property var monthStats: {
        let ev = 0, tk = 0, ids = {};
        for (let k of cellKeys) {
            if (k.substring(0, 7) !== monthKey) continue;
            for (let e of buckets[k].evs) if (!ids[e.id]) { ids[e.id] = 1; ev++; }
            tk += buckets[k].tks.length;
        }
        return { events: ev, tasks: tk };
    }

    // ── month change: slide in from the side we're moving to ───────────
    property string lastMonth: monthKey
    property real slide: 0
    onMonthKeyChanged: {
        let dir = monthKey > lastMonth ? 1 : -1;
        lastMonth = monthKey;
        slideAnim.stop();
        slide = dir;
        slideAnim.start();
    }
    NumberAnimation { id: slideAnim; target: mv; property: "slide"; to: 0; duration: 460; easing.type: Easing.OutQuint }

    // wheel: one notch (or a decent touchpad swipe) = one month
    property real wheelAcc: 0
    Timer { id: wheelCool; interval: 260 }
    function onWheelDelta(dy) {
        if (wheelCool.running) { wheelAcc = 0; return; }
        wheelAcc += dy;
        if (Math.abs(wheelAcc) >= 100) {
            Gcal.shiftMonth(wheelAcc > 0 ? -1 : 1);
            wheelAcc = 0;
            wheelCool.restart();
        }
    }

    function select(key) {
        Gcal.selectedDay = key;
        if (key.substring(0, 7) !== Gcal.monthKey) Gcal.monthKey = key.substring(0, 7);
    }

    Row {
        spacing: 18

        // ── grid column ────────────────────────────────────────────────
        Column {
            id: gridCol
            width: mv.gridW
            spacing: 10

            // month title + navigation
            Item {
                width: parent.width
                height: 36
                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.locale().standaloneMonthName(mv.monthDate.getMonth(), Locale.LongFormat)
                        color: ThemeBackend.text
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 22
                        font.weight: Font.Black
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: mv.monthDate.getFullYear()
                        color: ThemeBackend.subtext0
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 22
                        font.weight: Font.Bold
                        opacity: 0.75
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: 2
                        leftPadding: 4
                        text: mv.loading ? "loading…"
                              : (mv.monthStats.events + mv.monthStats.tasks === 0 ? "nothing planned"
                              : [mv.monthStats.events ? mv.monthStats.events + (mv.monthStats.events === 1 ? " event" : " events") : "",
                                 mv.monthStats.tasks ? mv.monthStats.tasks + (mv.monthStats.tasks === 1 ? " task" : " tasks") : ""].filter(s => s).join(" · "))
                        color: ThemeBackend.subtext0
                        opacity: 0.6
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Bold
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Rectangle {
                        id: todayBtn
                        readonly property bool atToday: Gcal.monthKey === Gcal.todayKey.substring(0, 7) && Gcal.selectedDay === Gcal.todayKey
                        width: todayTxt.implicitWidth + 26
                        height: 32
                        radius: 16
                        color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, tMa.containsMouse ? 0.32 : (atToday ? 0.08 : 0.18))
                        Behavior on color { ColorAnimation { duration: 180 } }
                        scale: tMa.pressed ? 0.94 : 1
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                        Text {
                            id: todayTxt
                            anchors.centerIn: parent
                            text: "Today"
                            color: todayBtn.atToday ? ThemeBackend.subtext0 : ThemeBackend.mauve
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: 13
                            font.weight: Font.Bold
                        }
                        MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.goToday() }
                    }
                    NavButton { glyph: 0xF0141; onClicked: Gcal.shiftMonth(-1) }   // chevron-left
                    NavButton { glyph: 0xF0142; onClicked: Gcal.shiftMonth(1) }    // chevron-right
                }
            }

            // weekday names
            Row {
                spacing: mv.gap
                Repeater {
                    model: 7
                    delegate: Text {
                        required property int index
                        readonly property int dow: (mv.weekStart + index) % 7
                        width: mv.cellW
                        leftPadding: 8
                        text: Qt.locale().dayName(dow, Locale.ShortFormat).toUpperCase()
                        color: dow === 0 || dow === 6 ? ThemeBackend.peach : ThemeBackend.subtext0
                        opacity: dow === 0 || dow === 6 ? 0.85 : 0.7
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 11
                        font.weight: Font.Black
                        font.letterSpacing: 1
                    }
                }
            }

            // the grid
            Item {
                id: gridBox
                width: parent.width
                height: mv.cellH * 6 + mv.gap * 5
                clip: true

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: wheel => mv.onWheelDelta(wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : -wheel.angleDelta.x)
                }

                Grid {
                    id: grid
                    columns: 7
                    spacing: mv.gap
                    x: mv.slide * 34
                    opacity: 1 - Math.abs(mv.slide) * 0.85
                    Repeater {
                        model: mv.cellKeys
                        delegate: DayCell {}
                    }
                }
            }
        }

        // ── selected day ───────────────────────────────────────────────
        Item {
            id: side
            width: mv.sideW
            height: gridCol.height

            Rectangle {
                anchors.fill: parent
                radius: 18
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.045)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)
            }

            Column {
                id: sideHead
                x: 16
                y: 14
                width: parent.width - 32
                spacing: 0
                Text {
                    text: {
                        let d = Gcal.dateOf(Gcal.selectedDay);
                        return Qt.locale().dayName(d.getDay(), Locale.LongFormat);
                    }
                    color: Gcal.selectedDay === Gcal.todayKey ? ThemeBackend.mauve : ThemeBackend.text
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 19
                    font.weight: Font.Black
                }
                Text {
                    text: {
                        let d = Gcal.dateOf(Gcal.selectedDay);
                        let rel = Gcal.selectedDay === Gcal.todayKey ? "Today" : (Gcal.selectedDay === Gcal.tomorrowKey ? "Tomorrow"
                                  : (Gcal.selectedDay === Gcal.shiftKey(Gcal.todayKey, -1) ? "Yesterday" : ""));
                        if (!rel) {
                            let n = Math.round((d - Gcal.dateOf(Gcal.todayKey)) / 86400000);
                            rel = n > 0 ? "in " + n + " days" : -n + " days ago";
                        }
                        return Qt.locale().standaloneMonthName(d.getMonth(), Locale.LongFormat) + " " + d.getDate()
                               + (d.getFullYear() !== Gcal.dateOf(Gcal.todayKey).getFullYear() ? ", " + d.getFullYear() : "") + "  ·  " + rel;
                    }
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
            }

            Flickable {
                id: sideFlick
                x: 16
                anchors.top: sideHead.bottom
                anchors.topMargin: 6
                anchors.bottom: addBtn.top
                anchors.bottomMargin: 10
                width: parent.width - 32
                contentHeight: dayView.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                AgendaDay {
                    id: dayView
                    width: sideFlick.width
                    dayKey: Gcal.selectedDay
                    fontPx: 13
                    readonly property var bucket: mv.buckets[Gcal.selectedDay] || null
                    readonly property bool own: !mv.inWindow && bucket !== null
                    evsOverride: own ? bucket.evs : null
                    tksOverride: own ? bucket.tks : null
                    noteOverride: own ? bucket.note : null
                    labelOverride: {
                        let ne = evs.length, nt = tks.length;
                        if (ne + nt === 0) return "Schedule";
                        return [ne ? ne + (ne === 1 ? " event" : " events") : "", nt ? nt + (nt === 1 ? " task" : " tasks") : ""].filter(s => s).join(" · ");
                    }
                    opacity: 1 - Math.abs(mv.slide) * 0.6
                }
            }

            // quick add on the selected day (uses the panel's capture box)
            Rectangle {
                id: addBtn
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 12
                x: 12
                width: parent.width - 24
                height: 36
                radius: 18
                color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, aMa.containsMouse ? 0.30 : 0.15)
                Behavior on color { ColorAnimation { duration: 180 } }
                scale: aMa.pressed ? 0.96 : 1
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                Row {
                    anchors.centerIn: parent
                    spacing: 7
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xF0415)
                        color: ThemeBackend.mauve
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: 16
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            let d = Gcal.dateOf(Gcal.selectedDay);
                            return "Add to " + (Gcal.selectedDay === Gcal.todayKey ? "today" : (Gcal.selectedDay === Gcal.tomorrowKey ? "tomorrow"
                                   : Qt.locale().monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate()));
                        }
                        color: ThemeBackend.text
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 13
                        font.weight: Font.Bold
                    }
                }
                MouseArea { id: aMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: mv.addRequested(Gcal.selectedDay) }
            }
        }
    }

    // ── one day cell ────────────────────────────────────────────────────
    component DayCell: Item {
        id: cell
        required property string modelData
        required property int index
        readonly property string key: modelData
        readonly property date d: Gcal.dateOf(key)
        readonly property bool inMonth: key.substring(0, 7) === mv.monthKey
        readonly property bool isToday: key === Gcal.todayKey
        readonly property bool isPast: key < Gcal.todayKey
        readonly property bool weekend: d.getDay() === 0 || d.getDay() === 6
        readonly property bool selected: key === Gcal.selectedDay
        readonly property var bucket: mv.buckets[key] || ({ evs: [], tks: [], note: false })
        readonly property var items: {
            let out = [];
            for (let e of bucket.evs) out.push({ ev: e });
            for (let t of bucket.tks) out.push({ task: t });
            return out;
        }
        readonly property int maxChips: Math.max(1, Math.floor((mv.cellH - 30) / 18))
        readonly property int shown: items.length > maxChips ? maxChips - 1 : items.length
        width: mv.cellW
        height: mv.cellH

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: cell.selected ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, cMa.containsMouse ? 0.17 : 0.12)
                 : cell.weekend ? Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, cMa.containsMouse ? 0.09 : (cell.inMonth ? 0.045 : 0.02))
                 : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, cMa.containsMouse ? 0.10 : (cell.inMonth ? 0.05 : 0.02))
            border.width: cell.selected ? 1 : 0
            border.color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.55)
            Behavior on color { ColorAnimation { duration: 160 } }
        }

        MouseArea {
            id: cMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mv.select(cell.key)
            onDoubleClicked: { mv.select(cell.key); mv.addRequested(cell.key); }
        }

        Item {
            anchors.fill: parent
            opacity: cell.inMonth ? 1 : 0.4

            // day number (today: filled disc)
            Rectangle {
                id: num
                x: 5
                y: 5
                width: Math.max(22, numTxt.implicitWidth + 10)
                height: 22
                radius: 11
                color: cell.isToday ? ThemeBackend.mauve : "transparent"
                Text {
                    id: numTxt
                    anchors.centerIn: parent
                    text: cell.d.getDate()
                    color: cell.isToday ? ThemeBackend.base : (cell.weekend ? ThemeBackend.peach : ThemeBackend.text)
                    opacity: cell.isToday ? 1 : (cell.isPast ? 0.55 : 0.92)
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 13
                    font.weight: cell.isToday ? Font.Black : Font.Bold
                    font.features: { "tnum": 1 }
                }
            }
            // first of a month: show the month name next to the number
            Text {
                visible: cell.d.getDate() === 1
                anchors.left: num.right
                anchors.verticalCenter: num.verticalCenter
                text: Qt.locale().monthName(cell.d.getMonth(), Locale.ShortFormat)
                color: ThemeBackend.subtext0
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 11
                font.weight: Font.Bold
            }
            // daily note exists
            Text {
                visible: cell.bucket.note && !addHint.visible
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: num.verticalCenter
                text: String.fromCodePoint(0xF0EBF)
                color: ThemeBackend.mauve
                opacity: 0.75
                font.family: ThemeBackend.iconFont
                font.pixelSize: 12
            }
            // hover "+" → quick add on this day
            Rectangle {
                id: addHint
                visible: cMa.containsMouse || plusMa.containsMouse
                anchors.right: parent.right
                anchors.rightMargin: 4
                y: 5
                width: 22
                height: 22
                radius: 11
                color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, plusMa.containsMouse ? 0.4 : 0.18)
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(0xF0415)
                    color: ThemeBackend.mauve
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: 14
                }
                MouseArea { id: plusMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { mv.select(cell.key); mv.addRequested(cell.key); } }
            }

            Column {
                x: 4
                y: 31
                width: parent.width - 8
                spacing: 2
                Repeater {
                    model: cell.items.slice(0, cell.shown)
                    delegate: Chip {
                        required property var modelData
                        width: parent.width
                        ev: modelData.ev || null
                        task: modelData.task || null
                        dayKey: cell.key
                    }
                }
                Text {
                    visible: cell.items.length > cell.shown
                    leftPadding: 5
                    height: 16
                    verticalAlignment: Text.AlignVCenter
                    text: "+" + (cell.items.length - cell.shown) + " more"
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 11
                    font.weight: Font.Bold
                }
            }
        }
    }

    // ── an event / task chip inside a cell ──────────────────────────────
    component Chip: Item {
        id: chip
        property var ev: null
        property var task: null
        property string dayKey: ""
        readonly property bool isTask: task !== null
        readonly property color accent: isTask ? (task.overdue ? ThemeBackend.red : ThemeBackend.green) : Gcal.colorFor(ev ? ev.color : "")
        readonly property bool solid: !isTask && ev && (ev.allDay || ev.startDate !== ev.endDate)
        readonly property bool ended: !isTask && ev && Gcal.isPast(ev)
        height: 16
        opacity: ended ? 0.55 : 1

        Rectangle {
            anchors.fill: parent
            radius: 5
            color: Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, chip.solid ? 0.38 : 0.15)
        }
        Rectangle {
            visible: !chip.solid && !chip.isTask
            x: 0
            width: 3
            height: parent.height
            radius: 1.5
            color: chip.accent
        }
        Text {
            id: tg
            visible: chip.isTask
            x: 3
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(chip.isTask && chip.task.inProgress ? 0xF0134 : 0xF0130)
            color: chip.accent
            font.family: ThemeBackend.iconFont
            font.pixelSize: 11
        }
        Text {
            anchors.left: chip.isTask ? tg.right : parent.left
            anchors.leftMargin: chip.isTask ? 2 : (chip.solid ? 6 : 7)
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
                if (chip.isTask) return (chip.task.time ? chip.task.time + " " : "") + chip.task.text;
                let e = chip.ev;
                if (e.allDay || (e.startDate !== e.endDate && chip.dayKey !== e.startDate)) return e.title;
                return Gcal.fmtTime(e.startMs) + " " + e.title;
            }
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
    }

    component NavButton: Rectangle {
        id: nb
        property int glyph: 0
        signal clicked()
        width: 32
        height: 32
        radius: 16
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, nMa.containsMouse ? 0.15 : 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: nMa.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
        Text {
            anchors.centerIn: parent
            text: String.fromCodePoint(nb.glyph)
            color: nMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext1
            font.family: ThemeBackend.iconFont
            font.pixelSize: 18
        }
        MouseArea { id: nMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: nb.clicked() }
    }
}
