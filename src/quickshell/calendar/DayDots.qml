import QtQuick
import "../"

// Little dots under a day: one per calendar color with events (max 3) and a
// green one when Obsidian tasks are due that day.
Row {
    id: dots
    property var info: null               // Gcal.dayInfo(key): { events, tasks, colors[] }
    property real dot: 4
    property bool muted: false
    property color tint: "transparent"   // when set, every dot uses this color (e.g. on today's disc)
    readonly property bool tinted: tint.a > 0
    spacing: dot * 0.6

    Repeater {
        model: dots.info ? dots.info.colors : []
        delegate: Rectangle {
            required property var modelData
            width: dots.dot
            height: dots.dot
            radius: dots.dot / 2
            color: dots.tinted ? dots.tint : Gcal.colorFor(modelData)
            opacity: dots.muted ? 0.45 : 1
        }
    }
    Rectangle {
        visible: !!dots.info && dots.info.tasks > 0
        width: dots.dot
        height: dots.dot
        radius: dots.dot / 2
        color: dots.tinted ? dots.tint : ThemeBackend.green
        opacity: dots.muted ? 0.45 : 1
    }
}
