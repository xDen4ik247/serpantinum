"""Removing songs from disk (library or the Yandex temp cache). Dependency-free: used by the app
backend and by the Yandex worker (which first unlikes the songs on Yandex, so the daily sync
does not download them again).

Library songs go to the desktop Trash (`gio trash`, restorable) together with their .lrc / .txt;
temp-cache songs are deleted. An album folder left without audio loses its cover and goes too,
and so does an artist folder left empty."""

import os
import shutil
import subprocess

AUDIO = (".m4a", ".flac", ".mp3", ".ogg", ".opus", ".wav")
SIDECARS = (".lrc", ".txt")
COVERS = ("cover.jpg", "cover.png", "folder.jpg", "folder.png")


def inside(path, roots):
    """True if path (resolved) lies strictly inside one of roots."""
    p = os.path.realpath(path)
    for r in roots:
        if r and p.startswith(os.path.realpath(r).rstrip("/") + "/"):
            return True
    return False


def _discard(path, trash):
    if not os.path.lexists(path):
        return True
    if trash and shutil.which("gio"):
        r = subprocess.run(["gio", "trash", "--", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            return True
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
        return True
    except OSError:
        return False


def remove(paths, roots, trash_roots=()):
    """Remove the audio files `paths` (absolute) that lie inside `roots`.

    Files inside one of `trash_roots` go to the Trash, the rest are deleted. Returns
    (removed audio paths, failed paths, folders to rescan): each rescan folder is the highest
    folder that disappeared, or the album folder if it is still there."""
    removed, failed, rescan = [], [], set()
    for p in paths:
        if not p.lower().endswith(AUDIO) or not inside(p, roots) or not os.path.isfile(p):
            failed.append(p)
            continue
        trash = inside(p, trash_roots)
        stem = os.path.splitext(p)[0]
        if not _discard(p, trash):
            failed.append(p)
            continue
        removed.append(p)
        for ext in SIDECARS:
            _discard(stem + ext, trash)
        d = os.path.dirname(p)
        top = d
        root = next(os.path.realpath(r) for r in roots if inside(p, [r]))
        # album folder without audio: covers + folder go; then an empty artist folder
        while os.path.realpath(d) != root and os.path.isdir(d):
            names = os.listdir(d)
            if any(n.lower().endswith(AUDIO) or os.path.isdir(os.path.join(d, n)) for n in names):
                break
            if any(n.lower() not in COVERS and not n.startswith(".yandex-music-downloader.") for n in names):
                break
            for n in names:
                _discard(os.path.join(d, n), trash)
            try:
                os.rmdir(d)
            except OSError:
                break
            top = d
            d = os.path.dirname(d)
        rescan.add(top)
    return removed, failed, sorted(rescan)
