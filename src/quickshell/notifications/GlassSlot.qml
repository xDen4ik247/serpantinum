import QtQuick
import Quickshell

// One rounded blur rectangle behind a popup card (NotificationPopups.qml), in window
// coordinates: container + list position + the delegate's own slide/swipe offset.
Region {
    property var win: null
    property int idx: 0
    readonly property var d: win && idx < win.glassItems.length ? win.glassItems[idx] : null
    readonly property bool shown: !!d && d.glassShown
    x: shown ? Math.round(win.glassOrigin.x + d.x - win.glassScroll.x + d.glassDx) : 0
    y: shown ? Math.round(win.glassOrigin.y + d.y - win.glassScroll.y + d.glassDy) : 0
    width: shown ? Math.round(d.width) : 0
    height: shown ? Math.round(d.height) : 0
    radius: shown ? d.glassRadius : 0
}
