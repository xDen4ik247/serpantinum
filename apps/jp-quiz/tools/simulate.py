"""Simulate learners with known true skill against the real engine; plot and print numbers.

    python tools/simulate.py [out.png]      (needs matplotlib; run from the project root)
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tests.sim import Learner, run  # noqa: E402

LEARNERS = [  # label, true start, learning per answer, color (validated categorical slots 1-3)
    ("beginner (θ −1.0)", -1.0, 0.0, "#2a78d6"),
    ("steady N4 (θ +0.3)", 0.3, 0.0, "#eb6834"),
    ("improving (−0.5 → +1.0)", -0.5, 0.0025, "#1baf7a"),
]
N = 600


def rolling(xs, w=50):
    out = []
    for i in range(len(xs)):
        win = xs[max(0, i - w + 1):i + 1]
        out.append(sum(win) / len(win))
    return out


def main(out_png):
    rows = []
    runs = []
    for k, (label, th, lr, color) in enumerate(LEARNERS):
        eng, log, _ = run(Learner(theta=th, seed=40 + k, learn_rate=lr), n=N, target=0.75,
                          tmp=Path(tempfile.mkdtemp(prefix="jpq-plot-")), engine_seed=7 + k)
        late = log[100:]
        rate = sum(r["ok"] for r in late) / len(late)
        mae = sum(abs(r["p_pred"] - r["p_true"]) for r in late) / len(late)
        err12 = abs(log[11]["est"] - log[11]["true"])
        errN = abs(log[-1]["est"] - log[-1]["true"])
        rows.append((label, rate, mae, err12, errN))
        runs.append((label, color, log))
    print(f"{'learner':28s} {'success 100-600':>16s} {'MAE p':>7s} {'|err| after 12':>15s} {'|err| at 600':>13s}")
    for label, rate, mae, e12, eN in rows:
        print(f"{label:28s} {rate:16.3f} {mae:7.3f} {e12:15.2f} {eN:13.2f}")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    surface, ink, muted, grid = "#fcfcfb", "#1a1a19", "#5f5e58", "#e7e6e1"
    plt.rcParams.update({"font.family": "Google Sans", "font.size": 10, "axes.edgecolor": grid,
                         "axes.labelcolor": muted, "xtick.color": muted, "ytick.color": muted})
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.4), dpi=150, facecolor=surface)
    for ax in (a1, a2):
        ax.set_facecolor(surface)
        ax.grid(True, color=grid, linewidth=0.8)
        ax.set_axisbelow(True)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        ax.set_xlabel("answers")
    for label, color, log in runs:
        xs = list(range(len(log)))
        a1.plot(xs, [r["true"] for r in log], color=color, linewidth=1.2, linestyle=(0, (4, 3)), alpha=0.9)
        a1.plot(xs, [r["est"] for r in log], color=color, linewidth=2, label=label)
        a1.annotate(label.split(" (")[0], (xs[-1], log[-1]["est"]), xytext=(6, 0), textcoords="offset points",
                    color=ink, fontsize=9, va="center")
        a2.plot(xs, rolling([r["ok"] for r in log]), color=color, linewidth=2, label=label)
    a1.set_title("Skill estimate (solid) vs true skill (dashed), logits", color=ink, fontsize=11, loc="left")
    a1.set_xlim(0, N * 1.16)
    a2.axhspan(0.70, 0.80, color="#d9d8d2", alpha=0.45, linewidth=0)
    a2.axhline(0.75, color=muted, linewidth=1, linestyle=(0, (4, 3)))
    a2.annotate("target 75 %", (N, 0.75), xytext=(6, 9), textcoords="offset points", color=ink, fontsize=9, va="center")
    a2.set_ylim(0.3, 1.0)
    a2.set_xlim(0, N * 1.12)
    a2.set_title("Success rate, rolling 50 answers", color=ink, fontsize=11, loc="left")
    a2.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0, decimals=0))
    leg = a2.legend(frameon=False, loc="lower right", fontsize=9)
    for t in leg.get_texts():
        t.set_color(ink)
    fig.tight_layout()
    fig.savefig(out_png, facecolor=surface)
    print("wrote", out_png)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "docs/simulation.png")
