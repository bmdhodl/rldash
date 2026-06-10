#!/usr/bin/env python3
"""rldash -- a zero-dependency terminal dashboard for RL training logs.

Tails your training log, parses the latest progress line, and redraws an
ANSI dashboard in place: progress bars, return sparkline, steps/sec, and an
optional GPU gauge (if nvidia-smi is on PATH). Pure stdlib; one file.

Quickstart:
    python rldash.py --log runs/myrun.log

Follow whatever run is newest (glob):
    python rldash.py --log "runs/*.log"

Custom log format (named groups; see --help):
    python rldash.py --log train.log --pattern \
      "step (?P<step>[\\d,]+).*?return (?P<ep_ret>-?[\\d.]+)"

Born on an RTX 5090 during an N=7 pendulum swing-up campaign.
MIT license. https://bmdpat.com
"""
from __future__ import annotations
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time

# Default pattern matches lines like:
#   upd  205/1907  step 107,479,040  SPS 327,723  ep_ret 220.3  ep_len 94.8
#   ... rps 2.32  v_loss 0.07  EV +0.99  logstd -1.86
# Only `step` is required; everything else is optional and shown if present.
DEFAULT_PATTERN = (
    r"upd\s+(?P<upd>\d+)/(?P<updtot>\d+)\s+"
    r"step\s+(?P<step>[\d,]+)\s+"
    r"SPS\s+(?P<sps>[\d,]+)\s+"
    r"ep_ret\s+(?P<ep_ret>-?[\d.]+)\s+"
    r"ep_len\s+(?P<ep_len>[\d.]+)"
    r"(?:\s+start_ang\s+(?P<start_ang>[\d.]+))?"
    r"(?:\s+rps\s+(?P<rps>-?[\d.]+))?"
    r"(?:\s+v_loss\s+(?P<v_loss>-?[\d.]+))?"
    r"(?:\s+EV\s+(?P<EV>[+-]?[\d.]+))?"
    r"(?:\s+logstd\s+(?P<logstd>[+-]?[\d.]+))?"
)

# Named groups consumed by dedicated gauges; every OTHER named group in the
# pattern is shown verbatim in the footer -- custom patterns get their extra
# fields displayed for free.
GAUGE_FIELDS = {"upd", "updtot", "step", "sps", "ep_ret", "ep_len", "rps"}

# Run-state markers searched in the log tail (and *driver*.out siblings).
DEFAULT_DONE = r"COMPLETE|ABORT|Traceback|\[train\] done"

ESC = "\x1b"
C = dict(cyan=f"{ESC}[96m", green=f"{ESC}[92m", yellow=f"{ESC}[93m",
         red=f"{ESC}[91m", gray=f"{ESC}[90m", mag=f"{ESC}[95m",
         bold=f"{ESC}[1m", dim=f"{ESC}[2m", rst=f"{ESC}[0m")
BLOCKS = " ▏▎▍▌▋▊▉█"
SPARKS = " ▁▂▃▄▅▆▇█"


def bar(val: float, vmax: float, width: int) -> str:
    vmax = max(vmax, 1e-9)
    frac = min(max(val / vmax, 0.0), 1.0)
    full = int(frac * width)
    rem = (frac * width) - full
    out = "█" * full
    if full < width:
        out += BLOCKS[round(rem * 8)]
    return out[:width].ljust(width, "░")


def spark(vals: list[float]) -> str:
    if not vals:
        return ""
    lo, hi = min(vals), max(vals)
    rng = (hi - lo) or 1.0
    return "".join(SPARKS[round((v - lo) / rng * 8)] for v in vals)


def newest(pattern: str) -> str | None:
    paths = glob.glob(os.path.expanduser(pattern))
    if not paths:
        return None
    return max(paths, key=os.path.getmtime)


def last_match(path: str, rx: re.Pattern, tail_bytes: int = 65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    hit = None
    for m in rx.finditer(text):
        hit = m
    return hit


def gpu_stats() -> tuple[int, float, int, float] | None:
    if not shutil.which("nvidia-smi"):
        return None
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu,power.draw,"
             "utilization.gpu,power.limit", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5).stdout
        t, p, u, pl = (x.strip() for x in out.splitlines()[0].split(","))
        return int(float(t)), float(p), int(float(u)), float(pl)
    except Exception:
        return None


def run_marker(path: str | None, rx: re.Pattern) -> str:
    """Search the log tail AND sibling *driver*.out files for a run-state
    marker (COMPLETE / ABORT / crash). Returns the last marker text or ''."""
    cands = []
    if path:
        cands.append(path)
        cands += sorted(glob.glob(os.path.join(os.path.dirname(path) or ".",
                                               "*driver*.out")),
                        key=os.path.getmtime)[-1:]
    last = ""
    for p in cands:
        try:
            with open(p, "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 16384))
                txt = f.read().decode("utf-8", errors="replace")
        except OSError:
            continue
        for m in rx.finditer(txt):
            last = m.group(0)
    return last


def fnum(s: str | None) -> float:
    return float(s.replace(",", "")) if s else 0.0


def main() -> None:
    ap = argparse.ArgumentParser(
        description="zero-dependency terminal dashboard for RL training logs")
    ap.add_argument("--log", default="runs/*.log",
                    help="log file or glob; newest match is followed")
    ap.add_argument("--pattern", default=DEFAULT_PATTERN,
                    help="regex with named groups; required: step; optional: "
                         "upd, updtot, sps, ep_ret, ep_len, rps, logstd")
    ap.add_argument("--interval", type=float, default=2.0,
                    help="refresh seconds")
    ap.add_argument("--title", default="R L   T R A I N I N G",
                    help="header title")
    ap.add_argument("--ep-len-max", type=float, default=0.0,
                    help="full-scale for the ep_len bar (0 = auto)")
    ap.add_argument("--rps-max", type=float, default=0.0,
                    help="full-scale for the reward/step bar (0 = auto)")
    ap.add_argument("--gpu-limit", type=int, default=85,
                    help="temperature shown as the gauge limit")
    ap.add_argument("--done-pattern", default=DEFAULT_DONE,
                    help="regex marking run completion/crash, searched in the "
                         "log tail and sibling *driver*.out files")
    ap.add_argument("--plain", action="store_true",
                    help="append frames instead of repainting (for piping)")
    ap.add_argument("--once", action="store_true", help="draw one frame, exit")
    args = ap.parse_args()

    if os.name == "nt":
        os.system("")              # enables ANSI processing in Windows console
    # Block/box characters need UTF-8 even when stdout is a cp1252 console
    # or a redirected pipe (Windows defaults both to legacy codecs).
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    rx = re.compile(args.pattern)
    done_rx = re.compile(args.done_pattern)
    hist: list[float] = []
    last_log = ""
    t0 = time.time()
    if not args.plain:
        sys.stdout.write(f"{ESC}[2J{ESC}[H")

    while True:
        path = newest(args.log)
        lines: list[str] = []
        W = 30
        name = os.path.basename(path) if path else "(no log found)"
        if path != last_log:
            hist.clear()
            last_log = path
        lines.append(f"{C['cyan']}{C['bold']}"
                     "╔" + "═" * 64 + "╗" + C["rst"])
        lines.append(f"{C['cyan']}{C['bold']}║   {args.title:<42}"
                     f"{C['mag']}r l d a s h{C['cyan']}        ║" + C["rst"])
        lines.append(f"{C['cyan']}{C['bold']}║   {C['rst']}{C['dim']}"
                     f"{name:<53}{C['rst']}{C['cyan']}{C['bold']}"
                     "        ║" + C["rst"])
        lines.append(f"{C['cyan']}{C['bold']}"
                     "╚" + "═" * 64 + "╝" + C["rst"])
        lines.append("")

        m = last_match(path, rx) if path else None
        if not m:
            lines.append(f"  {C['yellow']}waiting for a matching log line..."
                         f"{C['rst']}")
        else:
            g = m.groupdict()
            step = fnum(g.get("step"))
            upd, updtot = fnum(g.get("upd")), fnum(g.get("updtot"))
            ep_ret = fnum(g.get("ep_ret"))
            ep_len = fnum(g.get("ep_len"))
            rps = fnum(g.get("rps"))
            sps = fnum(g.get("sps"))
            hist.append(ep_ret)
            del hist[:-48]

            if updtot:
                pct = 100.0 * upd / updtot
                lines.append(f"  {C['bold']}update{C['rst']}   "
                             f"{int(upd):>6}/{int(updtot):<7}"
                             f"{C['gray']}▕{C['green']}"
                             f"{bar(upd, updtot, W)}{C['gray']}▏"
                             f"{C['rst']} {pct:5.1f}%")
                tot = step * updtot / max(upd, 1)
                lines.append(f"  {C['bold']}steps{C['rst']}    "
                             f"{step/1e6:9.1f}M / {tot/1e6:,.0f}M"
                             f"      {C['gray']}SPS{C['rst']} {sps:,.0f}")
            else:
                lines.append(f"  {C['bold']}steps{C['rst']}    "
                             f"{step/1e6:9.1f}M      "
                             f"{C['gray']}SPS{C['rst']} {sps:,.0f}")
            lines.append("")
            peak = max(hist) if hist else 1.0
            lines.append(f"  {C['bold']}ep_ret{C['rst']}   "
                         f"{C['gray']}▕{C['cyan']}"
                         f"{bar(ep_ret, peak, W)}{C['gray']}▏{C['rst']} "
                         f"{ep_ret:9.1f}  {C['dim']}(peak {peak:,.0f})"
                         f"{C['rst']}")
            if g.get("rps"):
                rmax = args.rps_max or max(rps, 1.0) * 1.5
                lines.append(f"  {C['bold']}rew/step{C['rst']} "
                             f"{C['gray']}▕{C['yellow']}"
                             f"{bar(rps, rmax, W)}{C['gray']}▏{C['rst']} "
                             f"{rps:9.2f}")
            lmax = args.ep_len_max or max(ep_len, 1.0) * 1.25
            lines.append(f"  {C['bold']}ep_len{C['rst']}   "
                         f"{C['gray']}▕{C['green']}"
                         f"{bar(ep_len, lmax, W)}{C['gray']}▏{C['rst']} "
                         f"{ep_len:9.0f}")
            lines.append("")
            lines.append(f"  {C['bold']}ep_ret trend{C['rst']}  "
                         f"{C['cyan']}{spark(hist)}{C['rst']}  "
                         f"{C['dim']}(last {len(hist)}){C['rst']}")
            lines.append("")
            # every named group not consumed by a gauge gets shown verbatim --
            # custom patterns surface their extra diagnostics automatically
            extras = [f"{k} {v}" for k, v in g.items()
                      if v is not None and k not in GAUGE_FIELDS]
            if extras:
                lines.append(f"  {C['dim']}{'   '.join(extras)}{C['rst']}")

        gpu = gpu_stats()
        util = -1
        if gpu:
            t, p, u, pl = gpu
            util = u
            tcol = (C["red"] if t >= args.gpu_limit - 5
                    else C["yellow"] if t >= args.gpu_limit - 15
                    else C["green"])
            lines.append(f"  {C['gray']}┌─ GPU "
                         + "─" * 47 + "┐" + C["rst"])
            lines.append(f"  {C['gray']}│{C['rst']} {C['bold']}temp"
                         f"{C['rst']}  {tcol}{t:>3}°C{C['rst']} "
                         f"{C['gray']}▕{tcol}{bar(t, args.gpu_limit, 20)}"
                         f"{C['gray']}▏{C['rst']} {C['dim']}limit "
                         f"{args.gpu_limit}{C['rst']}      {C['gray']}│"
                         + C["rst"])
            lines.append(f"  {C['gray']}│{C['rst']} {C['bold']}power"
                         f"{C['rst']} {p:5.0f} W {C['dim']}of {pl:.0f} W"
                         f"{C['rst']}   {C['bold']}util{C['rst']} "
                         f"{u:3d}%            {C['gray']}│" + C["rst"])
            lines.append(f"  {C['gray']}└" + "─" * 53 + "┘"
                         + C["rst"])

        # run state: live GPU beats markers; markers tell complete vs crash
        mark = run_marker(path, done_rx)
        if util >= 20:
            status = f"{C['green']}training{C['rst']}"
        elif re.search(r"ABORT|Traceback", mark or ""):
            status = f"{C['red']}{C['bold']}CRASHED/ABORTED{C['rst']}"
        elif mark:
            status = f"{C['cyan']}last run COMPLETE - waiting for next{C['rst']}"
        elif gpu:
            status = f"{C['gray']}idle{C['rst']}"
        else:
            status = f"{C['gray']}no gpu{C['rst']}"
        el = int(time.time() - t0)
        lines.append(f"  {C['gray']}elapsed {el//3600:02d}:"
                     f"{el % 3600 // 60:02d}:{el % 60:02d}  ·  "
                     f"{time.strftime('%H:%M:%S')}  ·  {status}  ·  "
                     f"Ctrl-C to quit{C['rst']}")

        if args.plain:
            print("\n".join(lines))
            print("-" * 60)
        else:
            out = f"{ESC}[H" + "".join(ln + f"{ESC}[K\n" for ln in lines)
            sys.stdout.write(out + f"{ESC}[J")
            sys.stdout.flush()
        if args.once:
            break
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            print()
            break


if __name__ == "__main__":
    main()
