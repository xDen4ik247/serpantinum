# Packages added for the glass setup

Installed with pacman (official repos) during the overhaul, on top of a normal Serpantinum + niri install:

| Feature | Packages |
|---|---|
| Shell / terminal | `zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting starship zoxide eza bat` |
| Python | `uv` (tools: beancount, fava, kaggle; envs in `~/.venvs`) |
| Repo tooling | `github-cli` |
| Music | `mpd mpc mpd-mpris rmpc` |
| AI dictation (typing) | `wtype` |
| NPU | `intel-npu-driver level-zero-loader` |
| Input method | `fcitx5 fcitx5-mozc fcitx5-qt fcitx5-gtk` (were already installed) |

Built from source, not packaged:
- OpenVINO 2026.4 runtime in `~/.local/opt/openvino`
- llama.cpp with `-DGGML_OPENVINO=ON` in `~/.local/opt/llama.cpp-ov`
- Python envs: `~/.venvs/npu` (OCR/Whisper, py3.12), `~/.venvs/gcal`, `~/.venvs/default`

Models (downloaded, not in the repo): Qwen3.5-4B Q4_K_M (chat), Qwen3-Embedding-0.6B Q8_0 (notes),
Whisper small/base OpenVINO (dictation), PP-OCR + manga-ocr (Japanese OCR), JMdict (dictionary).

Root changes besides packages: the SDDM theme (`system/sddm/`, install with `pkexec sh system/sddm/install.sh`) and two power tweaks in `system/etc/` (PCI runtime PM udev rule, NMI watchdog off).
