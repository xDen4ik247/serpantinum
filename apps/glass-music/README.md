# Glass Music

A Spotify-style library app for the MPD music library, in the liquid-glass / Matugen look of
the Serpantinum desktop. Quickshell window (app-id `glass-music`) + a small Python backend.

- `glass-music` (Mod+Shift+M) opens it, or focuses it if it is already open. Mod+Q closes it;
  playback keeps running in MPD.
- Keys: Space play/pause · Ctrl+F search · Ctrl+L lyrics · Ctrl+Shift+Q queue · Ctrl+←/→ prev/next ·
  Ctrl+↑/↓ volume · Ctrl+S shuffle · Ctrl+R repeat · Alt+←/→ back/forward.
- Double-click a song: play it with its album / artist / list as the queue. Right-click: play next,
  add to queue, like, add to playlist, never-in-smart-shuffle, go to artist / album.
- ♥ = MPD sticker `love`, "Never in smart shuffle" = sticker `ban` (the ones music-smart weighs).
- Menu (⋯, top right): Open terminal player (rmpc), Save queue as playlist, Rescan library.

Layout: `qml/` (shell.qml = state + window; one file per component/page), `glassmusic/`
(server.py = JSON-lines protocol, library.py = index + cache, search.py, thumbs.py, mpdclient.py).
Caches: `~/.cache/glass-music/{library.json,thumbs/}` (rebuilt when MPD's db_update changes).

Install / update: `./install.sh`. Tests: `python -m unittest discover -s tests -t .`

Environment overrides (for tests): `GLASS_MUSIC_MPD` (socket or host:port), `GLASS_MUSIC_CACHE`,
`GLASS_MUSIC_HISTORY`, `GLASS_MUSIC_SMART_STATE`, `GLASS_MUSIC_SMART_ENV` (JSON env for music-smart),
`GLASS_MUSIC_TITLE`, `GM_W`/`GM_H` (initial size). IPC: `quickshell ipc -p <app>/qml call glassmusic …`
(`go`, `panel`, `search`, `state`, `shot <png>` renders only this window).
