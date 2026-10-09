import QtQuick
import Quickshell

// One rounded blur rectangle for BackgroundEffect.blurRegion, following a
// glass island item from TopBar (coordinates are window-relative because the
// TopBar fills the bar window).
Region {
    property var target: null
    readonly property bool shown: !!target && target.islandShown === true

    x: shown ? Math.round(target.x) : 0
    y: shown ? Math.round(target.y + (target.islandOffsetY || 0)) : 0
    width: shown ? Math.round(target.width) : 0
    height: shown ? Math.round(target.height) : 0
    radius: shown ? Math.round(Math.min(target.height / 2, target.islandRadius || 0)) : 0
}
