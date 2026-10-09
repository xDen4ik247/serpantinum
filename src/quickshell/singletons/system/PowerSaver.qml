pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// Battery-aware policy for pollers and data animations (added by the battery worker).
// The mode comes from ~/.local/state/power-mode/mode, written by `power-mode auto|perf|save`:
//   auto -> save while on battery, perf on AC (default when the file is missing)
//   perf -> never save, save -> always save
// Consumers only stretch their sampling intervals; the look and the animations stay the same.
Singleton {
    id: root

    property string mode: "auto"
    readonly property bool onBattery: UPower.onBattery
    readonly property bool saving: mode === "save" || (mode !== "perf" && onBattery)

    // Scale a poll interval (ms) for the current policy.
    function interval(acMs, batteryMs) {
        return saving ? batteryMs : acMs;
    }

    FileView {
        id: modeFile
        path: Quickshell.env("HOME") + "/.local/state/power-mode/mode"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            let m = (modeFile.text() || "").trim();
            root.mode = (m === "perf" || m === "save") ? m : "auto";
        }
        onLoadFailed: root.mode = "auto"
    }
}
