"""The agenda editor (RepeatRules.js) and the backend (gcal_rec.py) must word repeat rules the same way.
Runs the QML JS library under node and compares describe() for a set of synthetic rules.
Run: ~/.venvs/gcal/bin/python ~/.local/share/gcal-sync/tests/test_repeat_js.py"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import gcal_rec as R  # noqa: E402

JS = Path(os.environ.get("REPEAT_RULES_JS", Path.home() / ".local/share/serpantinum/src/quickshell/calendar/RepeatRules.js"))
CASES = [
    [{"freq": "weekly", "byday": ["MO"]}, "2026-10-12"], [{"freq": "weekly"}, "2026-10-14"],
    [{"freq": "weekly", "byday": ["MO", "WE"], "interval": 2, "until": "2026-11-30"}, "2026-10-12"],
    [{"freq": "weekly", "byday": ["MO", "TU", "WE", "TH", "FR"]}, "2026-10-12"], [{"freq": "weekly", "byday": ["MO", "WE", "FR"]}, "2026-10-12"],
    [{"freq": "monthly", "byday": ["-1FR"], "count": 3}, "2026-10-30"], [{"freq": "monthly", "byday": ["2TU"]}, "2026-10-13"],
    [{"freq": "monthly", "bymonthday": [31]}, "2026-10-31"], [{"freq": "monthly"}, "2026-10-19"], [{"freq": "yearly"}, "2026-10-10"],
    [{"freq": "daily", "interval": 3, "count": 4}, "2026-10-01"], [{"freq": "daily", "count": 1}, "2026-10-01"],
    [{"freq": "yearly", "interval": 2, "until": "2030-01-01"}, "2026-02-28"], [None, "2026-10-01"],
    [{"freq": "monthly", "bymonthday": [-1]}, "2026-10-31"], [{"freq": "weekly", "byday": ["SA", "SU"]}, "2026-10-17"],
    [{"freq": "monthly", "byday": ["4TH"], "interval": 2}, "2026-10-22"],
]
node = shutil.which("node")
if not node:
    print("SKIP: node not installed")
    sys.exit(0)
script = ("const fs=require('fs');const src=fs.readFileSync(process.argv[1],'utf8').replace('.pragma library','');"
          "const R=new Function(src+'; return {describe};')();const c=JSON.parse(process.argv[2]);"
          "console.log(JSON.stringify(c.map(([r,d])=>R.describe(r,d))));")
js = json.loads(subprocess.run([node, "-e", script, str(JS), json.dumps(CASES)], capture_output=True, text=True, check=True).stdout)
py = [R.describe(r, d) for r, d in CASES]
bad = [(a, b) for a, b in zip(py, js) if a != b]
for a, b in bad:
    print(f"FAIL python {a!r} != js {b!r}")
print(f"{len(CASES) - len(bad)}/{len(CASES)} identical\n" + ("ALL PASSED" if not bad else f"{len(bad)} FAILED"))
sys.exit(1 if bad else 0)
