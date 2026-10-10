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
install/        glass.sh + glass-modules/ (the glass installer, next to upstream's install.sh + modules/)
docs/glass/     this file
tools/          sync-from-system.sh (machine -> repo), check-secrets.sh (run before every commit)
```

The niri config keeps upstream's copies in `~/.config/niri/config/` (never edited) and your own layer in
`~/.config/niri/user/`, with one `binds-<feature>.kdl` / `rules-<feature>.kdl` per feature. `serp-tweaks`
re-applies the Serpantinum source edits after upstream updates.

## Install

On Arch Linux (or an Arch-based distribution), as your normal user:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)"
```

Options go after a `_`, for example a dry run that only shows what would change:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xDen4ik247/serpantinum/glass/install/glass.sh)" _ --dry-run
```

From a clone of the `glass` branch it is just `install/glass.sh [options]`. The installer:

1. **Base:** installs (or updates) plain upstream Serpantinum for niri, using upstream's own installer modules at the
   commit this branch is built on. Upstream's `serpantinum update` and its version file keep working as usual.
2. **Root, one password prompt:** the extra packages (pacman, official repos only), the glass login screen
   (`system/sddm/`) and, on laptops, the battery tweaks (`system/etc/`).
3. **Dotfiles:** everything in `home/`, with `/home/user` rendered to your home. Files that were there before are
   backed up to `~/.config/serp-glass_backup/<date>/` first.
4. **Shell:** the glass changes to Serpantinum, written as `serp-tweaks` patches and applied, so
   `serp-tweaks sync` (it runs at every login) re-applies them after an upstream update.
5. **Apps:** Glass Music, and JP Quiz with `--with jpquiz`.
6. **Services:** the systemd user units for what is installed. The LLM, notes and greeter units stay on-demand
   (socket/path activated).

To update later, run the same command again. Re-running it is safe: it only fixes what differs. A file you edited after the install is never overwritten. The new
version is written next to it as `<file>.glass-new`, and `--force` replaces it after a backup instead.
Your music, notes, calendar links and quiz progress are never touched. Everything the installer writes is recorded in
`~/.local/state/serp-glass/` (a manifest and the logs).

| Option | What it does |
|---|---|
| `--dry-run` (`-n`), `--diff` | show what would change (with diffs); change nothing |
| `--yes` (`-y`) | don't ask |
| `--with LIST` | opt-in extras (below), remembered for later runs |
| `--no-sddm`, `--power auto\|yes\|no`, `--no-shell-rc` | skip the login screen / battery tweaks / zsh files |
| `--vault NAME` | your Obsidian vault in `~/Obsidian` (default: the only one there) |
| `--skip-base`, `--reinstall-base`, `--upstream latest`, `--upstream-menu` | control the upstream base install |
| `--wallpapers few\|full\|none` | upstream's wallpaper pack (default: a few) |
| `--status` | show what is installed |
| `--uninstall [--purge]` | remove the glass layer (upstream Serpantinum stays); `--purge` also deletes the downloaded models |

**Extras (`--with`).** The default install downloads no models. Without them the desktop works, and the AI keys
simply do nothing.

| Extra | What you get | Cost |
|---|---|---|
| `llm` | local LLM on the Intel Arc GPU (`ai`, calendar capture, OCR translation): OpenVINO 2026.4.1 + llama.cpp built locally + Qwen3.5-4B | ~3.2 GB download, 10–20 min build, ~9 GB RAM while running |
| `notes` | Obsidian AI notes (Mod+N), needs `llm` | 640 MB |
| `dictation` | Whisper dictation (Mod+Z) on the NPU | ~1.2 GB |
| `ocr` | Japanese OCR (Mod+X) on the NPU, includes `jmdict` | ~1 GB kept, ~2.5 GB temporary |
| `jmdict` | JMdict dictionary for OCR and Anki cards | 22 MB |
| `jpquiz` | JP Quiz (Mod+J), its question bank is built locally | ~80 MB download, a few minutes |
| `all` | all of the above | |

All downloads are pinned to exact upstream revisions and checked against their sha256.

After the first install, log out and pick the niri session (or reboot). Then press **Mod+Shift+/** to see every
shortcut, and run `gcal-setup` to add a Google Calendar (its secret address stays in `~/.config/gcal-sync/`).

## Keeping it up to date

```bash
git fetch upstream && git rebase upstream/master        # on branch glass
tools/sync-from-system.sh && tools/check-secrets.sh && git add -p
```

After a rebase, set `G_UPSTREAM_BASE` in `install/glass.sh` to the new upstream commit, so the installer builds the
patches against it.

## Credits

[Serpantinum](https://github.com/ilyamiro/serpantinum) by ilyamiro and contributors (AGPL-3.0, see `LICENSE.md`).
The glass layer, tools and apps were built with Claude Code.
