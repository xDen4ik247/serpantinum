pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "../../"

Singleton {
    id: root

    readonly property var _playerWatch: {
        let players = Mpris.players.values;
        let states = [];
        for (let i = 0; i < players.length; i++) {
            states.push(players[i].isPlaying);
            states.push(players[i].canControl);
            states.push(players[i].busName);
        }
        return states;
    }

    readonly property MprisPlayer activePlayer: {
        let _ = _playerWatch;
        let players = Mpris.players.values.slice().sort((a, b) => (a.busName || "").localeCompare(b.busName || ""));
        let playing = players.find(p => p.isPlaying);
        if (playing) return playing;
        let controllable = players.find(p => p.canControl);
        if (controllable) return controllable;
        return players.length > 0 ? players[0] : null;
    }

    readonly property string activePlayerId: activePlayer ? (activePlayer.busName || activePlayer.identity || "") : ""
    readonly property bool hasActivePlayer: activePlayer !== null
    readonly property bool isPlaying: activePlayer ? activePlayer.isPlaying : false
    readonly property string trackTitle: activePlayer ? (activePlayer.trackTitle || "") : ""
    readonly property string trackArtist: activePlayer ? (activePlayer.trackArtist || "") : ""
    readonly property string currentArtUrl: {
        if (!activePlayer) return "";
        if (activePlayer.trackArtUrl && activePlayer.trackArtUrl !== "") return activePlayer.trackArtUrl;
        if (activePlayer.metadata) {
            let m = activePlayer.metadata;
            if (m["mpris:artUrl"]) return m["mpris:artUrl"];
            if (m["artUrl"]) return m["artUrl"];
            if (m["xesam:url"] && typeof m["xesam:url"] === "string" && (m["xesam:url"].startsWith("http") || m["xesam:url"].startsWith("file://"))) {
                if (m["xesam:url"].match(/\.(jpg|jpeg|png|webp)$/i)) return m["xesam:url"];
            }
        }
        return "";
    }
    property real livePosition: 0

    property string artUrl: ""
    property string blur: ""
    property string grad: ""
    property string textColor: "#cdd6f4"
    property string deviceIcon: "󰓃"
    property string deviceName: "Speaker"
    property bool fetchPending: false

    // ── Position ─────────────────────────────────────────────────────────────
    // Quickshell extrapolates `position` from the last value it read over D-Bus and re-reads it only
    // on its own events. mpd-mpris sends no Seeked on a track change, so after a song ended the
    // clock kept counting from the previous one (the bar's progress line sat at 100%, synced
    // lyrics ran ahead). The real position is read back (playerctl) on track / state changes and
    // when the clock runs past the end; `posFix` is the difference. Nothing polls.
    property real posFix: 0
    property real _rawLast: 0       // Quickshell's position at the last check, and when
    property real _rawLastT: 0
    property real _lastResync: 0

    // The position of any player, corrected for the active one. Use this instead of player.position.
    function posOf(p) {
        if (!p) return 0;
        let raw = p.position || 0;
        return Math.max(0, p === root.activePlayer ? raw + root.posFix : raw);
    }

    function refreshPosition() {
        let p = root.activePlayer;
        if (!p) { root.livePosition = 0; return; }
        let now = Date.now() / 1000;
        let raw = p.position || 0;
        // Quickshell rebased its clock (a seek, a fresh read): its value is right again
        let expected = root._rawLast + (p.isPlaying ? now - root._rawLastT : 0);
        if (root._rawLastT > 0 && Math.abs(raw - expected) > 1.5) {
            root.posFix = 0;
            resyncTimer.restart();
        }
        root._rawLast = raw;
        root._rawLastT = now;
        root.livePosition = Math.max(0, raw + root.posFix);
        // still past the end of the track: the clock is stale, read the real position
        if (p.length > 0 && root.livePosition > p.length + 1 && now - root._lastResync > 5) resyncTimer.restart();
    }

    function resyncPosition() {
        if (!root.activePlayer || posProc.running) return;
        root._lastResync = Date.now() / 1000;
        posProc.running = true;
    }

    Timer { id: resyncTimer; interval: 400; onTriggered: root.resyncPosition() }

    Process {
        id: posProc
        command: ["playerctl", "-a", "metadata", "--format", "{{status}}\t{{position}}\t{{xesam:title}}"]
        stdout: StdioCollector {
            onStreamFinished: {
                let p = root.activePlayer;
                if (!p) return;
                let want = p.trackTitle || "";
                let state = p.isPlaying ? "Playing" : (p.playbackState === MprisPlaybackState.Paused ? "Paused" : "Stopped");
                let best = null;
                for (let ln of this.text.split("\n")) {
                    let f = ln.split("\t");
                    if (f.length < 3 || f.slice(2).join("\t") !== want || f[1] === "") continue;
                    if (!best || (f[0] === state && best[0] !== state)) best = f;
                }
                if (!best) return;
                let real = Number(best[1]) / 1e6;
                if (isNaN(real)) return;
                p.positionChanged();
                let raw = p.position || 0;
                root.posFix = real - raw;
                root._rawLast = raw;
                root._rawLastT = Date.now() / 1000;
                root.livePosition = Math.max(0, raw + root.posFix);
            }
        }
    }

    onActivePlayerChanged: {
        root.posFix = 0;
        root._rawLastT = 0;
        root.refreshPosition();
        resyncTimer.restart();
        root.queueFetch();
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.hasActivePlayer && root.isPlaying
        onTriggered: {
            if (root.activePlayer) {
                root.activePlayer.positionChanged();
                root.refreshPosition();
            }
        }
    }

    Timer {
        id: fetchDebounceTimer
        interval: 60
        repeat: false
        onTriggered: root.fetchArt()
    }

    function queueFetch() {
        fetchDebounceTimer.restart();
    }

    Connections {
        target: root.activePlayer
        function onPositionChanged() {
            root.refreshPosition();
        }
        function onPostTrackChanged() {
            root.refreshPosition();
            resyncTimer.restart();
            root.queueFetch();
        }
        function onTrackArtUrlChanged() {
            root.queueFetch();
        }
        function onTrackTitleChanged() {
            root.queueFetch();
        }
        function onMetadataChanged() {
            root.queueFetch();
        }
        function onPlaybackStateChanged() {
            root.refreshPosition();
            resyncTimer.restart();
            root.queueFetch();
        }
    }

    Process {
        id: artFetchProc
        command: [
            "bash",
            Caching.qsDir + "/media/art_fetch.sh",
            root.activePlayerId,
            root.currentArtUrl,
            root.trackTitle,
            root.trackArtist
        ]
        onExited: {
            if (root.fetchPending) {
                root.fetchPending = false;
                artFetchProc.running = true;
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text.trim();
                if (txt !== "") {
                    try {
                        let d = JSON.parse(txt);
                        root.deviceIcon = d.deviceIcon || "󰓃";
                        root.deviceName = d.deviceName || "Speaker";

                        if (d.playerId !== root.activePlayerId || d.title !== root.trackTitle || d.artist !== root.trackArtist) {
                            return;
                        }

                        if (d.isPlaceholder === false && d.artUrl) {
                            root.artUrl = d.artUrl;
                            root.blur = d.blur || "";
                            root.grad = d.grad || "";
                            root.textColor = d.textColor || "#cdd6f4";
                        } else {
                            root.artUrl = "";
                            root.blur = "";
                            root.grad = d.grad || "";
                            root.textColor = d.textColor || "#cdd6f4";
                        }
                    } catch(e) {}
                }
            }
        }
    }

    function fetchArt() {
        if (!root.hasActivePlayer) {
            root.artUrl = "";
            root.blur = "";
            root.grad = "";
            root.textColor = "#cdd6f4";
            return;
        }
        if (artFetchProc.running) {
            root.fetchPending = true;
            return;
        }
        root.fetchPending = false;
        artFetchProc.running = true;
    }

    function forceArtRefresh() {
        root.fetchArt();
    }
}
