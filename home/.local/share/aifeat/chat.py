"""AI assistant TUI (Mod+A): streaming chat with the local LLM (llama-server, 127.0.0.1:8765),
markdown rendered by rich, conversation kept until the window closes, quick clipboard actions."""
import json
import os
import readline  # noqa: F401  (line editing + history for input())
import subprocess
import sys
import time
import urllib.request

from rich.console import Console
from rich.live import Live
from rich.markdown import Markdown
from rich.panel import Panel
from rich.text import Text

URL = os.environ.get("AI_URL", "http://127.0.0.1:8765") + "/v1/chat/completions"
SYSTEM = ("You are a helpful, concise assistant on the user's Arch Linux laptop (niri desktop). "
          "Answer in the language of the question. Use markdown when it helps (lists, code blocks).")
QUICK = {
    "en": "Translate the following text into natural English. Output only the translation.",
    "ru": "Translate the following text into natural Russian. Output only the translation.",
    "ja": "Translate the following text into natural Japanese. Output only the translation.",
    "sum": "Summarize the following text: a one-line gist, then key points as short bullets. Same language as the text.",
    "fix": "Fix spelling, grammar and punctuation in the following text. Keep language, meaning and tone. Output only the corrected text.",
    "explain": "Explain the following text or code clearly and briefly for a beginner.",
    "keigo": "Rewrite the following as polite Japanese business keigo (translate to Japanese first if needed). Output only the result.",
    "reply": "Write one short, natural reply to the following message in its language. Output only the reply.",
}
HISTORY_CHARS = 14000  # ~ 8k-token context minus room for the answer

con = Console(highlight=False)
ACC = "bright_blue"
msgs = [{"role": "system", "content": SYSTEM}]
last_answer = ""
pending_ctx = ""


def paste(primary=False):
    try:
        r = subprocess.run(["wl-paste", "--no-newline", "--type", "text"] + (["--primary"] if primary else []),
                           capture_output=True, text=True, timeout=1)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def copy(txt):
    subprocess.run(["wl-copy", "--", txt])


def trim():
    while sum(len(m["content"]) for m in msgs) > HISTORY_CHARS and len(msgs) > 3:
        del msgs[1:3]


def stream(messages):
    body = json.dumps({"messages": messages, "stream": True, "temperature": 0.6, "max_tokens": 1500}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            ln = raw.decode("utf-8", "replace").strip()
            if not ln.startswith("data:"):
                continue
            p = ln[5:].strip()
            if p == "[DONE]":
                return
            try:
                d = json.loads(p)["choices"][0]["delta"].get("content")
            except (KeyError, IndexError, ValueError):
                continue
            if d:
                yield d


def answer(messages):
    out, t0, n = "", time.time(), 0
    try:
        with Live(Markdown(""), console=con, refresh_per_second=12, vertical_overflow="visible") as live:
            for d in stream(messages):
                out += d
                n += 1
                live.update(Markdown(out, code_theme="ansi_dark"))
    except KeyboardInterrupt:
        con.print("[dim]· stopped[/]")
    except OSError as e:
        con.print(f"[red]LLM unreachable ({e}). Start it: systemctl --user start npu-llm[/]")
        return ""
    dt = time.time() - t0
    con.print(Text(f"{dt:.1f} s · {n / dt if dt else 0:.0f} tok/s", style="dim"), justify="right")
    return out.strip()


def help_panel():
    t = Text()
    rows = [("/en /ru /ja", "translate the clipboard"), ("/sum /fix /explain", "summarize · fix · explain clipboard"),
            ("/keigo /reply", "polite Japanese · suggest a reply"), ("… sel", "e.g. /en sel: use the selection"),
            ("/paste", "attach clipboard to next message"), ("/copy", "copy the last answer"),
            ("/new", "start over"), ("/q  Ctrl-D", "close"), ("line ending in \\", "continue on the next line"),
            ("Ctrl-C", "stop the answer")]
    for i, (k, v) in enumerate(rows):
        t.append(f"{k:<20}", style=ACC)
        t.append(v + ("\n" if i < len(rows) - 1 else ""), style="default")
    con.print(Panel(t, title="commands", title_align="left", border_style="grey50", padding=(0, 1)))


def banner():
    con.clear()
    con.print(Text("✦ Assistant", style=f"bold {ACC}"), Text("  local qwen3.5-4b · Arc GPU · /help", style="dim"))
    clip = paste()
    if clip:
        one = " ".join(clip.split())
        con.print(Text("clipboard: ", style="dim") + Text(one[:110] + ("…" if len(one) > 110 else ""), style="italic grey70"))
    con.print()


def read_prompt():
    lines = []
    while True:
        ln = input("› " if not lines else "  ")
        if ln.endswith("\\"):
            lines.append(ln[:-1])
            continue
        lines.append(ln)
        return "\n".join(lines).strip()


def main():
    global last_answer, pending_ctx
    banner()
    while True:
        try:
            con.print()
            q = read_prompt()
        except (EOFError, KeyboardInterrupt):
            return
        if not q:
            continue
        if q.startswith("/"):
            cmd, *rest = q[1:].split(None, 1)
            arg = rest[0] if rest else ""
            if cmd in ("q", "quit", "exit"):
                return
            if cmd in ("help", "h", "?"):
                help_panel()
                continue
            if cmd == "new":
                del msgs[1:]
                last_answer = pending_ctx = ""
                banner()
                continue
            if cmd == "copy":
                if last_answer:
                    copy(last_answer)
                    con.print("[dim]copied[/]")
                continue
            if cmd == "paste":
                pending_ctx = paste()
                con.print(f"[dim]attached {len(pending_ctx)} chars from the clipboard[/]")
                continue
            if cmd in QUICK:
                src = paste(primary=arg.strip() == "sel") if arg.strip() in ("", "sel") else arg
                if not src:
                    con.print("[yellow]nothing in the clipboard/selection[/]")
                    continue
                one = " ".join(src.split())
                con.print(Text("on: ", style="dim") + Text(one[:100] + ("…" if len(one) > 100 else ""), style="italic grey70"))
                user = QUICK[cmd] + "\n\n" + src
                msgs.append({"role": "user", "content": user})
                trim()
                last_answer = answer(msgs)
                msgs.append({"role": "assistant", "content": last_answer})
                if last_answer:
                    copy(last_answer)
                    con.print(Text("copied to clipboard", style="dim"), justify="right")
                continue
            con.print("[yellow]unknown command — /help[/]")
            continue
        user = q
        if pending_ctx:
            user = f"{q}\n\n---\n{pending_ctx}"
            pending_ctx = ""
        msgs.append({"role": "user", "content": user})
        trim()
        last_answer = answer(msgs)
        if last_answer:
            msgs.append({"role": "assistant", "content": last_answer})
        else:
            msgs.pop()


if __name__ == "__main__":
    main()
    sys.exit(0)
