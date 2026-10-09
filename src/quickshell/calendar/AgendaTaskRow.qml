import QtQuick
import "../"

// One open Obsidian task (Tasks plugin 📅 / [due::] / due: / reminder (@date time)).
// Click opens the note that contains it via obsidian://open.
Item {
    id: row

    property var task: null
    property real fontPx: 13
    property bool compact: false

    readonly property color accent: task && task.overdue ? ThemeBackend.red : ThemeBackend.green

    implicitHeight: compact ? fontPx * 2.0 : fontPx * 2.5
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -row.fontPx * 0.45
        anchors.rightMargin: -row.fontPx * 0.45
        radius: row.fontPx * 0.7
        color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, ma.containsMouse ? 0.09 : 0)
        Behavior on color { ColorAnimation { duration: 180 } }
    }

    Text {
        id: box
        x: -row.fontPx * 0.08
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(row.task && row.task.inProgress ? 0xF0134 : 0xF0130)
        color: row.accent
        font.family: ThemeBackend.iconFont
        font.pixelSize: row.fontPx * 1.25
    }

    Text {
        id: when
        visible: text !== ""
        anchors.left: box.right
        anchors.leftMargin: row.fontPx * 0.45
        anchors.verticalCenter: parent.verticalCenter
        text: {
            if (!row.task) return "";
            if (row.task.overdue) {
                let d = Math.round((Gcal.dateOf(Gcal.todayKey) - Gcal.dateOf(row.task.due)) / 86400000);
                return d === 1 ? "yesterday" : d + "d late";
            }
            return row.task.time || "";
        }
        color: row.accent
        font.family: ThemeBackend.fontFamily
        font.pixelSize: row.fontPx * 0.8
        font.weight: Font.Bold
        font.features: { "tnum": 1 }
    }

    Text {
        id: label
        anchors.left: when.visible ? when.right : box.right
        anchors.leftMargin: row.fontPx * 0.45
        anchors.right: noteChip.visible ? noteChip.left : parent.right
        anchors.rightMargin: row.fontPx * 0.4
        anchors.verticalCenter: parent.verticalCenter
        text: row.task ? row.task.text : ""
        elide: Text.ElideRight
        color: ThemeBackend.text
        font.family: ThemeBackend.fontFamily
        font.pixelSize: row.fontPx
        font.weight: Font.Medium
    }

    // which note it lives in (hidden in compact rows)
    Rectangle {
        id: noteChip
        visible: !row.compact && !!row.task
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(noteText.implicitWidth + row.fontPx * 1.0 + (prio.visible ? prio.implicitWidth : 0), row.width * 0.38)
        height: row.fontPx * 1.55
        radius: height / 2
        color: Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.14)
        Row {
            anchors.centerIn: parent
            spacing: row.fontPx * 0.2
            Text {
                id: prio
                visible: !!row.task && row.task.priority > 0
                text: String.fromCodePoint(0xF0240)
                color: row.task && row.task.priority >= 2 ? ThemeBackend.red : ThemeBackend.peach
                font.family: ThemeBackend.iconFont
                font.pixelSize: row.fontPx * 0.8
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                id: noteText
                width: Math.min(implicitWidth, row.width * 0.38 - row.fontPx * 1.0 - (prio.visible ? prio.implicitWidth : 0))
                text: row.task ? (row.task.kind === "daily" ? "daily note" : row.task.note) : ""
                elide: Text.ElideRight
                color: ThemeBackend.mauve
                font.family: ThemeBackend.fontFamily
                font.pixelSize: row.fontPx * 0.72
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Gcal.openTask(row.task)
    }
}
