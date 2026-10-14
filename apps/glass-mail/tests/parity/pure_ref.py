#!/usr/bin/env python3
"""Python side of the pure-function parity test: one JSON request per stdin line -> one result line."""
import json, os, sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
import base64
from glassmail import codes, mime, reader

for line in sys.stdin:
    r = json.loads(line)
    f = r["fn"]
    if f == "html_blocks":
        res = reader.html_blocks(r["src"])
    elif f == "text_blocks":
        res = reader.text_blocks(r["src"])
    elif f == "html_to_text":
        res = reader.html_to_text(r["src"])
    elif f == "codes":
        c = codes.find(r["subject"], r["text"])
        res = [c["code"], c["score"]] if c else None
    elif f == "view":
        res = mime.view(base64.b64decode(r["raw"]))
    elif f == "text_of":
        res = mime.text_of(base64.b64decode(r["raw"]))
    elif f == "header_row":
        res = mime.header_row(base64.b64decode(r["hdr"]), 7, r["flags"], r["idate"], 1234, "1", True, "")
    elif f == "part_text":
        res = mime.part_text(base64.b64decode(r["data"]), r["info"])
    elif f == "snippet":
        res = mime.snippet_from_part(base64.b64decode(r["data"]), r["info"])
    elif f == "parse_rcpt":
        res = [list(x) for x in mime.parse_rcpt(r["text"])]
    elif f == "reply_subject":
        res = mime.reply_subject(r["s"], r["prefix"])
    elif f == "text_to_html":
        res = mime.text_to_html(r["body"])
    elif f == "build":
        fwd = [(n, c, base64.b64decode(d)) for n, c, d in r["forwarded"]]
        try:
            m, rcpts = mime.build(r["acc"], r["draft"], r["attachments"], fwd)
            res = [base64.b64encode(bytes(m)).decode(), rcpts]
        except Exception as e:
            res = ["error", str(e)]
    else:
        res = None
    sys.stdout.write(json.dumps(res, ensure_ascii=False) + "\n")
