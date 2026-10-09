import QtQuick
import "../"

// One calendar event: colored calendar bar, time, title, location/calendar.
// Click opens the event in Google Calendar; the camera chip opens the Meet link.
Item {
    id: row

    property var ev: null
    property real fontPx: 13
    property bool compact: false          // single line (desktop widget)
    property bool showCalendar: true
    property string dayKey: ""            // day the row is listed under (multi-day events)

    readonly property bool now: !!ev && Gcal.isNow(ev)
    readonly property bool past: !!ev && !ev.allDay && Gcal.isPast(ev)
    readonly property color accent: Gcal.colorFor(ev ? ev.color : "")
    readonly property bool multiDay: !!ev && ev.startDate !== ev.endDate

    implicitHeight: compact ? fontPx * 2.0 : fontPx * (subtitle.text !== "" ? 3.55 : 2.6)
    height: implicitHeight

    readonly property string timeText: {
        if (!ev) return "";
        if (ev.allDay) return multiDay ? "All day" : "All day";
        if (continued) return dayKey === ev.endDate ? Gcal.fmtTime(ev.endMs) : "All day";
        return Gcal.fmtTime(ev.startMs);
    }
    // a timed event that started on an earlier day (e.g. 23:00–01:00 listed under tomorrow)
    readonly property bool continued: !!ev && !ev.allDay && multiDay && dayKey !== "" && dayKey !== ev.startDate
    readonly property string endText: (!ev || ev.allDay || compact) ? "" : (continued ? (dayKey === ev.endDate ? "ends" : "") : Gcal.fmtTime(ev.endMs))

    Rectangle {
        id: hover
        anchors.fill: parent
        anchors.leftMargin: -row.fontPx * 0.45
        anchors.rightMargin: -row.fontPx * 0.45
        radius: row.fontPx * 0.7
        color: row.now ? Qt.rgba(row.accent.r, row.accent.g, row.accent.b, ma.containsMouse ? 0.26 : 0.16)
                       : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, ma.containsMouse ? 0.09 : 0)
        Behavior on color { ColorAnimation { duration: 180 } }
    }

    // calendar color bar
    Rectangle {
        id: bar
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(3, row.fontPx * 0.24)
        height: parent.height - row.fontPx * (row.compact ? 0.6 : 0.75)
        radius: width / 2
        color: row.accent
        opacity: row.past ? 0.4 : 1
    }

    Column {
        id: timeCol
        x: bar.width + row.fontPx * 0.6
        anchors.verticalCenter: parent.verticalCenter
        width: row.fontPx * (DateTime.is12Hour ? 4.6 : 3.3)
        spacing: 0
        Text {
            text: row.timeText
            color: row.now ? row.accent : ThemeBackend.text
            opacity: row.past ? 0.5 : 1
            font.family: ThemeBackend.fontFamily
            font.pixelSize: row.ev && row.ev.allDay ? row.fontPx * 0.8 : row.fontPx * 0.95
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
        }
        Text {
            visible: text !== ""
            text: row.endText
            color: ThemeBackend.subtext0
            opacity: 0.75
            font.family: ThemeBackend.fontFamily
            font.pixelSize: row.fontPx * 0.78
            font.features: { "tnum": 1 }
        }
    }

    Column {
        anchors.left: timeCol.right
        anchors.leftMargin: row.fontPx * 0.35
        anchors.right: meetChip.visible ? meetChip.left : parent.right
        anchors.rightMargin: row.fontPx * 0.4
        anchors.verticalCenter: parent.verticalCenter
        spacing: row.fontPx * 0.08
        Text {
            width: parent.width
            text: row.ev ? row.ev.title : ""
            elide: Text.ElideRight
            color: ThemeBackend.text
            opacity: row.past ? 0.5 : 1
            font.family: ThemeBackend.fontFamily
            font.pixelSize: row.fontPx
            font.weight: Font.DemiBold
        }
        Text {
            id: subtitle
            visible: !row.compact && text !== ""
            width: parent.width
            text: {
                if (!row.ev) return "";
                let parts = [];
                if (row.now) parts.push("now · ends " + Gcal.fmtTime(row.ev.endMs));
                if (row.ev.location) parts.push(row.ev.location);
                if (row.showCalendar && row.ev.calendar) parts.push(row.ev.calendar);
                return parts.join("  ·  ");
            }
            elide: Text.ElideRight
            color: ThemeBackend.subtext0
            opacity: 0.85
            font.family: ThemeBackend.fontFamily
            font.pixelSize: row.fontPx * 0.8
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Gcal.openEvent(row.ev)
    }

    // video-call chip (Meet / Zoom / Teams / Telemost)
    Rectangle {
        id: meetChip
        visible: !!row.ev && !!row.ev.meet
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: row.fontPx * (row.compact ? 1.7 : 2.1)
        height: width
        radius: width / 2
        color: meetMa.containsMouse ? Qt.rgba(row.accent.r, row.accent.g, row.accent.b, 0.35) : Qt.rgba(row.accent.r, row.accent.g, row.accent.b, 0.16)
        Behavior on color { ColorAnimation { duration: 160 } }
        scale: meetMa.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
        Text {
            anchors.centerIn: parent
            text: String.fromCodePoint(0xF0BDC)
            color: row.accent
            font.family: ThemeBackend.iconFont
            font.pixelSize: parent.width * 0.55
        }
        MouseArea {
            id: meetMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Gcal.openMeet(row.ev)
        }
    }
}
