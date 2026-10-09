import QtQuick
import "../"

// One day section of the agenda: header (label, daily note, count), events, tasks.
Column {
    id: day

    property string dayKey: ""
    property real fontPx: 13.5
    property bool highlighted: false

    // the Month view passes its own lists for days outside events.json's window
    property var evsOverride: null
    property var tksOverride: null
    property var noteOverride: null       // bool, or null = ask Gcal
    property bool showDateAlways: false
    property string labelOverride: ""     // replaces the day label (Month view's detail pane)

    readonly property var evs: evsOverride !== null ? evsOverride : Gcal.eventsOn(dayKey)
    readonly property var tks: tksOverride !== null ? tksOverride : Gcal.tasksOn(dayKey)
    readonly property bool isToday: dayKey === Gcal.todayKey
    readonly property bool empty: evs.length === 0 && tks.length === 0
    readonly property bool hasNote: noteOverride !== null ? noteOverride : Gcal.hasDaily(dayKey)

    spacing: 2

    Item {
        width: day.width
        height: day.fontPx * 1.9

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -day.fontPx * 0.45
            anchors.rightMargin: -day.fontPx * 0.45
            radius: day.fontPx * 0.7
            color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, day.highlighted ? 0.16 : 0)
            Behavior on color { ColorAnimation { duration: 400; easing.type: Easing.OutCubic } }
        }

        Text {
            id: label
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: (day.labelOverride || Gcal.dayLabel(day.dayKey)).toUpperCase()
            color: day.isToday ? ThemeBackend.mauve : ThemeBackend.subtext1
            font.family: ThemeBackend.fontFamily
            font.pixelSize: day.fontPx * 0.8
            font.weight: Font.Black
            font.letterSpacing: day.fontPx * 0.08
        }
        Text {
            anchors.left: label.right
            anchors.leftMargin: day.fontPx * 0.6
            anchors.verticalCenter: parent.verticalCenter
            visible: day.labelOverride ? false : day.showDateAlways ? Gcal.dayLabel(day.dayKey).indexOf(",") < 0 : (day.dayKey === Gcal.todayKey || day.dayKey === Gcal.tomorrowKey)
            text: { let d = Gcal.dateOf(day.dayKey); return Qt.locale().monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate(); }
            color: ThemeBackend.subtext0
            opacity: 0.6
            font.family: ThemeBackend.fontFamily
            font.pixelSize: day.fontPx * 0.8
            font.weight: Font.Bold
        }

        // daily-note chip: open (or create) that day's note
        Rectangle {
            id: noteChip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: day.hasNote || day.isToday
            width: noteRow.implicitWidth + day.fontPx * 0.9
            height: day.fontPx * 1.5
            radius: height / 2
            color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, nMa.containsMouse ? 0.3 : (day.hasNote ? 0.14 : 0.06))
            Behavior on color { ColorAnimation { duration: 160 } }
            Row {
                id: noteRow
                anchors.centerIn: parent
                spacing: day.fontPx * 0.25
                Text {
                    text: String.fromCodePoint(day.hasNote ? 0xF0EBF : 0xF1612)
                    color: ThemeBackend.mauve
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: day.fontPx * 0.85
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: day.hasNote ? "note" : "new note"
                    color: ThemeBackend.mauve
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: day.fontPx * 0.72
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea { id: nMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.openDaily(day.dayKey) }
        }
    }

    Repeater {
        model: day.evs
        delegate: AgendaEventRow {
            required property var modelData
            width: day.width
            ev: modelData
            fontPx: day.fontPx
            dayKey: day.dayKey
            showCalendar: Gcal.calendars.length > 1
        }
    }
    Repeater {
        model: day.tks
        delegate: AgendaTaskRow {
            required property var modelData
            width: day.width
            task: modelData
            fontPx: day.fontPx
        }
    }
    Text {
        visible: day.empty
        x: day.fontPx * 0.1
        height: day.fontPx * 1.7
        verticalAlignment: Text.AlignVCenter
        text: day.isToday ? "Nothing planned — enjoy the day" : "Free"
        color: ThemeBackend.subtext0
        opacity: 0.55
        font.family: ThemeBackend.fontFamily
        font.pixelSize: day.fontPx * 0.85
        font.italic: true
    }
}
