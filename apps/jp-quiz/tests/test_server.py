"""The JSON-lines bridge must survive a malformed line and never echo a previous request's rid.

Runs the real server as a subprocess on a throwaway data dir (copy of the content DB, fresh
progress DB), so no user progress is touched.
Run:  python -m unittest discover -s tests -v      (from the project root)
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTENT = ROOT / "data" / "content.db"


@unittest.skipUnless(CONTENT.exists(), "data/content.db not built")
class TestBridge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="jpquiz-bridge-")
        shutil.copy(CONTENT, Path(self.tmp) / "content.db")
        self.env = dict(os.environ, JPQUIZ_DATA=self.tmp,
                        JPQUIZ_CONTENT=str(Path(self.tmp) / "content.db"),
                        JPQUIZ_PROGRESS=str(Path(self.tmp) / "progress.db"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def talk(self, lines):
        p = subprocess.run([sys.executable, "-m", "jpquiz.server"], cwd=ROOT, env=self.env,
                           input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=60)
        return p, [json.loads(l) for l in p.stdout.splitlines()]

    def test_garbage_first_line(self):
        p, out = self.talk(["{not json", json.dumps({"cmd": "stats", "rid": 7})])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0]["type"], "error")
        self.assertIsNone(out[0]["rid"])
        self.assertEqual(out[1]["rid"], 7)

    def test_garbage_line_does_not_reuse_previous_rid(self):
        p, out = self.talk([json.dumps({"cmd": "stats", "rid": 1}), "oops", json.dumps({"cmd": "nope"}),
                            "[1, 2]"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([o["rid"] for o in out], [1, None, None, None])
        self.assertEqual([o["type"] for o in out[1:]], ["error"] * 3)


if __name__ == "__main__":
    unittest.main()
