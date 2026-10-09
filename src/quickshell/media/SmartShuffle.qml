pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Smart shuffle state for the bar island and the music panel.
// ~/.local/bin/music-smart (music-smart.service) writes ~/.local/state/music-smart/state.json
// whenever smart mode or its current pick changes; we only watch that file (inotify, no polling).
Singleton {
    id: root

    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/music-smart/state.json"
    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/music-smart"

    property bool active: false
    property string vibe: ""
    property string vibeLabel: ""
    property string why: ""
    property int queued: 0

    // Smart mode only means something while the library (MPD) is the player the UI shows.
    // mpd-mpris: dbusName "org.mpris.MediaPlayer2.mpd", identity "MPD on <socket>".
    readonly property var player: MprisController.activePlayer
    readonly property string playerId: player ? ((player.dbusName || "") + " " + (player.identity || "")) : ""
    readonly property bool onLibrary: player === null || /(\.mpd\b|^ ?MPD\b)/i.test(playerId)
    readonly property bool shown: active && onLibrary

    // Between a click and the daemon's answer (usually < 0.3 s).
    property bool busy: false
    Timer { id: busyTimer; interval: 4000; onTriggered: root.busy = false }

    function run(args) {
        busy = true;
        busyTimer.restart();
        Quickshell.execDetached([cli].concat(args));
    }
    function start() { run(["start"]); }      // starts, or re-rolls when already on
    function reroll() { run(["reroll"]); }
    function stop() { Quickshell.execDetached([cli, "stop"]); }

    function ingest(txt) {
        if (!txt || txt.trim() === "") return;   // torn read while the file is rewritten
        let st;
        try { st = JSON.parse(txt); } catch (e) { return; }
        active = !!st.active;
        vibe = st.vibe || "";
        vibeLabel = st.vibeLabel || "";
        why = st.active ? (st.why || "") : "";
        queued = st.queued || 0;
        busy = false;
        busyTimer.stop();
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        blockLoading: false
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.ingest(text())
    }
}
