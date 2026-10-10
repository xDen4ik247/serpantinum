import QtQuick
import "../"
import "../bar"
import "RepeatRules.js" as Rep

// Liquid-glass event card shown over the agenda (Google-Calendar-like):
//  - view mode: title, when, repeat rule, place, reminders, calendar; Edit / Delete / Open in Google
//  - edit mode: title, all-day, date + start/end, Repeat menu (Does not repeat / Daily / Weekly on … /
//    Monthly on day N / on the Nth weekday / Annually / Every weekday / Custom: interval, days,
//    ends never / on date / after N), place, reminders; Save / Cancel / Delete
//  - repeating events ask "This event / This and following events / All events" on save and delete.
// All state lives in the Gcal singleton (editorItem, editorMode, scopeAsk …); this file only draws it.
FocusScope {
    id: ed

    readonly property var it: Gcal.editorItem
    readonly property var ev: Gcal.editorEv
    readonly property bool editing: Gcal.editorMode === "edit"
    readonly property color accent: ev ? Gcal.colorFor(ev.color) : ThemeBackend.mauve
    readonly property real pad: 20
    property bool reminderMenu: false

    width: 520
    implicitHeight: body.implicitHeight + pad * 2
    height: implicitHeight
    Behavior on height { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }

    Connections {
        target: Gcal
        function onEditorOpenChanged() { if (!Gcal.editorOpen) { Gcal.editorRepeatMenu = false; Gcal.editorCustom = false; ed.reminderMenu = false; } }
        function onEditorModeChanged() {
            Gcal.editorRepeatMenu = false; ed.reminderMenu = false;
            if (ed.editing && ed.it && !ed.it.title) titleIn.forceActiveFocus();
        }
    }

    Keys.onEscapePressed: {
        if (Gcal.editorRepeatMenu || reminderMenu) { Gcal.editorRepeatMenu = false; reminderMenu = false; }
        else if (Gcal.scopeAsk !== "") Gcal.scopeAsk = "";
        else if (editing && ev) { Gcal.editorItem = JSON.parse(JSON.stringify(Gcal.editorOrig || Gcal.editorItem)); Gcal.editorMode = "view"; }
        else Gcal.closeEditor();
    }
    Keys.onPressed: event => {
        if (editing && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
            Gcal.saveEditor(); event.accepted = true;
        } else if (!editing && event.key === Qt.Key_E && ev && Gcal.editorEditable) {
            Gcal.startEditing(); event.accepted = true;
        } else if (!editing && event.key === Qt.Key_Delete && ev && Gcal.editorEditable) {
            Gcal.deleteEditor(); event.accepted = true;
        }
    }

    GlassPill {
        anchors.fill: parent
        radius: 22
        tintAlpha: 0.74
        lit: true
    }
    MouseArea { anchors.fill: parent; onClicked: { Gcal.editorRepeatMenu = false; ed.reminderMenu = false; ed.forceActiveFocus(); } }

    // ── helpers ──────────────────────────────────────────────────────────
    function pad2(n) { return ("0" + n).slice(-2); }
    function minutesOf(t) { if (!t) return 0; let p = t.split(":"); return (+p[0]) * 60 + (+p[1]); }
    function hhmm(m) { m = ((m % 1440) + 1440) % 1440; return pad2(Math.floor(m / 60)) + ":" + pad2(m % 60); }
    function showTime(t) {
        if (!t) return "";
        if (!DateTime.is12Hour) return t;
        let m = minutesOf(t), h = Math.floor(m / 60) % 12 || 12;
        return h + ":" + pad2(m % 60) + (m >= 720 ? " PM" : " AM");
    }
    function longDate(key) {
        let d = Gcal.dateOf(key);
        return Qt.locale().dayName(d.getDay(), Locale.LongFormat) + ", " + Qt.locale().monthName(d.getMonth(), Locale.LongFormat) + " " + d.getDate();
    }
    function shortDate(key) {
        let d = Gcal.dateOf(key);
        let y = key.substring(0, 4) !== Gcal.todayKey.substring(0, 4) ? " " + d.getFullYear() : "";
        return Qt.locale().dayName(d.getDay(), Locale.ShortFormat) + ", " + Qt.locale().monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate() + y;
    }
    // "2026-10-19", "19.10", "19.10.2026", "today", "tomorrow", "fri", "+3"
    function parseDate(s, base) {
        s = (s || "").trim().toLowerCase();
        let m;
        if ((m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(s))) return Gcal.keyOf(new Date(+m[1], +m[2] - 1, +m[3]));
        if ((m = /^(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?$/.exec(s))) {
            let y = m[3] ? (+m[3] < 100 ? 2000 + (+m[3]) : +m[3]) : +base.substring(0, 4);
            return Gcal.keyOf(new Date(y, +m[2] - 1, +m[1]));
        }
        if (s === "today" || s === "сегодня") return Gcal.todayKey;
        if (s === "tomorrow" || s === "tmrw" || s === "завтра") return Gcal.tomorrowKey;
        if ((m = /^([+-]\d+)$/.exec(s))) return Gcal.shiftKey(base, +m[1]);
        let names = ["mo", "tu", "we", "th", "fr", "sa", "su"];
        let i = names.indexOf(s.substring(0, 2));
        if (i >= 0 && /^[a-z]+$/.test(s)) {
            let d = Gcal.dateOf(Gcal.todayKey);
            let cur = (d.getDay() + 6) % 7;
            return Gcal.shiftKey(Gcal.todayKey, ((i - cur + 7) % 7) || 7);
        }
        return "";
    }
    // "9", "930", "9:30", "9.30", "9pm", "9:30 pm", "21"
    function parseTime(s) {
        s = (s || "").trim().toLowerCase().replace(/\s+/g, "");
        let m = /^(\d{1,2})(?:[:.]?(\d{2}))?(am|pm|a|p)?$/.exec(s);
        if (!m) return "";
        let h = +m[1], mi = m[2] ? +m[2] : 0;
        if (m[3]) { if (h === 12) h = 0; if (m[3][0] === "p") h += 12; }
        if (h > 23 || mi > 59) return "";
        return pad2(h) + ":" + pad2(mi);
    }
    readonly property string whenText: {
        if (!it) return "";
        if (it.allDay) {
            let days = Math.max(1, it.days || 1);
            return days > 1 ? shortDate(it.date) + " – " + shortDate(Gcal.shiftKey(it.date, days - 1)) : longDate(it.date) + "  ·  All day";
        }
        let end = minutesOf(it.time) + (it.duration || 60);
        let endDay = end >= 1440 ? "  (next day)" : "";
        return longDate(it.date) + "  ·  " + showTime(it.time) + " – " + showTime(hhmm(end)) + endDay;
    }
    function reminderText(m) {
        if (m === 0) return "At start";
        if (m % 10080 === 0) return (m / 10080) + (m === 10080 ? " week" : " weeks") + " before";
        if (m % 1440 === 0) return (m / 1440) + (m === 1440 ? " day" : " days") + " before";
        if (m % 60 === 0) return (m / 60) + (m === 60 ? " hour" : " hours") + " before";
        return m + " min before";
    }
    readonly property var reminderPresets: it && it.allDay ? [0, 540, 1440, 2880, 10080] : [0, 5, 10, 15, 30, 60, 120, 1440, 10080]

    Column {
        id: body
        x: ed.pad
        y: ed.pad
        width: ed.width - ed.pad * 2
        spacing: 12
        enabled: Gcal.scopeAsk === ""
        opacity: Gcal.scopeAsk === "" ? 1 : 0.25
        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        // ── header: colour mark, title, actions ─────────────────────────
        Item {
            width: parent.width
            height: Math.max(titleView.visible ? titleView.implicitHeight : 44, 36)

            Rectangle {
                id: mark
                x: 0
                y: 8
                width: 14
                height: 14
                radius: 5
                color: ed.accent
            }
            Text {
                id: titleView
                visible: !ed.editing
                anchors.left: mark.right
                anchors.leftMargin: 12
                anchors.right: actions.left
                anchors.rightMargin: 8
                text: ed.it ? (ed.it.title || "(no title)") : ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 21
                font.weight: Font.Bold
            }
            // title input (edit mode)
            Rectangle {
                visible: ed.editing
                anchors.left: mark.right
                anchors.leftMargin: 12
                anchors.right: actions.left
                anchors.rightMargin: 8
                height: 44
                radius: 14
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, titleIn.activeFocus ? 0.11 : 0.06)
                border.width: 1
                border.color: titleIn.activeFocus ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(1, 1, 1, 0.07)
                Behavior on color { ColorAnimation { duration: 160 } }
                TextInput {
                    id: titleIn
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    text: ed.it ? (ed.it.title || "") : ""
                    color: ThemeBackend.text
                    selectionColor: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    onTextEdited: Gcal.setEditor("title", text)
                    Keys.onReturnPressed: Gcal.saveEditor()
                    Keys.onEnterPressed: Gcal.saveEditor()
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: titleIn.text === ""
                        text: "Add title"
                        color: ThemeBackend.subtext0
                        opacity: 0.7
                        font: titleIn.font
                    }
                }
            }
            Row {
                id: actions
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 4
                RoundBtn { visible: !ed.editing && !!ed.ev && Gcal.editorEditable; glyph: 0xF03EB; tip: "Edit"; onClicked: Gcal.startEditing() }
                RoundBtn { visible: !ed.editing && !!ed.ev && Gcal.editorEditable; glyph: 0xF01B4; tip: "Delete"; danger: true; onClicked: Gcal.deleteEditor() }
                RoundBtn { visible: !ed.editing && !!ed.ev && !!ed.ev.url && ed.ev.source === "google" && Gcal.editorEditable; glyph: 0xF03CC; tip: "Open in Google Calendar"; onClicked: Gcal.openEvent(ed.ev) }
                RoundBtn { glyph: 0xF0156; tip: "Close"; onClicked: Gcal.closeEditor() }
            }
        }

        // ── view mode ───────────────────────────────────────────────────
        Column {
            visible: !ed.editing
            width: parent.width
            spacing: 10
            InfoLine { glyph: 0xF0150; text: ed.whenText; strong: true }
            InfoLine {
                glyph: 0xF0456
                visible: text !== ""
                text: ed.ev && ed.ev.repeat ? ed.ev.repeat : (ed.it && ed.it.recurrence ? Rep.describe(ed.it.recurrence, ed.it.date) : "")
            }
            InfoLine { glyph: 0xF07D9; visible: !!ed.it && !!ed.it.location; text: ed.it ? (ed.it.location || "") : "" }
            InfoLine {
                glyph: 0xF009C
                visible: text !== ""
                text: ed.it && ed.it.reminders && ed.it.reminders.length ? ed.it.reminders.map(m => ed.reminderText(m)).join(", ") : ""
            }
            InfoLine { glyph: 0xF0BDC; visible: !!ed.ev && !!ed.ev.meet; text: ed.ev ? (ed.ev.meet || "") : ""; link: true; onActivated: Gcal.openMeet(ed.ev) }
            InfoLine {
                glyph: 0xF00EE
                text: ed.ev ? ed.ev.calendar + (ed.ev.source === "local" ? "  ·  on this computer" : "") : ""
                dim: true
            }
            InfoLine { glyph: 0xF09A9; visible: !!ed.it && !!ed.it.notes; text: ed.it ? (ed.it.notes || "") : ""; dim: true; wrap: true }
            // read-only Google calendars (secret iCal link)
            Rectangle {
                visible: !!ed.ev && !!Gcal.editorOrig && !Gcal.editorEditable
                width: parent.width
                height: roText.implicitHeight + 18
                radius: 12
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
                Text {
                    id: roText
                    x: 12
                    y: 9
                    width: parent.width - 24
                    wrapMode: Text.Wrap
                    text: "Read-only here: this calendar comes from a secret iCal link. Edit it in Google Calendar, or run “gcal-setup oauth” once to edit Google events from the agenda."
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 12
                }
            }
            Row {
                visible: !!ed.ev && ed.ev.source === "google" && !!Gcal.editorOrig && !Gcal.editorEditable
                spacing: 8
                PillBtn { label: "Open in Google Calendar"; glyph: 0xF03CC; onClicked: Gcal.openEvent(ed.ev) }
            }
        }

        // ── edit mode ───────────────────────────────────────────────────
        Column {
            visible: ed.editing
            width: parent.width
            spacing: 10

            // when
            Row {
                spacing: 8
                width: parent.width
                DateField { id: dateF; width: 168; key: ed.it ? ed.it.date : ""; onPicked: k => Gcal.setEditor("date", k) }
                TimeField {
                    visible: ed.it && !ed.it.allDay
                    width: 92
                    value: ed.it ? (ed.it.time || "") : ""
                    onPicked: t => Gcal.setEditor("time", t)
                }
                Text {
                    visible: ed.it && !ed.it.allDay
                    anchors.verticalCenter: parent.verticalCenter
                    text: "–"
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 15
                }
                TimeField {
                    visible: ed.it && !ed.it.allDay
                    width: 92
                    value: ed.it && ed.it.time ? ed.hhmm(ed.minutesOf(ed.it.time) + (ed.it.duration || 60)) : ""
                    onPicked: t => {
                        let d = ed.minutesOf(t) - ed.minutesOf(ed.it.time);
                        if (d <= 0) d += 1440;
                        Gcal.setEditor("duration", d);
                    }
                }
                Text {
                    visible: ed.it && ed.it.allDay
                    anchors.verticalCenter: parent.verticalCenter
                    text: "–"
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 15
                }
                DateField {
                    visible: ed.it && ed.it.allDay
                    width: 168
                    key: ed.it ? Gcal.shiftKey(ed.it.date, Math.max(1, ed.it.days || 1) - 1) : ""
                    onPicked: k => {
                        let n = Math.round((Gcal.dateOf(k) - Gcal.dateOf(ed.it.date)) / 86400000) + 1;
                        Gcal.setEditor("days", Math.max(1, n));
                    }
                }
            }
            Row {
                spacing: 10
                Toggle { on: !!ed.it && !!ed.it.allDay; onToggled: Gcal.setEditor("allDay", !ed.it.allDay) }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "All day"
                    color: ThemeBackend.text
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!ed.it && !ed.it.allDay
                    text: ed.it ? "  " + Gcal.prettyDuration(ed.it.duration || 60) : ""
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 12
                }
            }

            // repeat
            Rectangle {
                id: repeatBtn
                width: parent.width
                height: 42
                radius: 14
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, rMa.containsMouse || Gcal.editorRepeatMenu ? 0.11 : 0.06)
                border.width: 1
                border.color: Gcal.editorRepeatMenu ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(1, 1, 1, 0.07)
                Behavior on color { ColorAnimation { duration: 160 } }
                Text {
                    id: rIcon
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(0xF0456)
                    color: ed.it && ed.it.recurrence ? ThemeBackend.mauve : ThemeBackend.subtext0
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: 17
                }
                Text {
                    anchors.left: rIcon.right
                    anchors.leftMargin: 10
                    anchors.right: chev.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: ed.it ? Rep.describe(ed.it.recurrence, ed.it.date) : ""
                    elide: Text.ElideRight
                    color: ThemeBackend.text
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    id: chev
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(0xF0140)
                    rotation: Gcal.editorRepeatMenu ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: 18
                }
                MouseArea { id: rMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { ed.reminderMenu = false; Gcal.editorRepeatMenu = !Gcal.editorRepeatMenu; } }
            }

            // custom recurrence
            Rectangle {
                id: custom
                visible: Gcal.editorCustom
                width: parent.width
                height: customCol.implicitHeight + 24
                radius: 16
                color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.05)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)
                readonly property var rec: ed.it && ed.it.recurrence ? Rep.normalize(ed.it.recurrence) : null
                function upd(patch) {
                    let r = Object.assign({}, rec || { freq: "weekly", interval: 1, byday: [], bymonthday: [], count: null, until: null }, patch);
                    Gcal.setEditor("recurrence", Rep.normalize(r));
                }
                Column {
                    id: customCol
                    x: 14
                    y: 12
                    width: parent.width - 28
                    spacing: 12
                    Row {
                        spacing: 8
                        Label { text: "Repeat every"; anchors.verticalCenter: parent.verticalCenter }
                        Stepper {
                            anchors.verticalCenter: parent.verticalCenter
                            value: custom.rec ? custom.rec.interval : 1
                            onChanged: v => custom.upd({ interval: v })
                        }
                        Segmented {
                            anchors.verticalCenter: parent.verticalCenter
                            options: [["daily", custom.rec && custom.rec.interval > 1 ? "days" : "day"], ["weekly", custom.rec && custom.rec.interval > 1 ? "weeks" : "week"],
                                      ["monthly", custom.rec && custom.rec.interval > 1 ? "months" : "month"], ["yearly", custom.rec && custom.rec.interval > 1 ? "years" : "year"]]
                            current: custom.rec ? custom.rec.freq : "weekly"
                            onPicked: v => {
                                let d = Gcal.dateOf(ed.it.date);
                                let wd = Rep.WD_CODES[(d.getDay() + 6) % 7];
                                custom.upd({ freq: v, byday: v === "weekly" ? [wd] : [], bymonthday: [] });
                            }
                        }
                    }
                    // weekdays (weekly)
                    Row {
                        visible: !!custom.rec && custom.rec.freq === "weekly"
                        spacing: 6
                        Label { text: "On"; width: 30; anchors.verticalCenter: parent.verticalCenter }
                        Repeater {
                            model: ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
                            delegate: Rectangle {
                                id: wdc
                                required property string modelData
                                required property int index
                                readonly property bool on: !!custom.rec && custom.rec.byday.indexOf(modelData) >= 0
                                width: 34
                                height: 34
                                radius: 17
                                color: on ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
                                          : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, wdMa.containsMouse ? 0.13 : 0.07)
                                border.width: on ? 1 : 0
                                border.color: Qt.rgba(1, 1, 1, 0.25)
                                Behavior on color { ColorAnimation { duration: 160 } }
                                scale: wdMa.pressed ? 0.9 : 1
                                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
                                Text {
                                    anchors.centerIn: parent
                                    text: Qt.locale().dayName((wdc.index + 1) % 7, Locale.NarrowFormat)
                                    color: wdc.on ? ThemeBackend.text : ThemeBackend.subtext1
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }
                                MouseArea {
                                    id: wdMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        let days = custom.rec ? custom.rec.byday.slice() : [];
                                        let i = days.indexOf(wdc.modelData);
                                        if (i >= 0) { if (days.length > 1) days.splice(i, 1); } else days.push(wdc.modelData);
                                        custom.upd({ byday: days });
                                    }
                                }
                            }
                        }
                    }
                    // monthly: day N or Nth weekday
                    Column {
                        visible: !!custom.rec && custom.rec.freq === "monthly"
                        spacing: 6
                        readonly property var opts: {
                            if (!ed.it) return [];
                            let ps = Rep.presets(ed.it.date).filter(p => p.key === "monthday" || p.key === "monthnth" || p.key === "monthlast");
                            return ps;
                        }
                        Repeater {
                            model: parent.opts
                            delegate: Radio {
                                required property var modelData
                                label: modelData.label
                                on: !!custom.rec && (Rep.same(Object.assign({}, custom.rec, { interval: 1, count: null, until: null }), modelData.rec)
                                                     || (modelData.key === "monthday" && !custom.rec.byday.length && !custom.rec.bymonthday.length))
                                onClicked: custom.upd({ byday: modelData.rec.byday, bymonthday: modelData.rec.bymonthday })
                            }
                        }
                    }
                    // ends
                    Label { text: "Ends" }
                    Column {
                        spacing: 6
                        Radio { label: "Never"; on: !!custom.rec && !custom.rec.count && !custom.rec.until; onClicked: custom.upd({ count: null, until: null }) }
                        Row {
                            spacing: 10
                            Radio {
                                id: onRadio
                                label: "On"
                                width: 70
                                on: !!custom.rec && !!custom.rec.until
                                onClicked: custom.upd({ count: null, until: Gcal.shiftKey(ed.it.date, 30) })
                            }
                            DateField {
                                width: 168
                                opacity: onRadio.on ? 1 : 0.45
                                key: custom.rec && custom.rec.until ? custom.rec.until : (ed.it ? Gcal.shiftKey(ed.it.date, 30) : "")
                                onPicked: k => custom.upd({ count: null, until: k })
                            }
                        }
                        Row {
                            spacing: 10
                            Radio {
                                id: afterRadio
                                label: "After"
                                width: 70
                                on: !!custom.rec && !!custom.rec.count
                                onClicked: custom.upd({ until: null, count: 10 })
                            }
                            Stepper {
                                opacity: afterRadio.on ? 1 : 0.45
                                anchors.verticalCenter: parent.verticalCenter
                                value: custom.rec && custom.rec.count ? custom.rec.count : 10
                                onChanged: v => custom.upd({ until: null, count: v })
                            }
                            Label { text: "occurrences"; anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                }
            }

            // place
            FieldRow {
                glyph: 0xF07D9
                placeholder: "Add location"
                value: ed.it ? (ed.it.location || "") : ""
                onEdited: v => Gcal.setEditor("location", v)
            }

            // reminders
            Flow {
                width: parent.width
                spacing: 6
                Text {
                    height: 30
                    verticalAlignment: Text.AlignVCenter
                    text: String.fromCodePoint(0xF009C)
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: 17
                    rightPadding: 6
                }
                Repeater {
                    model: ed.it && ed.it.reminders ? ed.it.reminders : []
                    delegate: Chipx {
                        required property var modelData
                        label: ed.reminderText(modelData)
                        removable: true
                        onRemoved: Gcal.setEditor("reminders", ed.it.reminders.filter(m => m !== modelData))
                    }
                }
                Chipx {
                    label: "Add reminder"
                    glyph: 0xF0415
                    subtle: true
                    visible: !ed.it || !ed.it.reminders || ed.it.reminders.length < 5
                    onClicked: { Gcal.editorRepeatMenu = false; ed.reminderMenu = !ed.reminderMenu; }
                }
            }
            Flow {
                visible: ed.reminderMenu
                width: parent.width
                spacing: 6
                leftPadding: 30
                Repeater {
                    model: ed.reminderPresets.filter(m => !ed.it || !ed.it.reminders || ed.it.reminders.indexOf(m) < 0)
                    delegate: Chipx {
                        required property var modelData
                        label: ed.reminderText(modelData)
                        subtle: true
                        onClicked: {
                            let r = (ed.it.reminders || []).slice();
                            r.push(modelData);
                            r.sort((a, b) => a - b);
                            Gcal.setEditor("reminders", r);
                            ed.reminderMenu = false;
                        }
                    }
                }
            }

            // where it goes
            Text {
                width: parent.width
                text: ed.ev ? "Calendar: " + ed.ev.calendar
                            : (Gcal.writeEnabled ? "Saves to Google Calendar (" + (Gcal.doc.writeCalendar || "") + ")" : "Saves to the local calendar on this computer")
                color: ThemeBackend.subtext0
                opacity: 0.75
                elide: Text.ElideRight
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 11
            }
        }

        // error
        Text {
            visible: Gcal.editorError !== ""
            width: parent.width
            text: Gcal.editorError
            wrapMode: Text.Wrap
            color: ThemeBackend.red
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }

        // buttons (edit mode)
        Item {
            visible: ed.editing
            width: parent.width
            height: 38
            PillBtn {
                visible: !!ed.ev
                anchors.left: parent.left
                label: "Delete"
                glyph: 0xF01B4
                danger: true
                onClicked: Gcal.deleteEditor()
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                PillBtn {
                    label: "Cancel"
                    onClicked: {
                        if (ed.ev) { Gcal.editorItem = JSON.parse(JSON.stringify(Gcal.editorOrig || Gcal.editorItem)); Gcal.editorMode = "view"; }
                        else Gcal.closeEditor();
                    }
                }
                PillBtn {
                    label: Gcal.editorBusy ? "Saving…" : "Save"
                    glyph: Gcal.editorBusy ? 0xF0450 : 0xF012C
                    primary: true
                    onClicked: Gcal.saveEditor()
                }
            }
        }
    }

    // ── Repeat menu (floats over the form) ───────────────────────────────
    Rectangle {
        id: menu
        visible: Gcal.editorRepeatMenu && ed.editing
        z: 20
        x: body.x
        y: body.y + repeatBtn.mapToItem(body, 0, 0).y + repeatBtn.height + 6
        width: body.width
        height: menuCol.implicitHeight + 12
        radius: 16
        color: ThemeBackend.base
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.35)
        opacity: visible ? 1 : 0
        Column {
            id: menuCol
            x: 6
            y: 6
            width: parent.width - 12
            Repeater {
                model: ed.it ? Rep.presets(ed.it.date).concat([{ key: "custom", label: "Custom…", rec: null }]) : []
                delegate: Rectangle {
                    id: mi
                    required property var modelData
                    readonly property bool cur: !!ed.it && (modelData.key === "custom" ? Gcal.editorCustom || Rep.presetKey(ed.it.recurrence, ed.it.date) === "custom"
                                                                                    : (!Gcal.editorCustom && Rep.presetKey(ed.it.recurrence, ed.it.date) === modelData.key))
                    width: menuCol.width
                    height: 36
                    radius: 11
                    color: miMa.containsMouse ? Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.10)
                                              : (cur ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.16) : "transparent")
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: mi.modelData.label
                        color: ThemeBackend.text
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 14
                        font.weight: mi.cur ? Font.Bold : Font.Normal
                    }
                    Text {
                        visible: mi.cur
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xF012C)
                        color: ThemeBackend.mauve
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: 16
                    }
                    MouseArea {
                        id: miMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Gcal.editorRepeatMenu = false;
                            if (mi.modelData.key === "custom") {
                                Gcal.editorCustom = true;
                                if (!ed.it.recurrence) Gcal.setRepeatPreset("weekly");
                            } else {
                                Gcal.editorCustom = false;
                                Gcal.setRepeatPreset(mi.modelData.key);
                            }
                        }
                    }
                }
            }
        }
    }

    // ── "this event / this and following / all events" ──────────────────
    Rectangle {
        id: scopeCard
        visible: Gcal.scopeAsk !== ""
        z: 30
        width: 340
        height: scopeCol.implicitHeight + 36
        anchors.centerIn: parent
        radius: 20
        color: ThemeBackend.base
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)
        property string choice: "this"
        onVisibleChanged: if (visible) choice = (Gcal.scopeAsk === "save" && Gcal.editorRuleChanged) ? "following" : "this"
        MouseArea { anchors.fill: parent }
        Column {
            id: scopeCol
            x: 20
            y: 18
            width: parent.width - 40
            spacing: 8
            Text {
                text: Gcal.scopeAsk === "delete" ? "Delete recurring event" : "Edit recurring event"
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 17
                font.weight: Font.Bold
                bottomPadding: 4
            }
            Radio { visible: !(Gcal.scopeAsk === "save" && Gcal.editorRuleChanged); label: "This event"; on: scopeCard.choice === "this"; onClicked: scopeCard.choice = "this" }
            Radio { label: "This and following events"; on: scopeCard.choice === "following"; onClicked: scopeCard.choice = "following" }
            Radio { label: "All events"; on: scopeCard.choice === "all"; onClicked: scopeCard.choice = "all" }
            Item { width: 1; height: 6 }
            Row {
                anchors.right: parent.right
                spacing: 8
                PillBtn { label: "Cancel"; onClicked: Gcal.scopeAsk = "" }
                PillBtn {
                    label: "OK"
                    primary: true
                    danger: Gcal.scopeAsk === "delete"
                    onClicked: Gcal.runEdit(Gcal.scopeAsk, scopeCard.choice)
                }
            }
        }
    }

    // ── small building blocks ────────────────────────────────────────────
    component Label: Text {
        color: ThemeBackend.subtext1
        font.family: ThemeBackend.fontFamily
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }

    component InfoLine: Item {
        id: il
        property int glyph: 0
        property string text: ""
        property bool strong: false
        property bool dim: false
        property bool link: false
        property bool wrap: false
        signal activated()
        width: parent ? parent.width : 300
        height: Math.max(22, ilText.implicitHeight)
        Text {
            id: ilIcon
            y: 1
            text: String.fromCodePoint(il.glyph)
            color: il.dim ? ThemeBackend.subtext0 : ThemeBackend.mauve
            font.family: ThemeBackend.iconFont
            font.pixelSize: 17
        }
        Text {
            id: ilText
            x: 30
            y: 1
            width: il.width - 30
            text: il.text
            wrapMode: il.wrap || il.strong ? Text.Wrap : Text.NoWrap
            maximumLineCount: il.wrap ? 4 : 2
            elide: Text.ElideRight
            color: il.link ? ThemeBackend.blue : (il.dim ? ThemeBackend.subtext0 : ThemeBackend.text)
            font.family: ThemeBackend.fontFamily
            font.pixelSize: il.strong ? 15 : 14
            font.weight: il.strong ? Font.DemiBold : Font.Normal
            font.underline: il.link && ilMa.containsMouse
        }
        MouseArea { id: ilMa; anchors.fill: parent; enabled: il.link; hoverEnabled: true; cursorShape: il.link ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: il.activated() }
    }

    component RoundBtn: Rectangle {
        id: rb
        property int glyph: 0
        property string tip: ""
        property bool danger: false
        signal clicked()
        width: 34
        height: 34
        radius: 17
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, rbMa.containsMouse ? 0.15 : 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: rbMa.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
        Text {
            anchors.centerIn: parent
            text: String.fromCodePoint(rb.glyph)
            color: rbMa.containsMouse ? (rb.danger ? ThemeBackend.red : ThemeBackend.mauve) : ThemeBackend.subtext1
            font.family: ThemeBackend.iconFont
            font.pixelSize: 17
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        MouseArea { id: rbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rb.clicked() }
    }

    component PillBtn: Rectangle {
        id: pb
        property string label: ""
        property int glyph: 0
        property bool primary: false
        property bool danger: false
        signal clicked()
        readonly property color tone: danger ? ThemeBackend.red : ThemeBackend.mauve
        width: pbRow.implicitWidth + 28
        height: 38
        radius: 19
        color: primary ? Qt.rgba(tone.r, tone.g, tone.b, pbMa.containsMouse ? 0.62 : 0.48)
                       : Qt.rgba(danger ? tone.r : ThemeBackend.text.r, danger ? tone.g : ThemeBackend.text.g, danger ? tone.b : ThemeBackend.text.b, pbMa.containsMouse ? 0.16 : 0.08)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, primary ? 0.22 : 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: pbMa.pressed ? 0.95 : 1
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                visible: pb.glyph !== 0
                anchors.verticalCenter: parent.verticalCenter
                text: pb.glyph ? String.fromCodePoint(pb.glyph) : ""
                color: pb.primary ? ThemeBackend.text : (pb.danger ? ThemeBackend.red : ThemeBackend.subtext1)
                font.family: ThemeBackend.iconFont
                font.pixelSize: 16
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: pb.label
                color: pb.danger && !pb.primary ? ThemeBackend.red : ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 13
                font.weight: Font.Bold
            }
        }
        MouseArea { id: pbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked() }
    }

    component Chipx: Rectangle {
        id: cx
        property string label: ""
        property int glyph: 0
        property bool removable: false
        property bool subtle: false
        signal clicked()
        signal removed()
        width: cxRow.implicitWidth + 22
        height: 30
        radius: 15
        color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, cxMa.containsMouse ? 0.26 : (subtle ? 0.08 : 0.16))
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, cxMa.containsMouse ? 0.2 : 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        Row {
            id: cxRow
            anchors.centerIn: parent
            spacing: 5
            Text {
                visible: cx.glyph !== 0
                anchors.verticalCenter: parent.verticalCenter
                text: cx.glyph ? String.fromCodePoint(cx.glyph) : ""
                color: ThemeBackend.mauve
                font.family: ThemeBackend.iconFont
                font.pixelSize: 14
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: cx.label
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }
            Text {
                visible: cx.removable
                anchors.verticalCenter: parent.verticalCenter
                text: String.fromCodePoint(0xF0156)
                color: xMa.containsMouse ? ThemeBackend.red : ThemeBackend.subtext0
                font.family: ThemeBackend.iconFont
                font.pixelSize: 13
                MouseArea { id: xMa; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cx.removed() }
            }
        }
        MouseArea { id: cxMa; anchors.fill: parent; z: -1; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cx.clicked() }
    }

    component Toggle: Rectangle {
        id: tg
        property bool on: false
        signal toggled()
        width: 42
        height: 24
        radius: 12
        color: on ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.14)
        Behavior on color { ColorAnimation { duration: 200 } }
        Rectangle {
            width: 18
            height: 18
            radius: 9
            y: 3
            x: tg.on ? tg.width - width - 3 : 3
            color: ThemeBackend.text
            Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tg.toggled() }
    }

    component Radio: Item {
        id: rd
        property string label: ""
        property bool on: false
        signal clicked()
        width: Math.max(rdRow.implicitWidth, 10)
        height: 28
        Row {
            id: rdRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18
                radius: 9
                color: "transparent"
                border.width: 2
                border.color: rd.on ? ThemeBackend.mauve : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, rdMa.containsMouse ? 0.6 : 0.35)
                Rectangle {
                    anchors.centerIn: parent
                    width: rd.on ? 8 : 0
                    height: width
                    radius: width / 2
                    color: ThemeBackend.mauve
                    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: rd.label
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 14
                font.weight: rd.on ? Font.DemiBold : Font.Normal
            }
        }
        MouseArea { id: rdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rd.clicked() }
    }

    component Stepper: Row {
        id: st
        property int value: 1
        property int minimum: 1
        property int maximum: 999
        signal changed(int v)
        spacing: 2
        Rectangle {
            width: 28; height: 30; radius: 10
            color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, mMa.containsMouse ? 0.15 : 0.07)
            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0374); color: ThemeBackend.subtext1; font.family: ThemeBackend.iconFont; font.pixelSize: 14 }
            MouseArea { id: mMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (st.value > st.minimum) st.changed(st.value - 1) }
        }
        Rectangle {
            width: 44; height: 30; radius: 10
            color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, numIn.activeFocus ? 0.12 : 0.05)
            TextInput {
                id: numIn
                anchors.fill: parent
                horizontalAlignment: TextInput.AlignHCenter
                verticalAlignment: TextInput.AlignVCenter
                text: String(st.value)
                validator: IntValidator { bottom: st.minimum; top: st.maximum }
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 14
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
                onEditingFinished: { let v = parseInt(text); if (!isNaN(v) && v !== st.value) st.changed(Math.max(st.minimum, Math.min(st.maximum, v))); else text = String(st.value); }
            }
        }
        Rectangle {
            width: 28; height: 30; radius: 10
            color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, pMa.containsMouse ? 0.15 : 0.07)
            Text { anchors.centerIn: parent; text: String.fromCodePoint(0xF0415); color: ThemeBackend.subtext1; font.family: ThemeBackend.iconFont; font.pixelSize: 14 }
            MouseArea { id: pMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (st.value < st.maximum) st.changed(st.value + 1) }
        }
    }

    component Segmented: Rectangle {
        id: sg
        property var options: []        // [[value, label], …]
        property string current: ""
        signal picked(string v)
        width: sgRow.implicitWidth + 6
        height: 30
        radius: 15
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
        Row {
            id: sgRow
            x: 3
            y: 3
            Repeater {
                model: sg.options
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: sg.current === modelData[0]
                    width: sgT.implicitWidth + 20
                    height: 24
                    radius: 12
                    color: on ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.42) : (sgMa.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Text {
                        id: sgT
                        anchors.centerIn: parent
                        text: modelData[1]
                        color: parent.on ? ThemeBackend.text : ThemeBackend.subtext1
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Bold
                    }
                    MouseArea { id: sgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sg.picked(modelData[0]) }
                }
            }
        }
    }

    // a date shown as "Mon, Oct 19"; click to type (2026-10-19, 19.10, fri, tomorrow, +3); ‹ › step a day
    component DateField: Rectangle {
        id: df
        property string key: ""
        signal picked(string k)
        height: 38
        radius: 13
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, dfIn.activeFocus ? 0.12 : (dfMa.containsMouse ? 0.10 : 0.06))
        border.width: 1
        border.color: dfIn.activeFocus ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(1, 1, 1, 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        Text {
            id: dfPrev
            x: 6
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF0141)
            color: pvMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext0
            font.family: ThemeBackend.iconFont
            font.pixelSize: 16
            MouseArea { id: pvMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (df.key) df.picked(Gcal.shiftKey(df.key, -1)) }
        }
        Text {
            id: dfNext
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF0142)
            color: nxMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext0
            font.family: ThemeBackend.iconFont
            font.pixelSize: 16
            MouseArea { id: nxMa; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (df.key) df.picked(Gcal.shiftKey(df.key, 1)) }
        }
        Text {
            visible: !dfIn.activeFocus
            anchors.centerIn: parent
            text: df.key ? ed.shortDate(df.key) : ""
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
        MouseArea { id: dfMa; anchors.fill: parent; anchors.leftMargin: 24; anchors.rightMargin: 24; hoverEnabled: true; cursorShape: Qt.IBeamCursor; onClicked: { dfIn.text = df.key; dfIn.forceActiveFocus(); dfIn.selectAll(); } }
        TextInput {
            id: dfIn
            visible: activeFocus
            anchors.fill: parent
            anchors.leftMargin: 26
            anchors.rightMargin: 26
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            color: ThemeBackend.text
            selectionColor: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 14
            clip: true
            function commit() { let k = ed.parseDate(text, df.key || Gcal.todayKey); if (k) df.picked(k); ed.forceActiveFocus(); }
            Keys.onReturnPressed: commit()
            Keys.onEnterPressed: commit()
            Keys.onEscapePressed: ed.forceActiveFocus()
            Keys.onUpPressed: { if (df.key) df.picked(Gcal.shiftKey(df.key, 1)); text = Gcal.shiftKey(df.key, 1); }
            Keys.onDownPressed: { if (df.key) df.picked(Gcal.shiftKey(df.key, -1)); text = Gcal.shiftKey(df.key, -1); }
            onActiveFocusChanged: if (!activeFocus && text !== "" && text !== df.key) { let k = ed.parseDate(text, df.key || Gcal.todayKey); if (k) df.picked(k); }
        }
    }

    // "10:00"; type 9, 930, 9:30, 9pm …; ↑/↓ step 15 min
    component TimeField: Rectangle {
        id: tf
        property string value: ""
        signal picked(string t)
        height: 38
        radius: 13
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, tfIn.activeFocus ? 0.12 : 0.06)
        border.width: 1
        border.color: tfIn.activeFocus ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(1, 1, 1, 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        Text {
            visible: !tfIn.activeFocus
            anchors.centerIn: parent
            text: ed.showTime(tf.value)
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 14
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { tfIn.text = tf.value; tfIn.forceActiveFocus(); tfIn.selectAll(); } }
        TextInput {
            id: tfIn
            visible: activeFocus
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            color: ThemeBackend.text
            selectionColor: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 14
            font.features: { "tnum": 1 }
            clip: true
            function commit() { let t = ed.parseTime(text); if (t) tf.picked(t); ed.forceActiveFocus(); }
            Keys.onReturnPressed: commit()
            Keys.onEnterPressed: commit()
            Keys.onEscapePressed: ed.forceActiveFocus()
            Keys.onUpPressed: { let t = ed.hhmm(ed.minutesOf(tf.value) + 15); tf.picked(t); text = t; }
            Keys.onDownPressed: { let t = ed.hhmm(ed.minutesOf(tf.value) - 15); tf.picked(t); text = t; }
            onActiveFocusChanged: if (!activeFocus && text !== "" && text !== tf.value) { let t = ed.parseTime(text); if (t) tf.picked(t); }
        }
    }

    component FieldRow: Rectangle {
        id: fr
        property int glyph: 0
        property string placeholder: ""
        property string value: ""
        signal edited(string v)
        width: parent ? parent.width : 300
        height: 40
        radius: 13
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, frIn.activeFocus ? 0.11 : 0.06)
        border.width: 1
        border.color: frIn.activeFocus ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.6) : Qt.rgba(1, 1, 1, 0.07)
        Behavior on color { ColorAnimation { duration: 160 } }
        Text {
            id: frIcon
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(fr.glyph)
            color: fr.value ? ThemeBackend.mauve : ThemeBackend.subtext0
            font.family: ThemeBackend.iconFont
            font.pixelSize: 17
        }
        TextInput {
            id: frIn
            anchors.left: frIcon.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: fr.value
            clip: true
            color: ThemeBackend.text
            selectionColor: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.5)
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 14
            onTextEdited: fr.edited(text)
            Keys.onReturnPressed: Gcal.saveEditor()
            Keys.onEnterPressed: Gcal.saveEditor()
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: frIn.text === ""
                text: fr.placeholder
                color: ThemeBackend.subtext0
                opacity: 0.7
                font: frIn.font
            }
        }
    }
}
