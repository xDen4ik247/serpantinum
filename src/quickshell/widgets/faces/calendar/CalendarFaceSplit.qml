import QtQuick
import "../"
import Quickshell
import "../../"
import "../../../"
import "../../../calendar"

// "Calendar" split variant — clock + date on a tinted panel, month grid beside it.
// When tall enough (≥ 200 px panel) the clock compacts and the panel lists what's next
// (Google Calendar events today/tomorrow, Obsidian tasks due today) from the Gcal singleton.
// Scroll over the grid to browse months; click the month title to return to today;
// click a day for its agenda, an event to open it in Google Calendar, a task to open its note.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 360
    property real minHeight: 180
    property real maxWidth: 1400
    property real maxHeight: 700
    property real minAspect: 1.4
    property real maxAspect: 3.2
    property bool isRound: false
    property int weekStart: 1

    // month navigation (today + browse offset) shared with the other calendar face: MonthGrid.qml
    MonthGrid.MonthNav { id: nav; grid: cal }
    readonly property string todayKey: nav.todayKey
    readonly property date today: nav.today
    readonly property int viewYear: nav.viewYear
    readonly property int viewMonth: nav.viewMonth
    readonly property bool isCurrentMonth: nav.isCurrentMonth
    function shift(delta) { nav.shift(delta); }
    function goToday() { nav.goToday(); }

    readonly property real pad: Math.max(12, height * 0.07)
    readonly property real panelW: Math.min(width * 0.44, height * 1.15)

    Rectangle {
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
    }

    // left: clock panel
    Rectangle {
        id: panel
        x: root.pad * 0.6
        y: root.pad * 0.6
        width: root.panelW
        height: root.height - root.pad * 1.2
        radius: Math.max(6, ThemeBackend.borderRadius - root.pad * 0.6)
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.26) }
            GradientStop { position: 1.0; color: Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.14) }
        }

        readonly property real unit: Math.min(width / 4.2, height / 3.2)
        readonly property bool agendaMode: height >= 200

        // ── classic: big clock centered (short widgets) ──
        Column {
            visible: !panel.agendaMode
            anchors.left: parent.left
            anchors.leftMargin: panel.unit * 0.42
            anchors.verticalCenter: parent.verticalCenter
            spacing: panel.unit * 0.05

            Text {
                text: Qt.locale().dayName(root.today.getDay(), Locale.LongFormat).toUpperCase()
                color: ThemeBackend.mauve
                font.family: ThemeBackend.fontFamily
                font.pixelSize: panel.unit * 0.24
                font.weight: Font.Black
                font.letterSpacing: panel.unit * 0.04
            }
            Row {
                spacing: panel.unit * 0.06
                Text {
                    id: clock
                    text: Qt.formatDateTime(DateTime.now, DateTime.is12Hour ? "h:mm" : "HH:mm")
                    color: ThemeBackend.text
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: panel.unit * 1.05
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
                Text {
                    visible: DateTime.is12Hour
                    text: Qt.formatDateTime(DateTime.now, "AP")
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: panel.unit * 0.26
                    font.weight: Font.Bold
                    anchors.baseline: clock.baseline
                }
            }
            Text {
                text: Qt.locale().standaloneMonthName(root.today.getMonth(), Locale.LongFormat) + " " + root.today.getDate() + ", " + root.today.getFullYear()
                color: ThemeBackend.subtext0
                font.family: ThemeBackend.fontFamily
                font.pixelSize: panel.unit * 0.25
                font.weight: Font.DemiBold
            }
        }

        // ── agenda: compact clock + what's next ──
        Item {
            id: ag
            visible: panel.agendaMode
            anchors.fill: parent
            anchors.margins: Math.max(12, panel.width * 0.065)
            readonly property real fs: Math.max(11, Math.min(14, panel.width * 0.052))

            Text {
                id: agClock
                text: Qt.formatDateTime(DateTime.now, DateTime.is12Hour ? "h:mm" : "HH:mm")
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Math.round(Math.min(panel.height * 0.17, panel.width * 0.19))
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
                y: -font.pixelSize * 0.12
            }
            Column {
                anchors.left: agClock.right
                anchors.leftMargin: ag.fs * 0.8
                anchors.right: parent.right
                anchors.verticalCenter: agClock.verticalCenter
                anchors.verticalCenterOffset: agClock.y / 2
                spacing: 0
                Text {
                    width: parent.width
                    text: Qt.locale().dayName(root.today.getDay(), Locale.LongFormat).toUpperCase()
                    elide: Text.ElideRight
                    color: ThemeBackend.mauve
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: ag.fs * 0.85
                    font.weight: Font.Black
                    font.letterSpacing: ag.fs * 0.08
                }
                Text {
                    width: parent.width
                    text: Qt.locale().standaloneMonthName(root.today.getMonth(), Locale.LongFormat) + " " + root.today.getDate()
                    elide: Text.ElideRight
                    color: ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: ag.fs
                    font.weight: Font.DemiBold
                }
            }

            Item {
                id: listBox
                anchors.left: parent.left
                anchors.right: parent.right
                y: agClock.y + agClock.height + ag.fs * 0.1
                height: parent.height - y
                clip: true

                readonly property var rows: { let r = Gcal.revision, n = Gcal.nowMs; return Gcal.upcoming(0); }

                Column {
                    id: rowsCol
                    width: parent.width
                    spacing: 0
                    Repeater {
                        model: listBox.rows
                        delegate: Loader {
                            required property var modelData
                            width: rowsCol.width
                            sourceComponent: modelData.kind === "header" ? hdr : (modelData.kind === "event" ? evRow : (modelData.kind === "more" ? moreRow : tkRow))
                            Component {
                                id: hdr
                                Item {
                                    height: ag.fs * 1.7
                                    Text {
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: ag.fs * 0.2
                                        text: modelData.label.toUpperCase()
                                        color: modelData.label === "Today" ? ThemeBackend.text : ThemeBackend.subtext1
                                        opacity: 0.8
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: ag.fs * 0.72
                                        font.weight: Font.Black
                                        font.letterSpacing: ag.fs * 0.1
                                    }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.openDay(modelData.key) }
                                }
                            }
                            Component {
                                id: moreRow
                                Item {
                                    height: ag.fs * 1.7
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: ag.fs * 1.7
                                        text: modelData.label
                                        color: moreMa.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: ag.fs * 0.85
                                        font.weight: Font.DemiBold
                                    }
                                    MouseArea { id: moreMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.openDay(modelData.key) }
                                }
                            }
                            Component { id: evRow; AgendaEventRow { ev: modelData.ev; fontPx: ag.fs; compact: true; dayKey: modelData.ev.startDate } }
                            Component { id: tkRow; AgendaTaskRow { task: modelData.task; fontPx: ag.fs; compact: true } }
                        }
                    }
                }

                // empty state
                Column {
                    visible: Gcal.loaded && listBox.rows.length === 0
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: ag.fs * 0.3
                    Text {
                        text: "Nothing planned"
                        color: ThemeBackend.subtext0
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: ag.fs
                        font.weight: Font.DemiBold
                    }
                    Text {
                        visible: !Gcal.configured
                        text: String.fromCodePoint(0xF02AD) + "  Connect Google Calendar"
                        color: connMa.containsMouse ? ThemeBackend.text : ThemeBackend.mauve
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: ag.fs * 0.85
                        font.weight: Font.Bold
                        MouseArea { id: connMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Gcal.runSetup() }
                    }
                }

                // soft fade where the list is cut off
                Rectangle {
                    visible: rowsCol.height > listBox.height
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: ag.fs * 1.6
                    gradient: Gradient {
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 1; color: Qt.tint(ThemeBackend.surface0, Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.12)) }
                    }
                }
            }
        }
    }

    // right: month grid
    Item {
        id: right
        x: panel.x + panel.width + root.pad * 0.6
        y: root.pad * 0.6
        width: root.width - x - root.pad * 0.6
        height: root.height - root.pad * 1.2

        readonly property real titlePx: Math.max(11, Math.min(height * 0.085, width * 0.06))

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            property real acc: 0
            onWheel: event => {
                acc += event.angleDelta.y;
                if (Math.abs(acc) >= 120) { root.shift(acc > 0 ? -1 : 1); acc = 0; }
            }
        }

        Row {
            id: title
            x: right.width / 14 - right.titlePx * 0.3
            y: right.titlePx * 0.25
            spacing: right.titlePx * 0.35
            Text {
                id: mName
                text: Qt.locale().standaloneMonthName(root.viewMonth, Locale.LongFormat)
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: right.titlePx
                font.weight: Font.Black
            }
            Text {
                text: root.viewYear
                color: ThemeBackend.mauve
                font.family: ThemeBackend.fontFamily
                font.pixelSize: right.titlePx
                font.weight: Font.Medium
                anchors.baseline: mName.baseline
            }
        }
        MouseArea {
            anchors.fill: title
            cursorShape: root.isCurrentMonth ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: root.goToday()
        }

        MonthGrid {
            id: cal
            y: title.y + title.height + right.titlePx * 0.2
            width: right.width
            height: right.height - y
            viewYear: root.viewYear
            viewMonth: root.viewMonth
            today: root.today
            weekStart: root.weekStart
        }
    }
}
