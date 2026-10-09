import QtQuick
import "../../../"
import "../../../calendar"

// Month grid (weekday header + 6×7 days) with today highlighted. Animates on month change.
// Days with Google Calendar events / Obsidian tasks get colored dots (Gcal singleton);
// clicking a day opens that day's agenda panel.
Item {
    id: grid

    property int viewYear: new Date().getFullYear()
    property int viewMonth: new Date().getMonth()
    property date today: new Date()
    property int weekStart: 1            // 1 = Monday, 0 = Sunday
    property int slideDir: 1

    readonly property real headerH: height / 7.2
    readonly property real cellW: width / 7
    readonly property real cellH: (height - headerH) / 6
    readonly property real fontPx: Math.max(9, Math.min(cellH * 0.42, cellW * 0.36))

    readonly property var cells: {
        let first = new Date(viewYear, viewMonth, 1);
        let lead = (first.getDay() - weekStart + 7) % 7;
        let out = [];
        for (let i = 0; i < 42; i++) {
            let d = new Date(viewYear, viewMonth, 1 - lead + i);
            out.push({
                key: Qt.formatDate(d, "yyyy-MM-dd"),
                day: d.getDate(),
                inMonth: d.getMonth() === viewMonth,
                weekend: d.getDay() === 0 || d.getDay() === 6,
                isToday: d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate()
            });
        }
        return out;
    }

    function weekdayName(i) {
        let dow = (weekStart + i) % 7;
        let n = Qt.locale().dayName(dow, Locale.ShortFormat);
        return n.substring(0, 2);
    }

    // header: weekday initials
    Row {
        id: header
        width: parent.width
        height: grid.headerH
        Repeater {
            model: 7
            delegate: Text {
                width: grid.cellW
                height: header.height
                text: grid.weekdayName(index)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: ((grid.weekStart + index) % 7 === 0 || (grid.weekStart + index) % 7 === 6)
                    ? Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.85)
                    : ThemeBackend.subtext1
                font.family: ThemeBackend.fontFamily
                font.pixelSize: grid.fontPx * 0.82
                font.weight: Font.Bold
            }
        }
    }

    Item {
        id: days
        y: grid.headerH
        width: parent.width
        height: grid.height - grid.headerH
        clip: false

        property real slide: 0
        Grid {
            x: days.slide
            columns: 7
            Repeater {
                model: 42
                delegate: Item {
                    id: cell
                    readonly property var c: grid.cells[index]
                    readonly property var info: { let r = Gcal.revision; return Gcal.dayInfo(c.key); }
                    readonly property real disc: Math.min(width, height) * 0.9
                    width: grid.cellW
                    height: grid.cellH

                    Rectangle {
                        anchors.centerIn: parent
                        width: cell.disc
                        height: width
                        radius: width / 2
                        color: c.isToday ? ThemeBackend.mauve : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, dayMa.containsMouse ? 0.12 : 0)
                        visible: c.isToday || dayMa.containsMouse
                        scale: dayMa.pressed ? 0.9 : 1
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
                    }
                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: cell.info ? -cell.disc * 0.08 : 0
                        text: c.day
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: grid.fontPx
                        font.weight: c.isToday ? Font.Black : (c.inMonth ? Font.DemiBold : Font.Normal)
                        font.features: { "tnum": 1 }
                        color: c.isToday ? ThemeBackend.base
                            : (c.weekend ? ThemeBackend.peach : ThemeBackend.text)
                        opacity: c.isToday ? 1 : (c.inMonth ? (c.weekend ? 0.9 : 1) : 0.28)
                    }
                    DayDots {
                        visible: !!cell.info
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height / 2 + cell.disc * 0.2
                        info: cell.info
                        dot: Math.max(3, Math.round(cell.disc * 0.1))
                        muted: !c.inMonth
                        tint: c.isToday ? ThemeBackend.base : "transparent"
                        opacity: c.isToday ? 0.8 : 1
                    }
                    MouseArea {
                        id: dayMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Gcal.openDay(c.key)
                    }
                }
            }
        }
    }

    onViewMonthChanged: monthAnim.restart()
    ParallelAnimation {
        id: monthAnim
        NumberAnimation { target: days; property: "slide"; from: grid.slideDir * grid.cellW * 0.6; to: 0; duration: 420; easing.type: Easing.OutCubic }
        NumberAnimation { target: days; property: "opacity"; from: 0; to: 1; duration: 320; easing.type: Easing.OutCubic }
    }
}
