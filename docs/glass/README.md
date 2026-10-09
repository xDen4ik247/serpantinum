# Serpantinum — liquid glass edition

A fork of [ilyamiro/serpantinum](https://github.com/ilyamiro/serpantinum) (v2.2.4, niri) tuned for an Intel
Core Ultra 200V ("Lunar Lake") laptop with an Arc 140V GPU and an NPU. It turns the shell into **liquid glass**
(translucent tints over niri blur, hairline rims, soft shadows) and adds a local-AI and study layer that runs
entirely on the machine.

Screenshots: coming later.

## What's in the fork

| Area | What it does | Where |
|---|---|---|
| Top bar | floating glass islands, dynamic workspace dots, fcitx5 EN/RU/JP pill, no window title | `src/quickshell/bar/` |
| Desktop widgets | vitals rings (CPU/GPU/NPU/RAM/temp/battery), calendar, favorites, network/disk graph | `src/quickshell/widgets/` |
| Agenda | Google Calendar (secret iCal link) + Obsidian tasks, 8-day and month views, AI capture | `src/quickshell/calendar/`, `home/.local/share/gcal-sync/` |
| Music | MPD + mpd-mpris, panel with synced lyrics + EQ, smart shuffle (Mod+S), Spotify-style Glass Music app (Mod+Shift+M) | `src/quickshell/media/`, `apps/glass-music/`, `home/.local/bin/music-*` |
| Shortcuts | searchable glass cheat sheet generated from the niri config (Mod+Shift+/) | `src/quickshell/cheatsheet/`, `niri-keys` |
| Local LLM | llama.cpp (OpenVINO backend) serving a 4B model on the Arc GPU, started on demand; `ai` CLI | `npu-llm.socket`, `npu-llm-server.service` |
| Japanese | OCR on the NPU (Mod+X), reading helper, Anki mining, adaptive quiz app (Mod+J) | `home/.local/share/npu-ocr/`, `apps/jp-quiz/` |
| AI tools | Whisper dictation (Mod+Z), assistant (Mod+A), clipboard actions, Obsidian AI notes (Mod+N) | `home/.local/share/{aifeat,ai-notes}/` |
| Login | liquid-glass SDDM greeter that follows the wallpaper and palette | `system/sddm/` |
| Input | fcitx5 as one self-restarting service, Mozc starts in hiragana, Mod+Alt+I repairs it | `home/.config/fcitx5/`, `ime-fix` |
| Power | `power-mode auto|perf|save`, lazy widgets, on-demand LLM, runtime PM | `power-mode`, `system/etc/` |

## Repository layout

```text
src/            Serpantinum itself (upstream + the glass changes, one commit per feature)
home/           dotfiles relative to $HOME (paths written as /home/user — replace with your own)
system/         root-owned parts: SDDM theme + installer, udev/sysctl power tweaks, package list
apps/           JP Quiz and Glass Music
docs/glass/     this file
tools/          sync-from-system.sh (machine -> repo), check-secrets.sh (run before every commit)
```

The niri config keeps upstream's copies in `~/.config/niri/config/` (never edited) and your own layer in
`~/.config/niri/user/`, with one `binds-<feature>.kdl` / `rules-<feature>.kdl` per feature. `serp-tweaks`
re-applies the Serpantinum source edits after upstream updates.

## Using it

1. Install Serpantinum normally (upstream installer, niri), then the packages in `system/packages.md`.
2. Shell: copy `src/` over `~/.local/share/serpantinum/src/`, then `serpantinum reload`.
3. Dotfiles: copy what you want from `home/` into `$HOME`, replacing `/home/user` with your home directory:
   ```bash
   grep -rl /home/user home | xargs sed -i "s|/home/user|$HOME|g"
   systemctl --user daemon-reload
   systemctl --user enable --now fcitx5 mpd mpd-mpris music-smart npu-llm.socket npu-ocr aidict power-mode \
       gcal-sync.timer anki-queue-flush.timer ai-notes-watch greeter-sync.path
   niri validate
   ```
4. Models are not included (size): a 4B GGUF chat model, an embedding GGUF, Whisper (OpenVINO) and the OCR models.
5. Login screen: `pkexec sh system/sddm/install.sh` (revert: `pkexec rm /etc/sddm.conf.d/20-serp-glass.conf`).
6. Google Calendar: run `gcal-setup` and paste your calendar's secret iCal address (stored outside the repo).

## Keeping it up to date

```bash
git fetch upstream && git rebase upstream/master        # on branch glass
tools/sync-from-system.sh && tools/check-secrets.sh && git add -p
```

## Credits

[Serpantinum](https://github.com/ilyamiro/serpantinum) by ilyamiro and contributors (AGPL-3.0, see `LICENSE.md`).
The glass layer, tools and apps were built with Claude Code.
