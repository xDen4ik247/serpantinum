"""AI assistant TUI (Mod+A): streaming chat with the local LLM (llama-server, 127.0.0.1:8765),
markdown rendered by rich, conversation kept until the window closes, quick clipboard actions."""
import json
import os
import readline  # noqa: F401  (line editing + history for input())
import subprocess
import sys
import time
import urllib.request

from rich.console import Console, Group
from rich.live import Live
from rich.markdown import Markdown
from rich.padding import Padding
from rich.rule import Rule
from rich.spinner import Spinner
from rich.table import Table
from rich.text import Text
from rich.theme import Theme

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

# ANSI palette slots only, so the colours follow the wallpaper theme. The kitty palette is
# Material You: green = primary, yellow = tertiary, bright_blue = pale secondary.
ACC, ACC2, USER = "green", "bright_blue", "yellow"
con = Console(highlight=False, theme=Theme({
    "markdown.code": f"bold {USER}", "markdown.link": f"underline {ACC}", "markdown.item.bullet": f"bold {ACC}",
    "markdown.item.number": f"bold {ACC}", "markdown.h1": f"bold {ACC2}", "markdown.h2": f"bold underline {ACC}",
    "markdown.h3": f"bold {ACC}", "markdown.block_quote": "italic grey62", "markdown.hr": "grey35",
}))
COMMANDS = ["/en", "/ru", "/ja", "/sum", "/fix", "/explain", "/keigo", "/reply", "/paste", "/copy", "/new", "/help", "/q"]
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


class Waiting:
    """Spinner with a live elapsed-time counter until the first token arrives."""
    def __init__(self):
        self.t0, self.sp = time.time(), Spinner("dots", style=ACC)

    def __rich__(self):
        s = int(time.time() - self.t0)
        msg = Text("thinking", style=ACC) + Text(f"  {s}s", style="dim")
        if s >= 4:
            msg += Text("  · waking the model, the first answer after idle takes ~35 s", style="dim italic")
        self.sp.update(text=msg)
        return self.sp


def label(txt, style):
    con.print(Text("  ") + Text(txt, style=style))


def answer(messages):
    out, t0, t1, n = "", time.time(), None, 0
    con.print()
    label("✦ assistant", f"bold {ACC}")
    try:
        with Live(Padding(Waiting(), (0, 0, 0, 4)), console=con, refresh_per_second=12,
                  vertical_overflow="visible") as live:
            for d in stream(messages):
                out += d
                n += 1
                t1 = t1 or time.time()
                live.update(Padding(Markdown(out, code_theme="ansi_dark"), (0, 2, 0, 4)))
    except KeyboardInterrupt:
        con.print(Padding(Text("■ stopped", style="red"), (0, 0, 0, 4)))
    except OSError as e:
        con.print(Padding(Text.assemble(("✗ the local model is unreachable", "bold red"), (f"  ({e})\n", "dim"),
                                        ("  start it:  ", "dim"), ("systemctl --user start npu-llm", USER)), (0, 0, 0, 4)))
        return ""
    if n:
        gen = time.time() - (t1 or t0)
        con.print(Text(f"{t1 - t0:.1f} s to first word · {n / gen if gen > 0 else 0:.0f} tok/s  ", style="grey42"),
                  justify="right")
    return out.strip()


def help_panel():
    groups = [
        ("on the clipboard  (answer is copied back)", [
            ("/en  /ru  /ja", "translate"), ("/sum", "summarize: gist + bullets"), ("/fix", "fix spelling and grammar"),
            ("/explain", "explain for a beginner"), ("/keigo", "polite Japanese business form"),
            ("/reply", "suggest a short reply"), ("/en sel", "add sel: use the mouse selection instead"),
            ("/en some text", "or give the text right after the command")]),
        ("chat", [
            ("/paste", "attach the clipboard to your next message"), ("/copy", "copy the last answer"),
            ("/new", "forget the conversation"), ("/q  Ctrl-D", "close the window")]),
        ("typing", [
            ("Tab", "complete a /command"), ("↑ ↓", "earlier messages"), ("line ending in \\", "continue on the next line"),
            ("Ctrl-C", "stop the answer")]),
    ]
    for title, rows in groups:
        t = Table.grid(padding=(0, 3))
        t.add_column(no_wrap=True, min_width=16)
        t.add_column()
        for k, v in rows:
            t.add_row(Text(k, style=f"bold {ACC}"), Text(v, style="grey70"))
        con.print()
        con.print(Text("    " + title, style=f"bold {ACC2}"))
        con.print(Padding(t, (0, 0, 0, 4)))


def snippet(txt, width):
    one = " ".join(txt.split())
    return one[:width] + ("…" if len(one) > width else "")


def banner():
    con.clear()
    con.print()
    head = Table.grid(expand=True, padding=(0, 2))
    head.add_column()
    head.add_column(justify="right")
    head.add_row(Text.assemble(("  ✦ ", f"bold {ACC2}"), ("Assistant", f"bold {ACC}")),
                 Text("qwen3.5 4b · local · Arc GPU  ", style="grey50"))
    con.print(head)
    con.print(Rule(style="grey27"))
    clip = paste()
    if clip:
        con.print(Text.assemble(("  clipboard  ", f"bold {USER}"),
                                (snippet(clip, max(20, con.width - 16)), "italic grey62")))
    con.print(Text.assemble(("  /help", f"bold {ACC}"), (" commands   ", "grey50"), ("/en /sum /fix", f"bold {ACC}"),
                            (" work on the clipboard   ", "grey50"), ("Tab", f"bold {ACC}"), (" completes", "grey50")))


def rl(txt, sgr):
    """Prompt text coloured for readline (\001 \002 hide the escapes from its width count)."""
    return f"\001\033[{sgr}m\002{txt}\001\033[0m\002"


def read_prompt():
    con.print()
    label("╭─ you", f"bold {USER}")
    lines = []
    while True:
        ln = input(rl("  ╰› ", "1;33") if not lines else rl("   │ ", "90"))
        if ln.endswith("\\"):
            lines.append(ln[:-1])
            continue
        lines.append(ln)
        return "\n".join(lines).strip()


def complete(text, state):
    hits = [c + " " for c in COMMANDS if c.startswith(text)] if text.startswith("/") else []
    return hits[state] if state < len(hits) else None


def main():
    global last_answer, pending_ctx
    readline.set_completer_delims(" \t\n")
    readline.set_completer(complete)
    readline.parse_and_bind("tab: complete")
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
                    con.print(Text("  ✓ copied the last answer", style="green"))
                continue
            if cmd == "paste":
                pending_ctx = paste()
                con.print(Text.assemble(("  ＋ attached ", "green"), (f"{len(pending_ctx)} chars", "bold green"),
                                        (" from the clipboard to your next message", "green")) if pending_ctx
                          else Text("  the clipboard is empty", style="red"))
                continue
            if cmd in QUICK:
                src = paste(primary=arg.strip() == "sel") if arg.strip() in ("", "sel") else arg
                if not src:
                    con.print(Text("  nothing in the clipboard / selection", style="red"))
                    continue
                con.print(Text.assemble((f"  /{cmd} ", f"bold {ACC}"), ("on  ", "grey50"),
                                        (snippet(src, max(20, con.width - 16)), "italic grey62")))
                user = QUICK[cmd] + "\n\n" + src
                msgs.append({"role": "user", "content": user})
                trim()
                last_answer = answer(msgs)
                msgs.append({"role": "assistant", "content": last_answer})
                if last_answer:
                    copy(last_answer)
                    con.print(Text("✓ copied to the clipboard  ", style="green"), justify="right")
                continue
            con.print(Text.assemble(("  unknown command ", "red"), (f"/{cmd}", "bold red"), ("  · /help lists them", "grey50")))
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
