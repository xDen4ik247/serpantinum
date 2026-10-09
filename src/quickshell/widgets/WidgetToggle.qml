pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Global show/hide for desktop widgets (all monitors), driven over IPC:
//   serpantinum ipc call widgets toggle | show | hide | status
// Widgets fade out, then their layer surfaces are unmapped so they take no input.
Singleton {
    id: root

    property bool hidden: false
    property real fade: hidden ? 0 : 1
    Behavior on fade { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    readonly property bool windowsHidden: hidden && fade < 0.01

    IpcHandler {
        target: "widgets"

        function toggle(): string {
            root.hidden = !root.hidden;
            return root.hidden ? "hidden" : "shown";
        }
        function show(): string {
            root.hidden = false;
            return "shown";
        }
        function hide(): string {
            root.hidden = true;
            return "hidden";
        }
        function status(): string {
            return root.hidden ? "hidden" : "shown";
        }
    }
}
