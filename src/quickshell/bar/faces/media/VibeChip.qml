import QtQuick
import Quickshell
import "../../../reusables"
import "../../../"

// The My Vibe chip of the bar's media island (MediaFace): style glyph + name.
// Click = start My Vibe in this style, or (while it plays) open the inline style picker;
// right-click = re-roll; middle-click = leave My Vibe; wheel = previous / next style.
Item {
    id: chip
    required property var face
    width: face.vibeW
    height: face.btnSize
    readonly property bool hot: chipMouse.containsMouse
    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: face.vibeLit ? Qt.alpha(ThemeBackend.mauve, chip.hot ? 0.40 : 0.28)
             : (face.smart.pendingStyle !== "" || face.previewStyle !== "") ? Qt.alpha(ThemeBackend.mauve, 0.16)
             : (chip.hot ? face.chipHoverColor : face.chipColor)
        Behavior on color { ColorAnimation { duration: 220 } }
    }
    Row {
        x: face.s(face.isCompact ? 8 : 10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: face.s(5)
        Text {
            width: face.vibeGlyphW
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
            text: face.smart.glyphOf(face.vibeStyle)
            font.family: ThemeBackend.iconFont
            font.pixelSize: Math.round(face.s(face.isCompact ? 11 : 13))
            color: face.vibeLit ? ThemeBackend.mauve : (chip.hot ? ThemeBackend.text : Qt.alpha(ThemeBackend.text, 0.8))
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(face.s(96), implicitWidth)
            elide: Text.ElideRight
            text: face.smart.labelOf(face.vibeStyle)
            font.family: ThemeBackend.fontFamily
            font.pixelSize: face.fontSize
            font.weight: Font.DemiBold
            color: face.vibeLit ? ThemeBackend.text : (chip.hot ? ThemeBackend.text : face.dimColor)
        }
    }
    scale: chipMouse.pressed ? 0.95 : 1
    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }
    opacity: face.smart.busy ? 0.6 : 1
    Behavior on opacity { NumberAnimation { duration: 180 } }
    MouseArea {
        id: chipMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) { face.smart.pendingStyle = ""; face.smart.stop(); }
            else if (mouse.button === Qt.RightButton) { if (face.smartOn) face.smart.reroll(); else face.smart.start(); }
            else if (face.smartOn && face.smart.pendingStyle === "") face.pickerOpen = !face.pickerOpen;
            else { face.cancelStyleSwitch(); face.pickerOpen = false; face.smart.start(); }
        }
    }
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        property real acc: 0
        onWheel: (event) => {
            acc += event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y * 2;
            if (Math.abs(acc) < 120) return;
            face.cycleStyle(acc > 0 ? -1 : 1);
            acc = 0;
        }
    }
}
