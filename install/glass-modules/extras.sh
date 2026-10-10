#!/usr/bin/env bash
# Extras: the heavy, opt-in parts. Nothing here runs unless asked for with --with (the choice is remembered,
# so a later plain re-run keeps them up to date). Without them the desktop works and the features that need
# them stay quiet: their units are never enabled, their keys do nothing.
#
# Every download is pinned (exact upstream revision; sha256 for every large file) and resumable.
# Builds and downloads are cached in ~/.cache/serp-glass-build (safe to delete afterwards).

G_EXTRAS=(llm notes dictation ocr jmdict jpquiz)
declare -A G_EXTRA_INFO=(
    [llm]="local LLM on the Intel Arc GPU: OpenVINO 2026.4.1 runtime + llama.cpp built here + Qwen3.5-4B (Q4_K_M) — download ~3.2 GB, disk ~3.5 GB, build ~10–20 min; needs ~9 GB free RAM while it runs"
    [notes]="Obsidian AI notes (Mod+N): Qwen3-Embedding-0.6B — download 640 MB (needs llm)"
    [dictation]="Whisper dictation (Mod+Z): Python env ~/.venvs/npu (~700 MB) + Whisper small for OpenVINO (480 MB)"
    [ocr]="Japanese OCR (Mod+X): ~/.venvs/npu (~700 MB) + PP-OCRv6 (30 MB) + manga-ocr exported here (temporary ~2.5 GB of tools and weights, 215 MB kept) + JMdict"
    [jmdict]="JMdict dictionary for OCR and Anki cards — download 22 MB, 55 MB on disk"
    [jpquiz]="JP Quiz app (Mod+J): builds its question bank from Tatoeba/JMdict — download ~80 MB, ~5–10 min"
)
declare -A G_EXTRA_NEEDS=([notes]=llm [ocr]=jmdict)

# ---- pinned sources
G_OV_VER=2026.4.1
G_OV_URL="https://storage.openvinotoolkit.org/repositories/openvino/packages/2026.4.1/linux/openvino_toolkit_ubuntu24_2026.4.1.22982.07f9c262b05_x86_64.tgz"
G_OV_SHA=772ce52d9b0aa375c77d391fccea71450d889c98b9af197bb8f05167a9dabd87
G_OV_DIR="$HOME/.local/opt/openvino_$G_OV_VER"
G_OV_LINK="$HOME/.local/opt/openvino"            # the units' LD_LIBRARY_PATH points here
G_LLAMA_URL="https://github.com/ggml-org/llama.cpp"
G_LLAMA_REV=f498f864fbc0472004ee1c3616c1188c68eb157f
G_LLAMA_SRC="$HOME/.local/src/llama.cpp"
G_LLAMA_DIR="$HOME/.local/opt/llama.cpp-ov"
G_CHAT=(bartowski/Qwen_Qwen3.5-4B-GGUF 4168f45a16a1290d65a4ec0fa312ae917a4c15d6 Qwen_Qwen3.5-4B-Q4_K_M.gguf)
G_CHAT_DIR="$HOME/.local/share/npu-ai/models"
G_EMB=(Qwen/Qwen3-Embedding-0.6B-GGUF 370f27d7550e0def9b39c1f16d3fbaa13aa67728 Qwen3-Embedding-0.6B-Q8_0.gguf)
G_EMB_DIR="$HOME/.local/share/ai-notes/models"
G_WHISPER=(OpenVINO/whisper-small-fp16-ov 2410d022171ca8a97343182f88eec8807a324db9)
G_WHISPER_DIR="$HOME/.local/share/npu-ai/whisper/whisper-small-fp16-ov"
G_OCR_DET=(PaddlePaddle/PP-OCRv6_small_det_onnx 28fe5895c24fd108c19eb3e8479f4ab385fbfc62)
G_OCR_REC=(PaddlePaddle/PP-OCRv6_small_rec_onnx b8f84f0b80c529de40b4fbb3544b84fa7233a513)
G_MOCR=(kha-white/manga-ocr-base aa6573bd10b0d446cbf622e29c3e084914df9741)
G_OCR_DIR="$HOME/.local/share/npu-ocr/models"
G_JMDICT_URL="http://ftp.edrdg.org/pub/Nihongo/JMdict.gz"   # EDRDG, CC BY-SA 4.0; changes daily, so not pinned
G_JMDICT_DB="$HOME/.local/share/npu-ocr/jmdict.db"
G_NPU_VENV="$HOME/.venvs/npu"
G_OV_PIP=("openvino==2026.4.1" "openvino-genai==2026.4.1.0" "openvino-tokenizers==2026.4.1.0" numpy)
G_OCR_PIP=(opencv-python-headless pyclipper fugashi unidic-lite pyyaml pillow)
G_FETCH="$G_ROOT/install/glass-tools/fetch.py"

g_vault_dir() { printf '%s/Obsidian/%s' "$HOME" "${G_VAULT:-Vault}"; }
g_has_intel_gpu() { lspci -nn 2>/dev/null | grep -iE 'VGA|Display|3D' | grep -qi 'Intel'; }

g_npu_venv_has() {   # python modules (directories or single-file modules) present in ~/.venvs/npu
    local m
    [ -x "$G_NPU_VENV/bin/python" ] || return 1
    for m; do
        compgen -G "$G_NPU_VENV/lib/python3*/site-packages/$m" >/dev/null ||
            compgen -G "$G_NPU_VENV/lib/python3*/site-packages/$m.*" >/dev/null || return 1
    done
}

g_extra_ready() {
    case "$1" in
        llm)       [ -x "$G_LLAMA_DIR/bin/llama-server" ] && [ -f "$G_OV_LINK/setupvars.sh" ] && [ -s "$G_CHAT_DIR/${G_CHAT[2]}" ] ;;
        notes)     [ -x "$G_LLAMA_DIR/bin/llama-server" ] && [ -s "$G_EMB_DIR/${G_EMB[2]}" ] ;;
        dictation) g_npu_venv_has openvino openvino_genai && [ -f "$G_WHISPER_DIR/openvino_encoder_model.xml" ] ;;
        ocr)       g_npu_venv_has openvino cv2 pyclipper fugashi unidic_lite yaml &&
                   [ -f "$G_OCR_DIR/ppocrv6_det_small/inference.onnx" ] && [ -f "$G_OCR_DIR/ppocrv6_rec_small/inference.onnx" ] &&
                   [ -f "$G_OCR_DIR/manga_ocr_base/ov/encoder.xml" ] && [ -f "$G_OCR_DIR/manga_ocr_base/ov/decoder_step_b1_t128.xml" ] ;;
        jmdict)    [ -s "$G_JMDICT_DB" ] ;;
        jpquiz)    [ -s "$HOME/.local/share/jp-quiz/content.db" ] && [ -d "$HOME/.local/share/jp-quiz/app" ] ;;
        *) return 1 ;;
    esac
}

# Expand --with: dependencies, and "all".
g_extras_resolve() {
    local e changed=1
    if [ "${G_WITH[all]:-0}" = 1 ]; then for e in "${G_EXTRAS[@]}"; do G_WITH[$e]=1; done; unset 'G_WITH[all]'; fi
    while [ $changed = 1 ]; do
        changed=0
        for e in "${!G_WITH[@]}"; do
            [ "${G_WITH[$e]}" = 1 ] || continue
            local need="${G_EXTRA_NEEDS[$e]:-}"
            if [ -n "$need" ] && [ "${G_WITH[$need]:-0}" != 1 ]; then G_WITH[$need]=1; changed=1; fi
        done
    done
}

g_extras_selected() { local e; for e in "${G_EXTRAS[@]}"; do [ "${G_WITH[$e]:-0}" = 1 ] && printf '%s ' "$e"; done; }

# Packages the selected extras need (added to the one root step).
g_extras_pkgs() {
    [ "${G_WITH[llm]:-0}" = 1 ] && ! g_extra_ready llm &&
        printf '%s\n' cmake ninja gcc git opencl-headers opencl-clhpp ocl-icd intel-compute-runtime
    if [ "${G_WITH[dictation]:-0}" = 1 ] || [ "${G_WITH[ocr]:-0}" = 1 ]; then
        g_has_npu && printf '%s\n' intel-npu-driver level-zero-loader
    fi
    [ "${G_WITH[jpquiz]:-0}" = 1 ] && printf '%s\n' unzip
    return 0
}

g_fetch() { python3 -I "$G_FETCH" "$@"; }

g_extras_install() {
    local e any=0
    for e in llm notes dictation jmdict ocr; do
        [ "${G_WITH[$e]:-0}" = 1 ] || continue
        any=1
        if g_extra_ready "$e"; then g_ok "$e: ready"; continue; fi
        if g_is_dry; then g_dry "$e: ${G_EXTRA_INFO[$e]}"; continue; fi
        g_info "$e: ${G_EXTRA_INFO[$e]}"
        if "g_extra_$e"; then g_ok "$e: installed"; else g_warn "$e: not finished (re-run the installer to resume; downloads continue where they stopped)"; fi
    done
    [ $any = 1 ] || g_detail "no extras selected (see --with)"
    return 0
}

# ---------------------------------------------------------------- llm
g_extra_llm() {
    local mem_gb; mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
    [ "${mem_gb:-0}" -ge 15 ] || g_warn "llm: only ${mem_gb} GB RAM — the 4B model needs ~9 GB while it runs"
    g_has_intel_gpu || g_warn "llm: no Intel GPU found — npu-llm-server.service runs on GPU; set GGML_OPENVINO_DEVICE=CPU there (slow)"
    g_openvino_runtime && g_llama_build && g_fetch hf "${G_CHAT[@]:0:2}" "$G_CHAT_DIR" "${G_CHAT[2]}"
}

g_openvino_runtime() {
    if [ -f "$G_OV_DIR/setupvars.sh" ]; then g_detail "ok        OpenVINO $G_OV_VER"
    else
        local tgz="$G_BUILD/dl/$(basename "$G_OV_URL")"
        g_fetch url "$G_OV_URL" "$tgz" "$G_OV_SHA" || return 1
        rm -rf "$G_OV_DIR.tmp" && mkdir -p "$G_OV_DIR.tmp" &&
            tar -xzf "$tgz" -C "$G_OV_DIR.tmp" --strip-components=1 && mv "$G_OV_DIR.tmp" "$G_OV_DIR" ||
            { g_err "can't unpack $tgz"; return 1; }
        rm -f "$tgz"
        g_info "OpenVINO $G_OV_VER runtime in ${G_OV_DIR/#$HOME/\~}"
    fi
    if [ -L "$G_OV_LINK" ] || [ ! -e "$G_OV_LINK" ]; then
        ln -sfn "$(basename "$G_OV_DIR")" "$G_OV_LINK"
    elif [ ! -f "$G_OV_LINK/setupvars.sh" ]; then
        g_err "${G_OV_LINK/#$HOME/\~} exists and is not an OpenVINO install — move it away and re-run"; return 1
    fi
}

g_llama_build() {
    if [ -x "$G_LLAMA_DIR/bin/llama-server" ]; then g_detail "ok        llama.cpp"; return 0; fi
    local b="$G_LLAMA_SRC/build/ReleaseOV" log="$G_BUILD/llama-build.log" jobs
    jobs=$(nproc); [ "$jobs" -gt 8 ] && jobs=8
    mkdir -p "$G_BUILD" "$(dirname "$G_LLAMA_SRC")"
    if [ ! -d "$G_LLAMA_SRC/.git" ]; then
        git init -q "$G_LLAMA_SRC" && git -C "$G_LLAMA_SRC" remote add origin "$G_LLAMA_URL" || return 1
    fi
    if ! git -C "$G_LLAMA_SRC" cat-file -e "$G_LLAMA_REV^{commit}" 2>/dev/null; then
        g_info "llama.cpp: fetching ${G_LLAMA_REV:0:7}"
        git -C "$G_LLAMA_SRC" fetch -q --depth 1 origin "$G_LLAMA_REV" || { g_err "git fetch llama.cpp failed"; return 1; }
    fi
    git -C "$G_LLAMA_SRC" -c advice.detachedHead=false checkout -q --force "$G_LLAMA_REV" || return 1
    g_info "llama.cpp: building with the OpenVINO backend ($jobs jobs; log: ${log/#$HOME/\~})"
    local ovlib="$G_OV_LINK/runtime/lib/intel64" tbblib="$G_OV_LINK/runtime/3rdparty/tbb/lib"
    if ! (
        set +u; source "$G_OV_LINK/setupvars.sh" >/dev/null; set -e
        cmake -S "$G_LLAMA_SRC" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_OPENVINO=ON \
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
            -DCMAKE_INSTALL_PREFIX="$G_LLAMA_DIR" -DCMAKE_INSTALL_RPATH="\$ORIGIN/../lib;$ovlib;$tbblib"
        nice -n 10 cmake --build "$b" --parallel "$jobs"
        cmake --install "$b"
    ) > "$log" 2>&1; then
        tail -n 25 "$log" | sed 's/^/         /'
        g_err "llama.cpp build failed (full log: $log)"
        return 1
    fi
    rm -rf "$b"          # ~400 MB of objects; the source stays for a later rebuild
    g_info "llama.cpp installed in ${G_LLAMA_DIR/#$HOME/\~}"
}

# ---------------------------------------------------------------- notes
g_extra_notes() {
    [ -x "$G_LLAMA_DIR/bin/llama-server" ] || { g_err "notes needs the llama.cpp build from --with llm"; return 1; }
    g_fetch hf "${G_EMB[@]:0:2}" "$G_EMB_DIR" "${G_EMB[2]}" || return 1
    [ -d "$(g_vault_dir)" ] || g_warn "notes: no Obsidian vault at $(g_vault_dir) — create it (or pass --vault NAME) and re-run to start the watcher"
}

# ---------------------------------------------------------------- dictation / ocr: ~/.venvs/npu
g_npu_venv() {   # extra pip packages...
    g_have uv || { g_err "uv is missing (pacman -S uv)"; return 1; }
    if [ ! -x "$G_NPU_VENV/bin/python" ]; then
        g_info "creating ${G_NPU_VENV/#$HOME/\~} (Python 3.12, OpenVINO $G_OV_VER)"
        uv venv -q --seed --python 3.12 "$G_NPU_VENV" || return 1
    fi
    uv pip install -q --python "$G_NPU_VENV/bin/python" "${G_OV_PIP[@]}" "$@" || { g_err "pip install into ~/.venvs/npu failed"; return 1; }
}

g_extra_dictation() {
    g_has_npu || g_warn "dictation: no Intel NPU found — Whisper falls back to the CPU (slower)"
    g_npu_venv || return 1
    g_fetch hf "${G_WHISPER[@]}" "$G_WHISPER_DIR"
}

g_extra_ocr() {
    g_has_npu || g_warn "ocr: no Intel NPU found — the OCR runs on the GPU or CPU instead"
    g_npu_venv "${G_OCR_PIP[@]}" || return 1
    g_fetch hf "${G_OCR_DET[@]}" "$G_OCR_DIR/ppocrv6_det_small" inference.onnx inference.yml || return 1
    g_fetch hf "${G_OCR_REC[@]}" "$G_OCR_DIR/ppocrv6_rec_small" inference.onnx inference.yml || return 1
    g_mangaocr_export
}

# manga-ocr has no ready-made static-shape export: convert it here once, in a throwaway environment.
g_mangaocr_export() {
    local out="$G_OCR_DIR/manga_ocr_base" w="$G_BUILD/manga-ocr" f
    if [ -f "$out/ov/encoder.xml" ] && [ -f "$out/ov/decoder_step_b1_t128.xml" ]; then return 0; fi
    g_info "ocr: converting manga-ocr for OpenVINO (temporary torch + transformers env, ~2.5 GB; deleted afterwards)"
    mkdir -p "$w" "$out"
    g_fetch hf "${G_MOCR[@]}" "$w/hf" || return 1
    if [ ! -x "$w/venv/bin/python" ]; then
        uv venv -q --seed --python 3.12 "$w/venv" || return 1
    fi
    uv pip install -q --python "$w/venv/bin/python" torch --index-url https://download.pytorch.org/whl/cpu &&
        uv pip install -q --python "$w/venv/bin/python" transformers pillow numpy "openvino==$G_OV_VER" ||
        { g_err "can't set up the export environment"; return 1; }
    nice -n 10 "$w/venv/bin/python" -I "$G_ROOT/install/glass-tools/export_mangaocr.py" "$w/hf" "$out/ov.tmp" > "$G_BUILD/manga-ocr-export.log" 2>&1 ||
        { tail -n 20 "$G_BUILD/manga-ocr-export.log" | sed 's/^/         /'; g_err "manga-ocr export failed (log: $G_BUILD/manga-ocr-export.log)"; return 1; }
    rm -rf "$out/ov" && mv "$out/ov.tmp" "$out/ov"
    for f in config.json preprocessor_config.json special_tokens_map.json tokenizer_config.json vocab.txt; do
        cp -f "$w/hf/$f" "$out/$f"
    done
    rm -rf "$w"
    g_info "ocr: manga-ocr exported to ${out/#$HOME/\~}/ov"
}

# ---------------------------------------------------------------- jmdict
g_extra_jmdict() {
    local gz="$G_BUILD/dl/JMdict.gz" quiz_gz="$G_BUILD/jp-quiz/data/raw/JMdict.gz"
    [ -s "$quiz_gz" ] && gz="$quiz_gz"   # the JP Quiz build already has one
    [ -s "$gz" ] || g_fetch url "$G_JMDICT_URL" "$gz" || return 1
    [ -f "$HOME/.local/share/npu-ocr/jocr/build_jmdict.py" ] || { g_err "jocr is missing (dotfiles step failed?)"; return 1; }
    (cd "$HOME/.local/share/npu-ocr" && nice -n 10 /usr/bin/python3 -s -m jocr.build_jmdict "$gz") >/dev/null || return 1
    [ "$gz" = "$quiz_gz" ] || rm -f "$gz"
}

# ---------------------------------------------------------------- uninstall
# Heavy parts are never deleted silently: list them (with sizes) and delete only with --purge.
g_extras_paths() {
    printf '%s\n' "$G_OV_DIR" "$G_LLAMA_SRC" "$G_LLAMA_DIR" "$G_CHAT_DIR/${G_CHAT[2]}" "$G_EMB_DIR/${G_EMB[2]}" \
        "$G_WHISPER_DIR" "$G_NPU_VENV" "$G_OCR_DIR" "$G_JMDICT_DB" "$HOME/.venvs/jp-quiz" "$G_BUILD"
}

g_extras_uninstall() {
    local p list=() created
    read -r -a created <<< "$(g_state_get EXTRAS_CREATED)"
    while IFS= read -r p; do
        [ -e "$p" ] || continue
        if [ "${G_PURGE:-0}" = 1 ] && { [[ " ${created[*]} " == *" $p "* ]] || [ "$p" = "$G_BUILD" ]; }; then
            if g_is_dry; then g_dry "delete    ${p/#$HOME/\~} ($(du -sh "$p" 2>/dev/null | cut -f1))"
            else rm -rf "$p" && g_info "deleted ${p/#$HOME/\~}"; fi
        else
            list+=("$(du -sh "$p" 2>/dev/null | cut -f1)	${p/#$HOME/\~}")
        fi
    done < <(g_extras_paths)
    if [ -L "$G_OV_LINK" ] && [ ! -e "$G_OV_LINK/setupvars.sh" ]; then g_is_dry || rm -f "$G_OV_LINK"; fi
    if [ ${#list[@]} -gt 0 ]; then
        g_note "kept the AI models/builds (delete by hand, or re-run with --uninstall --purge for the ones glass created):"
        for p in "${list[@]}"; do g_note "    $p"; done
    fi
}

# Remember what the extras created (so --purge never deletes something that was there before glass).
g_extras_record() {
    g_is_dry && return 0
    local p created; read -r -a created <<< "$(g_state_get EXTRAS_CREATED)"
    while IFS= read -r p; do
        [ "$p" = "$G_BUILD" ] && continue
        [[ " ${created[*]} " == *" $p "* ]] && continue
        [ -e "$p" ] && [[ " ${G_EXISTED_BEFORE[*]} " != *" $p "* ]] && created+=("$p")
    done < <(g_extras_paths)
    g_state_set EXTRAS_CREATED "${created[*]}"
}

g_extras_snapshot() {   # before installing: what already exists
    local p; G_EXISTED_BEFORE=()
    while IFS= read -r p; do [ -e "$p" ] && G_EXISTED_BEFORE+=("$p"); done < <(g_extras_paths)
}
