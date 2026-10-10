# Glass Music

A Spotify-style library app for the MPD music library, in the liquid-glass / Matugen look of
the Serpantinum desktop. Quickshell window (app-id `glass-music`) + a small Python backend.

- `glass-music` (Mod+Shift+M) opens it, or focuses it if it is already open (via the shared
  `niri-focus-or-run` helper in `~/.local/bin`; without it a second window opens). Mod+Q closes it;
  playback keeps running in MPD. `glass-music --current` opens (or focuses) it on the album of
  the playing track.
- **My Vibe** (Home): one big play button for an endless smart queue from `music-smart`, plus a
  style picker: My Vibe (what you play most, from the play history), Favourites, Discover (rarely
  played), Reggae (from genre tags) and the moods. Styles top themselves up as you listen; Mod+S
  re-rolls within the style. Local overrides / extra styles: `~/.config/glass-music/styles.json`
  (see `music-smart --help`).
- Keys: Space play/pause · Ctrl+F search · Ctrl+L lyrics · Ctrl+Shift+Q queue · Ctrl+←/→ prev/next ·
  Ctrl+↑/↓ volume · Ctrl+S shuffle · Ctrl+R repeat · Alt+←/→ back/forward.
- Double-click a song: play it with its album / artist / list as the queue. Right-click: play next,
  add to queue, favourite, add to playlist, never play in My Vibe, go to artist / album.
- The whole library counts as liked. ☆ Favourite = MPD sticker `favourite` (a strong boost in My
  Vibe and its own style; old `love` stickers are migrated by music-smart); "Never play in My Vibe"
  = sticker `ban`.
- Menu (⋯, top right): Open terminal player (rmpc), Save queue as playlist, Rescan library.

Layout: `qml/` (shell.qml = state + window; one file per component/page), `glassmusic/`
(server.py = JSON-lines protocol, library.py = index + cache, search.py, thumbs.py, mpdclient.py).
Caches: `~/.cache/glass-music/{library.json,thumbs/}` (rebuilt when MPD's db_update changes).

Install / update: `./install.sh`. Tests: `python -m unittest discover -s tests -t .`

Environment overrides (for tests): `GLASS_MUSIC_MPD` (socket or host:port), `GLASS_MUSIC_CACHE`,
`GLASS_MUSIC_HISTORY`, `GLASS_MUSIC_SMART_STATE`, `GLASS_MUSIC_SMART_ENV` (JSON env for music-smart),
`GLASS_MUSIC_TITLE`, `GM_W`/`GM_H` (initial size). IPC: `quickshell ipc -p <app>/qml call glassmusic …`
(`go`, `panel`, `search`, `state`, `vibe <style>`, `pickStyle <style>`, `openCurrent`,
`shot <png>` renders only this window).
