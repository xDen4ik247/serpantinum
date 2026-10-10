pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// My Vibe (music-smart) state for the bar island and the music panel.
// ~/.local/bin/music-smart (music-smart.service) writes ~/.local/state/music-smart/state.json
// whenever My Vibe, its style, the current track or its favourite flag change; we only watch
// that file (inotify, no polling).
Singleton {
    id: root

    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/music-smart/state.json"
    readonly property string cli: Quickshell.env("HOME") + "/.local/bin/music-smart"

    property bool active: false
    property string style: "default"          // the style My Vibe plays (or last played)
    property string styleLabel: "My Vibe"
    property var styles: []                   // [{id, label, desc, icon, n}]
    property string vibe: ""                  // old names, kept for older readers
    property string vibeLabel: ""
    property string why: ""
    property int queued: 0
    property string curFile: ""               // MPD's current song (file) and its stickers
    property bool fav: false
    property bool banned: false

    // A style picked in the bar but not started yet (wheel on the vibe chip).
    property string pendingStyle: ""
    readonly property string shownStyle: pendingStyle !== "" ? pendingStyle : (style || "default")

    // My Vibe only means something while the library (MPD) is the player the UI shows.
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
    // start My Vibe in the shown style; when that style already plays, music-smart re-rolls it
    function start() { run(["start", shownStyle]); }
    function startStyle(id) { pendingStyle = ""; run(["start", id || "default"]); }
    function reroll() { run(["reroll"]); }
    function stop() { Quickshell.execDetached([cli, "stop"]); }
    function toggleFav() {
        fav = !fav;                            // optimistic; state.json confirms it
        Quickshell.execDetached([cli, "fav", fav ? "on" : "off"]);
    }

    // ── styles ───────────────────────────────────────────────────────────────
    readonly property var fallbackStyles: [
        { id: "default", label: "My Vibe", icon: "vibe" }, { id: "favourites", label: "Favourites", icon: "star" },
        { id: "discover", label: "Discover", icon: "compass" }, { id: "reggae", label: "Reggae", icon: "reggae" }
    ]
    readonly property var styleList: styles.length ? styles : fallbackStyles
    // The picker skips styles with nothing to play (e.g. Favourites before the first star).
    readonly property var playableStyles: styleList.filter(s => s.n === undefined || s.n > 0)
    readonly property var glyphs: ({
        vibe: 0xf0674, star: 0xf04ce, compass: 0xf018b, reggae: 0xf1055, heavy: 0xf02c4, rock: 0xf02c4,
        alt: 0xf04e0, rap: 0xf036e, electronic: 0xf147d, pop: 0xf1056, chill: 0xf0594, custom: 0xf04f9
    })
    function info(id) {
        for (const s of styleList) if (s.id === id) return s;
        return { id: id, label: id === "default" ? "My Vibe" : id, icon: "custom" };
    }
    function labelOf(id) { return info(id).label || id; }
    function glyphOf(id) {
        const ic = info(id).icon || id;
        return String.fromCodePoint(glyphs[ic] !== undefined ? glyphs[ic] : glyphs.custom);
    }
    function nextStyleId(id, dir) {
        const l = playableStyles;
        if (!l.length) return id;
        let i = 0;
        for (let j = 0; j < l.length; j++) if (l[j].id === id) { i = j; break; }
        return l[(i + (dir < 0 ? l.length - 1 : 1)) % l.length].id;
    }

    function ingest(txt) {
        if (!txt || txt.trim() === "") return;   // torn read while the file is rewritten
        let st;
        try { st = JSON.parse(txt); } catch (e) { return; }
        if (st.active && (!active || st.style !== style || st.started !== lastStarted)) pendingStyle = "";
        lastStarted = st.started || 0;
        active = !!st.active;
        style = st.style || st.vibe || "default";
        styleLabel = st.styleLabel || st.vibeLabel || "My Vibe";
        vibe = st.vibe || "";
        vibeLabel = st.vibeLabel || "";
        if (st.styles && st.styles.length) styles = st.styles;
        why = st.active ? (st.why || "") : "";
        queued = st.queued || 0;
        curFile = st.cur || "";
        fav = !!st.fav;
        banned = !!st.banned;
        busy = false;
        busyTimer.stop();
    }
    property real lastStarted: 0

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
