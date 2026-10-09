import QtQuick
import "../"
import Quickshell
import "../../"
import "../../../"
import "../../../calendar"

// "Calendar" month variant — month title, navigation chevrons, month grid.
// Scroll or use the chevrons to browse; click the title to jump back to today.
// Days carry event/task dots; when the widget is tall (≥ 330 px) a "next up" footer
// lists the next two events/tasks (Gcal singleton).
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 220
    property real minHeight: 220
    property real maxWidth: 900
    property real maxHeight: 900
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

    readonly property real pad: Math.max(14, Math.min(width, height) * 0.07)
    readonly property real titlePx: Math.max(14, Math.min(width * 0.085, height * 0.075))

    Rectangle {
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        property real acc: 0
        onWheel: event => {
            acc += event.angleDelta.y;
            if (Math.abs(acc) >= 120) { root.shift(acc > 0 ? -1 : 1); acc = 0; }
        }
    }

    Item {
        id: header
        x: root.pad
        y: root.pad
        width: root.width - root.pad * 2
        height: root.titlePx * 1.7

        Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.titlePx * 0.35

            Text {
                id: monthLabel
                text: Qt.locale().standaloneMonthName(root.viewMonth, Locale.LongFormat)
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: root.titlePx
                font.weight: Font.Black
            }
            Text {
                text: root.viewYear
                color: ThemeBackend.mauve
                font.family: ThemeBackend.fontFamily
                font.pixelSize: root.titlePx
                font.weight: Font.Medium
                anchors.baseline: monthLabel.baseline
            }
        }
        MouseArea {
            anchors.fill: titleRow
            cursorShape: root.isCurrentMonth ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: root.goToday()
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.titlePx * 0.2

            Repeater {
                model: [-1, 1]
                delegate: Rectangle {
                    width: root.titlePx * 1.55
                    height: width
                    radius: width / 2
                    color: navMa.containsMouse ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.18) : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.05)
                    Behavior on color { ColorAnimation { duration: 180 } }
                    scale: navMa.pressed ? 0.88 : 1
                    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(modelData < 0 ? 0xF0141 : 0xF0142)
                        color: navMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext0
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: parent.width * 0.62
                    }
                    MouseArea {
                        id: navMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.shift(modelData)
                    }
                }
            }
        }
    }

    readonly property real fs: Math.max(11, Math.min(14, width * 0.042))
    readonly property var nextRows: {
        let r = Gcal.revision, n = Gcal.nowMs;
        return Gcal.upcoming(0).filter(x => x.kind === "event" || x.kind === "task").slice(0, 2);
    }
    readonly property bool showNext: height >= 330 && nextRows.length > 0

    MonthGrid {
        id: cal
        x: root.pad * 0.6
        y: header.y + header.height + root.pad * 0.4
        width: root.width - root.pad * 1.2
        height: root.height - y - root.pad * 0.6 - (root.showNext ? nextBox.height + root.pad * 0.5 : 0)
        viewYear: root.viewYear
        viewMonth: root.viewMonth
        today: root.today
        weekStart: root.weekStart
    }

    Rectangle {
        id: nextBox
        visible: root.showNext
        x: root.pad * 0.6
        width: root.width - root.pad * 1.2
        y: root.height - height - root.pad * 0.6
        height: nextCol.height + root.fs * 0.6
        radius: Math.max(8, ThemeBackend.borderRadius - root.pad * 0.6)
        color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.12)
        Column {
            id: nextCol
            x: root.fs * 0.7
            width: parent.width - root.fs * 1.4
            anchors.verticalCenter: parent.verticalCenter
            Repeater {
                model: root.nextRows
                delegate: Loader {
                    required property var modelData
                    width: nextCol.width
                    sourceComponent: modelData.kind === "event" ? nEv : nTk
                    Component { id: nEv; AgendaEventRow { ev: modelData.ev; fontPx: root.fs; compact: true; dayKey: modelData.ev.startDate } }
                    Component { id: nTk; AgendaTaskRow { task: modelData.task; fontPx: root.fs; compact: true } }
                }
            }
        }
    }
}
