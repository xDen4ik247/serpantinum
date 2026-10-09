import QtQuick
import Quickshell
import Quickshell.Wayland
import "../"
import "../bar"

// Mod+Shift+O: liquid-glass smart capture. Type a rough note; a live preview of
// chips (kind, date, time, duration, place, repeat, priority, tags, reminder) shows
// what will be created and can be tweaked before Enter. Tasks go to Obsidian
// (Tasks-plugin syntax), events to Google Calendar (if write access is set up)
// or to the local calendar + an Obsidian event-task.
PanelWindow {
    id: win

    color: "transparent"
    visible: shown
    property bool shown: false

    anchors.top: true
    margins.top: 150
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 760
    implicitHeight: 420
    WlrLayershell.namespace: "qs-capture"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !Gcal.passive && Gcal.captureOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region { item: card }
    BackgroundEffect.blurRegion: Region {
        x: Math.round(card.x)
        y: Math.round(card.y)
        width: Math.round(card.width)
        height: Math.round(card.height)
        radius: card.radius
    }

    property real t: 0
    property bool done: false
    property bool ok: true
    property string message: ""

    Connections {
        target: Gcal
        function onCaptureOpenChanged() {
            if (Gcal.captureOpen) {
                win.done = false;
                win.message = "";
                box.input.text = "";
                win.shown = true;
                closeAnim.stop();
                openAnim.restart();
                box.input.forceActiveFocus();
            } else {
                openAnim.stop();
                closeAnim.restart();
            }
        }
        function onCaptured(ok, message) {
            if (!Gcal.captureOpen) return;
            win.ok = ok;
            win.message = message;
            win.done = ok;
            if (ok) closeTimer.restart();
        }
    }
    NumberAnimation { id: openAnim; target: win; property: "t"; to: 1; duration: 480; easing.type: Easing.OutQuint }
    SequentialAnimation {
        id: closeAnim
        NumberAnimation { target: win; property: "t"; to: 0; duration: 200; easing.type: Easing.InCubic }
        ScriptAction { script: win.shown = false }
    }
    Timer { id: closeTimer; interval: 1300; onTriggered: Gcal.captureOpen = false }

    Item {
        id: card
        readonly property real radius: 22
        width: 700
        height: win.done ? 64 : Math.max(64, box.implicitHeight + 24 + (errLine.visible ? 22 : 0))
        Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
        x: Math.round((win.width - width) / 2)
        y: Math.round(20 - (1 - win.t) * 14)
        opacity: win.t
        scale: 0.96 + 0.04 * win.t
        transformOrigin: Item.Top

        GlassPill {
            anchors.fill: parent
            radius: card.radius
            tintAlpha: 0.66
            lit: true
        }

        Rectangle {
            id: iconBubble
            x: 12
            y: 12
            width: 40
            height: 40
            radius: 20
            color: win.done ? Qt.rgba(ThemeBackend.green.r, ThemeBackend.green.g, ThemeBackend.green.b, 0.28)
                            : Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.24)
            Behavior on color { ColorAnimation { duration: 250 } }
            Text {
                anchors.centerIn: parent
                text: String.fromCodePoint(win.done ? 0xF012C : (Gcal.captureBusy ? 0xF0450 : (Gcal.preview && Gcal.preview.kind === "event" ? 0xF00F3 : 0xF039D)))
                color: win.done ? ThemeBackend.green : ThemeBackend.mauve
                font.family: ThemeBackend.iconFont
                font.pixelSize: 20
                scale: win.done ? 1.15 : 1
                Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutBack } }
            }
        }

        CaptureBox {
            id: box
            visible: !win.done
            x: iconBubble.x + iconBubble.width + 14
            y: 12
            width: card.width - x - 18
            large: true
            focus: true
            onEscaped: Gcal.captureOpen = false
        }

        Text {
            visible: win.done
            anchors.left: iconBubble.right
            anchors.leftMargin: 14
            anchors.right: parent.right
            anchors.rightMargin: 18
            y: 32 - height / 2
            text: win.message
            elide: Text.ElideRight
            color: ThemeBackend.text
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 17
            font.weight: Font.DemiBold
        }

        // error line
        Text {
            id: errLine
            visible: win.message !== "" && !win.done
            x: box.x
            y: card.height - 30
            width: card.width - x - 16
            text: win.message
            color: ThemeBackend.red
            elide: Text.ElideRight
            font.family: ThemeBackend.fontFamily
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }
}
