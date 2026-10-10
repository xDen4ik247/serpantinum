// Glass Music: a Spotify-style library app for MPD, in the liquid-glass / Matugen look.
// A quickshell window (app-id glass-music, set by the launcher through QS_APP_ID) plus a
// Python backend (glassmusic.server) over stdin/stdout. Run: glass-music
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: shell

    // ------------------------------------------------------------------ theme
    QtObject {
        id: theme
        property color base: "#090f10"
        property color mantle: "#161d1d"
        property color crust: "#0e1415"
        property color text: "#dde4e4"
        property color sub0: "#bec8c9"
        property color sub1: "#899393"
        property color surface0: "#1a2121"
        property color surface1: "#252b2c"
        property color surface2: "#303636"
        property color accent: "#80d4db"      // Matugen primary
        property color accent2: "#b7c7ea"     // Matugen tertiary
        property color deep: "#004f54"        // Matugen primary container
        property color bad: "#ffb4ab"
        readonly property color onAccent: Qt.rgba(base.r * 0.9, base.g * 0.9, base.b * 0.9, 1)
        property string font: "Google Sans"
        property string icons: iconFont.status === FontLoader.Ready ? iconFont.name : "Symbols Nerd Font Mono"
        property int radius: 18
        function mix(a, b, t) { a = Qt.color(a); b = Qt.color(b); return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t) }
        function alpha(c, a) { const k = Qt.color(c); return Qt.rgba(k.r, k.g, k.b, a) }
    }

    FontLoader {
        id: iconFont
        source: "file:///usr/lib/kitty/fonts/SymbolsNerdFontMono-Regular.ttf"
    }

    FileView {
        id: colorsFile
        path: (Quickshell.env("HOME") || "") + "/.local/state/serpantinum/qs_colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const c = JSON.parse(text());
                const set = (k, v) => { if (v) theme[k] = v; };
                set("base", c.base); set("mantle", c.mantle); set("crust", c.crust); set("text", c.text);
                set("sub0", c.subtext0); set("sub1", c.subtext1); set("surface0", c.surface0);
                set("surface1", c.surface1); set("surface2", c.surface2); set("accent", c.blue);
                set("accent2", c.peach); set("deep", c.sapphire); set("bad", c.red);
            } catch (e) {}
        }
    }

    // ------------------------------------------------------------------ backend
    property string appDir: Quickshell.env("GLASS_MUSIC_APP") || (Quickshell.shellDir + "/..")

    Process {
        id: engine
        command: [Quickshell.env("GLASS_MUSIC_PYTHON") || "python3", "-m", "glassmusic.server"]
        workingDirectory: shell.appDir
        environment: ({ "PYTHONPATH": shell.appDir, "PYTHONUNBUFFERED": "1" })
        stdinEnabled: true
        running: true
        stdout: SplitParser {
            onRead: data => app.receive(data)
        }
        stderr: SplitParser {
            onRead: data => console.warn("backend:", data)
        }
        onExited: (code, status) => { if (!app.closing) app.fatal = "The music backend stopped (exit " + code + ")." }
        onStarted: app.send({ cmd: "hello" })
    }

    FileView {
        id: smartFile
        path: app.smartPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            let st;
            try { st = JSON.parse(text()); } catch (e) { return; }
            // a style picked here but not started yet gives way once My Vibe (re)starts anywhere
            if (st.active && (!app.smart.active || st.style !== app.smart.style || st.started !== app.smart.started)) app.vibeStyle = "";
            app.smart = st;
            if (st.styles && st.styles.length) app.styles = st.styles;
        }
    }
    // music-smart's style song lists (written only when the library / favourites / styles change)
    FileView {
        id: stylesFile
        path: app.smartStylesPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const d = JSON.parse(text());
                if (d.styles && d.styles.length) app.styles = d.styles;
                app.stylePools = d.pools || {};
            } catch (e) {}
        }
    }

    // ------------------------------------------------------------------ app state
    QtObject {
        id: app
        readonly property var th: theme
        property var rootItem: null
        property bool closing: false
        property string fatal: ""
        property bool ready: false

        // library
        property var lib: ({ tracks: [], albums: [], artists: [], moods: [] })
        property var albumByKey: ({})
        property var artistByName: ({})
        property var fileIdx: ({})
        property var thumbs: ({})
        property bool thumbsEnabled: true
        property var thumbAsk: []
        property var albumsByAdded: []

        // playback
        property var status: ({ state: "stop", elapsed: 0, duration: 0, volume: -1, random: false, repeat: false, single: false, pos: -1, id: -1, file: "" })
        property real posBase: 0
        property double posAt: 0
        property real position: 0
        property var queue: []
        property var likes: ({})
        property int likesCount: 0
        property var bans: ({})
        property var playlists: []
        property var home: ({ recent: [], most: [], counts: {} })
        property var smart: ({ active: false })
        property string smartPath: Quickshell.env("GLASS_MUSIC_SMART_STATE") || ((Quickshell.env("HOME") || "") + "/.local/state/music-smart/state.json")
        property string smartStylesPath: smartPath.replace(/state\.json$/, "styles.json")
        // My Vibe: the styles music-smart offers, their song lists, and the style picked here
        property var styles: []
        property var stylePools: ({})
        property string vibeStyle: ""
        readonly property string curStyle: vibeStyle || smart.style || "default"
        readonly property bool vibeOn: !!smart.active
        property bool openCurrentPending: Quickshell.env("GLASS_MUSIC_OPEN") === "current"
        readonly property bool playing: status.state === "play"
        readonly property int curIdx: status.file && fileIdx[status.file] !== undefined ? fileIdx[status.file] : -1
        readonly property var curTrack: curIdx >= 0 ? lib.tracks[curIdx] : null
        property var lyrics: ({ file: "", lines: [] })

        // navigation: {page, arg}; back/forward stacks remember scroll positions
        property var nav: ({ page: "home", arg: "" })
        property var backStack: []
        property var fwdStack: []
        property var pageItem: null
        property string rightPanel: ""          // "" | "queue" | "lyrics"
        property string selected: ""
        property string searchText: ""
        property var searchRes: null
        property int searchRid: 0
        property bool searchFocus: false

        signal toast(string icon, string text)
        signal focusSearch()

        function send(obj) { engine.write(JSON.stringify(obj) + "\n"); }

        function receive(line) {
            let m;
            try { m = JSON.parse(line); } catch (e) { console.warn("bad line", line.slice(0, 200)); return; }
            if (m.type === "library") setLibrary(m);
            else if (m.type === "status") {
                status = m;
                if (openCurrentPending && ready) { openCurrentPending = false; if (m.file) Qt.callLater(openCurrent); }
                posBase = m.elapsed; posAt = Date.now(); position = m.elapsed;
                if (m.file && lyrics.file !== m.file && rightPanel === "lyrics") send({ cmd: "lyrics", file: m.file });
            }
            else if (m.type === "queue") queue = m.items;
            else if (m.type === "likes") {
                const o = {};
                for (const f of m.files) o[f] = true;
                likes = o; likesCount = m.files.length;
                const b = {};
                for (const f of (m.bans || [])) b[f] = true;
                bans = b;
            }
            else if (m.type === "playlists") playlists = m.items;
            else if (m.type === "home") home = m;
            else if (m.type === "thumbs") {
                const t = Object.assign({}, thumbs);
                for (const k in m.items) t[k] = m.items[k];
                thumbs = t;
            }
            else if (m.type === "search") { if (m.rid === searchRid) searchRes = m; }
            else if (m.type === "lyrics") lyrics = m;
            else if (m.type === "toast") toast(m.icon, m.text);
            else if (m.type === "hello") { smartPath = m.smartState || smartPath; if (m.smartStyles) smartStylesPath = m.smartStyles; }
            else if (m.type === "error") console.warn("backend error:", m.error, m.trace || "");
            else if (m.type === "log") console.log("backend:", m.msg);
            else if (m.type === "mpd" && !m.ok) toast("warn", "MPD unavailable: " + m.error);
        }

        function setLibrary(m) {
            const L = m.lib;
            const ab = {}, ar = {}, fi = {};
            for (const a of L.albums) ab[a.k] = a;
            for (const a of L.artists) ar[a.n] = a;
            for (let i = 0; i < L.tracks.length; i++) fi[L.tracks[i].f] = i;
            albumByKey = ab; artistByName = ar; fileIdx = fi;
            thumbs = Object.assign({}, m.thumbs || {}, thumbs);
            albumsByAdded = L.albums.slice().sort((a, b) => (b.ad || "").localeCompare(a.ad || "")).map(a => a.k);
            lib = L;
            ready = true;
            if (openCurrentPending && status.file) { openCurrentPending = false; Qt.callLater(openCurrent); }
            console.log("library:", L.tracks.length, "tracks,", L.albums.length, "albums,", L.artists.length, "artists", m.cached ? "(cache)" : "(indexed)", m.ms + " ms");
        }

        // lazily ask the backend for thumbnails, batched per frame
        function requestThumb(k) {
            if (thumbAsk.indexOf(k) < 0) thumbAsk.push(k);
            if (thumbAsk.length === 1) Qt.callLater(flushThumbs);
        }
        function flushThumbs() {
            if (!thumbAsk.length) return;
            send({ cmd: "thumbs", keys: thumbAsk });
            thumbAsk = [];
        }
        function colorFor(k) {
            const t = thumbs[k];
            if (t && t.c) return t.c;
            let h = 0;
            for (let i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) % 360;
            return Qt.hsla(h / 360, 0.45, 0.5, 1);
        }

        // ---- helpers
        function fmt(sec) {
            sec = Math.max(0, Math.round(sec || 0));
            const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, s = sec % 60;
            return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s;
        }
        function fmtLong(sec) {
            sec = Math.round(sec || 0);
            const h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60;
            return h ? h + " hr " + m + " min" : m + " min " + (sec % 60) + " sec";
        }
        function n(k, one, many) { return k + " " + (k === 1 ? one : (many || one + "s")); }
        function track(i) { return i >= 0 ? lib.tracks[i] : null; }
        function filesOf(idxs) { return idxs.map(i => lib.tracks[i].f); }
        function idxOfFiles(files) { const out = []; for (const f of files) { const i = fileIdx[f]; if (i !== undefined) out.push(i); } return out; }
        function isLiked(i) { return i >= 0 && !!likes[lib.tracks[i].f]; }
        function greeting() {
            const h = new Date().getHours();
            return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
        }
        function plays(i) { return i >= 0 ? (home.counts[lib.tracks[i].f] || 0) : 0; }
        function artistTop(name, n) {
            const a = artistByName[name];
            if (!a) return [];
            let idx = [];
            for (const k of a.al) idx = idx.concat(albumByKey[k].tr);
            const c = home.counts;
            idx.sort((x, y) => {
                const px = (c[lib.tracks[x].f] || 0) + (likes[lib.tracks[x].f] ? 0.5 : 0);
                const py = (c[lib.tracks[y].f] || 0) + (likes[lib.tracks[y].f] ? 0.5 : 0);
                return py - px;
            });
            return idx.slice(0, n);
        }
        function artistTracks(name) {
            const a = artistByName[name];
            if (!a) return [];
            let idx = [];
            for (const k of a.al) idx = idx.concat(albumByKey[k].tr);
            return idx;
        }
        function moodTracks(mood) {
            const out = [];
            for (let i = 0; i < lib.tracks.length; i++) if (lib.tracks[i].m === mood) out.push(i);
            return out;
        }
        function moodLabel(m) { for (const x of lib.moods) if (x.id === m) return x.label; return m; }
        function moodColor(m) {
            const hues = { heavy: 0.0, rock: 0.07, alt: 0.78, rap: 0.58, electronic: 0.52, pop: 0.9, chill: 0.42 };
            return Qt.hsla(hues[m] !== undefined ? hues[m] : 0.6, 0.55, 0.5, 1);
        }
        function likedTracks() { return idxOfFiles(Object.keys(likes)); }      // favourites

        // ---- My Vibe styles (music-smart)
        readonly property var fallbackStyles: [
            { id: "default", label: "My Vibe", desc: "What you play most, with room for surprises", icon: "vibe" },
            { id: "favourites", label: "Favourites", desc: "Only the songs you starred", icon: "star" },
            { id: "discover", label: "Discover", desc: "Songs and artists you rarely play", icon: "compass" },
            { id: "reggae", label: "Reggae", desc: "Roots, dub, dancehall, ska and rocksteady", icon: "reggae" }
        ]
        function styleList() {
            if (styles.length) return styles;
            const out = fallbackStyles.slice();
            for (const m of lib.moods) out.push({ id: m.id, label: m.label, desc: m.n + " songs", icon: m.id, n: m.n });
            return out;
        }
        function styleInfo(id) {
            for (const s of styleList()) if (s.id === id) return s;
            return { id: id, label: id === "default" ? "My Vibe" : id, desc: "", icon: "vibe" };
        }
        function styleLabel(id) { return styleInfo(id).label; }
        function styleIcon(id) {
            const ic = styleInfo(id).icon || id;
            return ["vibe", "star", "compass", "reggae", "heavy", "rock", "alt", "rap", "electronic", "pop", "chill"].indexOf(ic) >= 0 ? ic : "tag";
        }
        function styleColor(id) {
            const hues = { favourites: 0.12, discover: 0.48, reggae: 0.31, heavy: 0.0, rock: 0.07, alt: 0.78, rap: 0.58, electronic: 0.52, pop: 0.9, chill: 0.42 };
            if (id === "default") return th.accent;
            if (hues[id] !== undefined) return Qt.hsla(hues[id], 0.55, 0.52, 1);
            let h = 0;
            for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 360;
            return Qt.hsla(h / 360, 0.5, 0.52, 1);
        }
        function styleTracks(id) {
            if (stylePools[id]) return idxOfFiles(stylePools[id]);
            if (id === "favourites") return likedTracks();
            return moodTracks(id);
        }
        // play button: the style that is on → play / pause; anything else → start it
        function vibePlay(id) {
            id = id || curStyle;
            if (smart.active && smart.style === id && status.file) { toggle(); return; }
            vibeStyle = id;
            send({ cmd: "smart", action: "start", style: id });
        }
        function vibePick(id) {
            if (smart.active && smart.style !== id) send({ cmd: "smart", action: "start", style: id });
            vibeStyle = id;
        }
        function vibeReroll() { send({ cmd: "smart", action: "reroll" }); }
        function vibeStop() { send({ cmd: "smart", action: "stop" }); }
        function openCurrent() {
            if (curIdx >= 0) { goTrackAlbum(curIdx); if (rightPanel === "") rightPanel = "queue"; }
            else go("home");
        }

        // ---- navigation
        function go(page, arg) {
            if (nav.page === page && (nav.arg || "") === (arg || "")) { if (pageItem && pageItem.scrollTop) pageItem.scrollTop(); return; }
            const cur = Object.assign({}, nav, { y: pageItem && pageItem.flick ? pageItem.flick.contentY : 0 });
            backStack = backStack.concat([cur]).slice(-50);
            fwdStack = [];
            nav = { page: page, arg: arg || "" };
        }
        function back() {
            if (!backStack.length) return;
            const cur = Object.assign({}, nav, { y: pageItem && pageItem.flick ? pageItem.flick.contentY : 0 });
            fwdStack = fwdStack.concat([cur]);
            const b = backStack[backStack.length - 1];
            backStack = backStack.slice(0, -1);
            nav = b;
        }
        function forward() {
            if (!fwdStack.length) return;
            const cur = Object.assign({}, nav, { y: pageItem && pageItem.flick ? pageItem.flick.contentY : 0 });
            backStack = backStack.concat([cur]);
            const f = fwdStack[fwdStack.length - 1];
            fwdStack = fwdStack.slice(0, -1);
            nav = f;
        }
        function goAlbum(k) { if (albumByKey[k]) go("album", k); }
        function goArtist(n) { if (artistByName[n]) go("artist", n); }
        function goTrackAlbum(i) { if (i >= 0) goAlbum(lib.tracks[i].k); }
        function goTrackArtist(i) { if (i >= 0) goArtist(lib.tracks[i].p); }

        // ---- search
        function search(q) {
            searchText = q;
            searchRid += 1;
            if (q.trim() === "") { searchRes = null; return; }
            send({ cmd: "search", q: q, rid: searchRid });
        }

        // ---- playback commands
        function playContext(idxs, at, shuffle) { send({ cmd: "play", files: filesOf(idxs), index: at || 0, shuffle: !!shuffle }); }
        function playFiles(files, at, shuffle) { send({ cmd: "play", files: files, index: at || 0, shuffle: !!shuffle }); }
        function playAlbum(k, shuffle) { const a = albumByKey[k]; if (a) playContext(a.tr, 0, shuffle); }
        function playArtist(n, shuffle) { const t = artistTracks(n); if (t.length) playContext(t, 0, shuffle); }
        function addNext(idxs) { send({ cmd: "add", files: filesOf(idxs), next: true }); }
        function addQueue(idxs) { send({ cmd: "add", files: filesOf(idxs), next: false }); }
        function toggle() { send({ cmd: "toggle" }); }
        function next() { send({ cmd: "next" }); }
        function prev() {
            // Spotify: restart the track if more than 3 s in
            if (position > 3) send({ cmd: "seek", pos: 0 }); else send({ cmd: "previous" });
        }
        function seek(p) { position = p; posBase = p; posAt = Date.now(); send({ cmd: "seek", pos: p }); }
        function setVolume(v) { send({ cmd: "volume", value: Math.round(v) }); }
        function toggleShuffle() { send({ cmd: "random", on: !status.random }); }
        function cycleRepeat() {
            const mode = !status.repeat ? "all" : (status.single ? "off" : "one");
            send({ cmd: "repeat", mode: mode });
        }
        function toggleLike(i) { if (i >= 0) send({ cmd: "fav", file: lib.tracks[i].f, on: !isLiked(i) }); }
        function smartToggle() { send({ cmd: "smart", action: smart.active ? "stop" : "start" }); }
        function smartStart(reroll) { send({ cmd: "smart", action: reroll && smart.active ? "reroll" : "start", style: smart.active ? "" : curStyle }); }
        function mix(mood) { vibePlay(mood); }
        function togglePanel(p) {
            rightPanel = rightPanel === p ? "" : p;
            if (rightPanel === "lyrics" && status.file && lyrics.file !== status.file) send({ cmd: "lyrics", file: status.file });
        }
        function openTerminalPlayer() { send({ cmd: "spawn", what: "terminal" }); }

        // ---- context menu
        function trackMenu(i, ctxIdxs, at, item, mx, my) {
            if (i < 0) return;
            const t = lib.tracks[i];
            const items = [
                { icon: "play", text: "Play", act: () => playContext(ctxIdxs && ctxIdxs.length ? ctxIdxs : [i], ctxIdxs && ctxIdxs.length ? at : 0) },
                { icon: "next-up", text: "Play next", act: () => addNext([i]) },
                { icon: "playlist-plus", text: "Add to queue", act: () => addQueue([i]) },
                { sep: true },
                { icon: isLiked(i) ? "star" : "star-outline", text: isLiked(i) ? "Remove from Favourites" : "Add to Favourites", act: () => toggleLike(i) },
                { icon: "playlist", text: "Add to playlist", sub: "playlists", files: [t.f] },
                { icon: bans[t.f] ? "vibe" : "cancel", text: bans[t.f] ? "Allow in My Vibe again" : "Never play in My Vibe", act: () => send({ cmd: "ban", file: t.f, on: !bans[t.f] }) },
                { sep: true },
                { icon: "artist", text: "Go to artist", act: () => goArtist(t.p) },
                { icon: "album", text: "Go to album", act: () => goAlbum(t.k) }
            ];
            menu.open(items, item, mx, my);
        }
        function albumMenu(k, item, mx, my) {
            const a = albumByKey[k];
            if (!a) return;
            menu.open([
                { icon: "play", text: "Play", act: () => playAlbum(k, false) },
                { icon: "shuffle", text: "Shuffle play", act: () => playAlbum(k, true) },
                { icon: "next-up", text: "Play next", act: () => addNext(a.tr) },
                { icon: "playlist-plus", text: "Add to queue", act: () => addQueue(a.tr) },
                { icon: "playlist", text: "Add to playlist", sub: "playlists", files: filesOf(a.tr) },
                { sep: true },
                { icon: "artist", text: "Go to artist", act: () => goArtist(a.p) },
                { icon: "album", text: "Open album", act: () => goAlbum(k) }
            ], item, mx, my);
        }
        function queueMenu(entry, item, mx, my) {
            const i = entry.i;
            const items = [
                { icon: "play", text: "Play", act: () => send({ cmd: "playid", id: entry.id }) },
                { icon: "playlist-remove", text: "Remove from queue", act: () => send({ cmd: "deleteid", id: entry.id }) }
            ];
            if (i >= 0) items.push({ sep: true },
                { icon: isLiked(i) ? "star" : "star-outline", text: isLiked(i) ? "Remove from Favourites" : "Add to Favourites", act: () => toggleLike(i) },
                { icon: "artist", text: "Go to artist", act: () => goTrackArtist(i) },
                { icon: "album", text: "Go to album", act: () => goTrackAlbum(i) });
            menu.open(items, item, mx, my);
        }
        function appMenu(item, mx, my) {
            menu.open([
                { icon: "console", text: "Open terminal player", act: () => openTerminalPlayer() },
                { icon: "playlist-plus", text: "Save queue as playlist", sub: "savequeue" },
                { icon: "refresh", text: "Rescan library", act: () => { send({ cmd: "rescan" }); toast("refresh", "Rescanning ~/Music…"); } }
            ], item, mx, my);
        }

        function close() {
            closing = true;
            send({ cmd: "quit" });
            Qt.callLater(Qt.quit);
        }
    }

    // position: extrapolated locally between MPD events; ticks only while playing
    Timer {
        interval: app.rightPanel === "lyrics" ? 200 : 500
        repeat: true
        running: app.playing
        onTriggered: app.position = Math.min(app.status.duration || 1e9, app.posBase + (Date.now() - app.posAt) / 1000)
    }

    // ------------------------------------------------------------------ window
    FloatingWindow {
        id: win
        title: Quickshell.env("GLASS_MUSIC_TITLE") || "Glass Music"
        implicitWidth: parseInt(Quickshell.env("GM_W") || "1280")
        implicitHeight: parseInt(Quickshell.env("GM_H") || "820")
        minimumSize: Qt.size(640, 520)
        color: "transparent"
        onClosed: app.close()

        Item {
            id: root
            anchors.fill: parent
            focus: true
            Component.onCompleted: app.rootItem = root

            Keys.onPressed: event => {
                const k = event.key, ctrl = event.modifiers & Qt.ControlModifier, alt = event.modifiers & Qt.AltModifier;
                if (k === Qt.Key_Space && !ctrl) { app.toggle(); event.accepted = true; }
                else if (ctrl && k === Qt.Key_F) { app.go("search"); app.focusSearch(); event.accepted = true; }
                else if (ctrl && k === Qt.Key_L) { app.togglePanel("lyrics"); event.accepted = true; }
                else if (ctrl && k === Qt.Key_Q && (event.modifiers & Qt.ShiftModifier)) { app.togglePanel("queue"); event.accepted = true; }
                else if (ctrl && k === Qt.Key_Right) { app.next(); event.accepted = true; }
                else if (ctrl && k === Qt.Key_Left) { app.prev(); event.accepted = true; }
                else if (ctrl && k === Qt.Key_Up) { app.setVolume(Math.min(100, app.status.volume + 5)); event.accepted = true; }
                else if (ctrl && k === Qt.Key_Down) { app.setVolume(Math.max(0, app.status.volume - 5)); event.accepted = true; }
                else if (ctrl && k === Qt.Key_S) { app.toggleShuffle(); event.accepted = true; }
                else if (ctrl && k === Qt.Key_R) { app.cycleRepeat(); event.accepted = true; }
                else if (alt && k === Qt.Key_Left || k === Qt.Key_Back) { app.back(); event.accepted = true; }
                else if (alt && k === Qt.Key_Right || k === Qt.Key_Forward) { app.forward(); event.accepted = true; }
                else if (k === Qt.Key_Escape) { if (menu.shown) menu.close(); event.accepted = true; }
            }

            // window tint: niri blurs what is behind (rules-music.kdl), we add the Matugen wash
            Rectangle {
                anchors.fill: parent
                radius: 20
                gradient: Gradient {
                    GradientStop { position: 0.0; color: theme.alpha(theme.mix(theme.base, theme.deep, 0.30), 0.60) }
                    GradientStop { position: 1.0; color: theme.alpha(theme.base, 0.70) }
                }
            }
            // a soft wash of the playing album's colour, like Spotify's tinted views
            Rectangle {
                anchors.fill: parent
                radius: 20
                opacity: app.curTrack ? 0.20 : 0
                Behavior on opacity { NumberAnimation { duration: 600 } }
                gradient: Gradient {
                    GradientStop { position: 0.0; color: app.curTrack ? app.colorFor(app.curTrack.k) : "transparent"; Behavior on color { ColorAnimation { duration: 900; easing.type: Easing.OutCubic } } }
                    GradientStop { position: 0.55; color: "transparent" }
                }
            }

            readonly property real gap: 8
            readonly property bool narrow: width < 1100
            readonly property real sideW: narrow ? 72 : Math.round(Math.min(300, Math.max(240, width * 0.2)))
            readonly property real rightW: app.rightPanel === "" ? 0 : Math.round(Math.min(380, Math.max(300, width * 0.26)))

            Sidebar {
                id: sidebar
                app: app
                collapsed: root.narrow
                x: root.gap; y: root.gap
                width: root.sideW
                height: bar.y - root.gap * 2
                Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            }

            MainPane {
                id: mainPane
                app: app
                x: sidebar.x + sidebar.width + root.gap
                y: root.gap
                width: rightPanel.x - x - (rightPanel.width > 1 ? root.gap : 0)
                height: bar.y - root.gap * 2
            }

            RightPanel {
                id: rightPanel
                app: app
                y: root.gap
                width: root.rightW
                x: root.width - root.gap - width
                height: bar.y - root.gap * 2
                Behavior on width { NumberAnimation { duration: 460; easing.type: Easing.OutQuint } }
            }

            NowPlayingBar {
                id: bar
                app: app
                x: root.gap
                width: root.width - root.gap * 2
                height: 84
                y: root.height - height - root.gap
            }

            Toasts {
                id: toasts
                app: app
                anchors { horizontalCenter: parent.horizontalCenter; bottom: bar.top; bottomMargin: 16 }
            }

            ContextMenu {
                id: menu
                app: app
                anchors.fill: parent
            }

            Text {
                anchors.centerIn: parent
                visible: app.fatal !== ""
                text: app.fatal
                color: theme.bad
                font.family: theme.font
                font.pixelSize: 18
            }
        }
    }

    // test hook: drive the window without keyboard focus (screenshots / checks)
    IpcHandler {
        target: "glassmusic"
        function go(page: string, arg: string): void { app.go(page, arg) }
        function panel(name: string): void { app.rightPanel = name === "none" ? "" : name; if (name === "lyrics" && app.status.file) app.send({ cmd: "lyrics", file: app.status.file }); }
        function search(q: string): void { app.go("search"); app.search(q) }
        function back(): void { app.back() }
        function toggle(): void { app.toggle() }
        function playAlbum(k: string): void { app.playAlbum(k, false) }
        function scroll(y: real): void { if (app.pageItem && app.pageItem.flick) app.pageItem.flick.contentY = y }
        function menuDemo(): void { if (app.lib.tracks.length) app.trackMenu(app.curIdx >= 0 ? app.curIdx : 0, [], 0, app.rootItem, app.rootItem.width / 2, app.rootItem.height / 3) }
        function closeMenu(): void { menu.close() }
        function state(): string { return JSON.stringify({ page: app.nav.page, arg: app.nav.arg, tracks: app.lib.tracks.length, status: app.status.state, file: app.status.file, queue: app.queue.length, panel: app.rightPanel, thumbs: Object.keys(app.thumbs).length, style: app.curStyle, vibeOn: app.vibeOn, styles: app.styleList().length, favs: app.likesCount }) }
        // open the album of the playing track (bar island click-through: glass-music --current)
        function openCurrent(): void { if (app.ready) app.openCurrent(); else app.openCurrentPending = true }
        function vibe(style: string): void { app.vibePlay(style) }
        function pickStyle(style: string): void { app.vibeStyle = style }
        function quit(): void { app.close() }
        // renders only this window's own content to a PNG (no screen capture, no clipboard)
        function shot(path: string): void { app.rootItem.grabToImage(r => r.saveToFile(path)) }
        function hover(x: real, y: real): void { }
    }
}
