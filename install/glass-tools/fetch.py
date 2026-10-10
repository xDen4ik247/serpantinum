#!/usr/bin/env python3
"""Download helper for the glass installer (standard library only).

  fetch.py url URL DEST [SHA256]
      one file; resumes DEST.part; checks the sha256 when given
  fetch.py hf REPO REVISION DESTDIR [FILE ...]
      files of a Hugging Face model repo at a fixed revision (all files except README.md and
      .gitattributes when none are named); sizes and the sha256 of large files come from the
      HF API for that exact revision

Files that are already complete are skipped. Progress goes to stderr. Exit status 1 on any failure.
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

UA = {"User-Agent": "serp-glass-installer"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024


def _get(url, part, have, size, label):
    """Append the rest of url to part (from byte `have`). Returns when the server is done."""
    req = urllib.request.Request(url, headers=dict(UA, **({"Range": f"bytes={have}-"} if have else {})))
    try:
        r = urllib.request.urlopen(req, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code == 416 and have:           # nothing left to send: the .part is complete
            return
        raise
    with r:
        if have and r.status != 206:         # server ignored the range: start over
            have = 0
        total = size or (int(r.headers.get("Content-Length", 0)) + have) or None
        done, last = have, 0.0
        with open(part, "ab" if have else "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                now = time.time()
                if now - last > 2 and sys.stderr.isatty():
                    pct = f"{100 * done / total:5.1f}%" if total else ""
                    print(f"\r  get      {label} {human(done)} {pct}   ", end="", file=sys.stderr)
                    last = now
    if sys.stderr.isatty():
        print("\r", end="", file=sys.stderr)


def download(url, dest, size=None, sha=None, label=None):
    label = label or os.path.basename(dest)
    if os.path.exists(dest) and (size is None or os.path.getsize(dest) == size):
        if sha is None or sha256(dest) == sha:
            print(f"  ok       {label}", file=sys.stderr)
            return
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    part = dest + ".part"
    for attempt in range(1, 6):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if size is not None and have > size:
            os.remove(part)
            have = 0
        try:
            if size is None or have < size:
                _get(url, part, have, size, label)
            if size is not None and os.path.getsize(part) != size:
                raise IOError(f"size {os.path.getsize(part)} != {size}")
            if sha is not None:
                got = sha256(part)
                if got != sha:
                    os.remove(part)
                    raise IOError(f"sha256 mismatch ({got[:12]}... != {sha[:12]}...)")
            os.replace(part, dest)
            print(f"  got      {label} ({human(os.path.getsize(dest))})", file=sys.stderr)
            return
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            print(f"\n  retry {attempt}/5 {label}: {e}", file=sys.stderr)
            time.sleep(min(30, 3 * attempt))
    raise SystemExit(f"fetch: giving up on {url}")


def hf(repo, rev, destdir, files):
    api = f"https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=1"
    with urllib.request.urlopen(urllib.request.Request(api, headers=UA), timeout=60) as r:
        tree = {f["path"]: f for f in json.load(r) if f.get("type") == "file"}
    want = files or [p for p in tree if p not in ("README.md", ".gitattributes")]
    for path in want:
        if path not in tree:
            raise SystemExit(f"fetch: {repo}@{rev[:10]} has no {path}")
        f = tree[path]
        lfs = f.get("lfs") or {}
        download(f"https://huggingface.co/{repo}/resolve/{rev}/{path}", os.path.join(destdir, path),
                 size=f.get("size"), sha=lfs.get("oid"), label=f"{repo.split('/')[-1]}/{path}")


def main(argv):
    if len(argv) >= 3 and argv[0] == "url":
        download(argv[1], argv[2], sha=argv[3] if len(argv) > 3 else None)
    elif len(argv) >= 4 and argv[0] == "hf":
        hf(argv[1], argv[2], argv[3], argv[4:])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
