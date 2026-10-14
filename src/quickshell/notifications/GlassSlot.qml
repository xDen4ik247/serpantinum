import QtQuick
import Quickshell

// One rounded blur rectangle behind a popup card (NotificationPopups.qml), in window
// coordinates: container + list position + the delegate's own slide/swipe offset.
Region {
    property var win: null
    property int idx: 0
    readonly property var d: win && idx < win.glassItems.length ? win.glassItems[idx] : null
    readonly property bool shown: !!d && d.glassShown
    // the delegate may be scaling in (add transition), around its centre
    x: shown ? Math.round(win.glassOrigin.x + d.x - win.glassScroll.x + d.glassDx + d.width * (1 - d.scale) / 2) : 0
    y: shown ? Math.round(win.glassOrigin.y + d.y - win.glassScroll.y + d.glassDy + d.height * (1 - d.scale) / 2) : 0
    width: shown ? Math.round(d.width * d.scale) : 0
    height: shown ? Math.round(d.height * d.scale) : 0
    radius: shown ? d.glassRadius : 0
}
