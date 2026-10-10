# Packages added for the glass setup

`install/glass.sh` installs all of these (the exact list lives in `install/glass-modules/system.sh`; the opt-in
extras add their own build tools). Installed with pacman (official repos) on top of a normal Serpantinum + niri install:

| Feature | Packages |
|---|---|
| Shell / terminal | `zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting starship zoxide eza bat` |
| Python | `uv` (tools: beancount, fava, kaggle; envs in `~/.venvs`) |
| Repo tooling (maintainers only, not installed) | `github-cli` |
| Music | `mpd mpc mpd-mpris rmpc` |
| AI dictation (typing) | `wtype` |
| NPU | `intel-npu-driver level-zero-loader` |
| Input method | `fcitx5 fcitx5-mozc fcitx5-qt fcitx5-gtk fcitx5-configtool noto-fonts-cjk` |
| Helpers | `rsync patch jq inotify-tools imagemagick python-gobject python-numpy python-rich python-yaml python-pillow` |
| Calendar (`~/.venvs/gcal`) | `python-icalendar python-recurring-ical-events python-x-wr-timezone` |
| Login screen | `sddm qt6-declarative qt6-svg qt6-5compat` |
| Local LLM build (`--with llm`) | `cmake ninja gcc git opencl-headers opencl-clhpp ocl-icd intel-compute-runtime` |

Built or downloaded by the installer's opt-in extras, not packaged:
- OpenVINO 2026.4.1 runtime (Intel's archive) in `~/.local/opt/openvino`
- llama.cpp with `-DGGML_OPENVINO=ON` in `~/.local/opt/llama.cpp-ov`
- Python envs: `~/.venvs/npu` (OCR/Whisper, py3.12), `~/.venvs/gcal`, `~/.venvs/default`

Models (downloaded, not in the repo): Qwen3.5-4B Q4_K_M (chat), Qwen3-Embedding-0.6B Q8_0 (notes),
Whisper small/base OpenVINO (dictation), PP-OCR + manga-ocr (Japanese OCR), JMdict (dictionary).

Root changes besides packages: the SDDM theme (`system/sddm/`, install with `pkexec sh system/sddm/install.sh`) and two power tweaks in `system/etc/` (PCI runtime PM udev rule, NMI watchdog off).
