#!/usr/bin/env python3
"""A deterministic tick timeline: midnight + week rollover (Sun->Mon), half-hour/hour edges,
system states, an excluded app (secs=0), long titles, gaps that force a full re-sync."""
import datetime as dt, random
random.seed(7)
apps = [("kitty", "zsh"), ("firefox", "Docs"), ("firefox", "Mozilla Firefox"), ("org.telegram.desktop", "Telegram"),
        ("code", "Visual Studio Code"), ("Kitty", "A Very Long Window Title Name Here"), ("mpv", "song.flac")]
t = dt.datetime(2026, 10, 18, 23, 20, 0).timestamp()   # Sunday 23:20 local
tick = 0
for i in range(2600):
    tick += 1
    r = random.random()
    if r < 0.05:
        cls, title = random.choice([("Desktop", "Desktop"), ("Locked", "Locked"), ("Quickshell", "Quickshell")])
        secs = 0
    elif r < 0.08:
        cls, title, secs = "steam", "Steam", 0          # an excluded app: main() passes secs=0
    else:
        cls, title = random.choice(apps)
        secs = random.choice([1, 1, 1, 1, 2])
    if random.random() < 0.004:
        t += random.choice([75, 400, 3600])           # gap -> resync (> 60 s since the last sync)
    t += secs if secs else 1
    print(f"{t:.3f}\t{cls}\t{title}\t{secs}\t{1 if tick % 5 == 0 else 0}")
