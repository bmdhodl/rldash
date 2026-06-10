# rldash

A zero-dependency terminal dashboard for RL training runs. One Python file,
pure stdlib, works on Linux / macOS / Windows. Point it at your training log
and it redraws in place: progress bars, return sparkline, steps/sec, and a
GPU gauge if `nvidia-smi` is on your PATH.

```
╔════════════════════════════════════════════════════════════════╗
║   N = 7   P E N D U L U M                   r l d a s h         ║
║   n7_bal_long.log                                               ║
╚════════════════════════════════════════════════════════════════╝

  update      195/1907   ▕███▏░░░░░░░░░░░░░░░░░░░░░░░░░░▏  10.2%
  steps        102.2M / 1,000M      SPS 327,142

  ep_ret   ▕██████████████████████████████▏     217.1  (peak 217)
  rew/step ▕████████████████████▏░░░░░░░░░▏      2.35
  ep_len   ▕████████████████████████▏░░░░░▏        92

  ep_ret trend  ▁▂▃▄▅▆▇█▇▆▇█  (last 48)

  ┌─ GPU ───────────────────────────────────────────────┐
  │ temp   64°C ▕███████████████▏░░░░▏ limit 85         │
  │ power   304 W   util  48%                           │
  └─────────────────────────────────────────────────────┘
  elapsed 00:42:10  ·  11:24:28  ·  training  ·  Ctrl-C to quit
```

## Quickstart

Grab the one file and run it:

```bash
curl -O https://raw.githubusercontent.com/bmdhodl/rldash/main/rldash.py
python rldash.py --log "runs/*.log"
```

No install, no dependencies. With a glob, it always follows the most
recently modified match — kick off a new run and the dashboard hops over to
it automatically.

## Your log format

Out of the box it parses lines like:

```
upd  205/1907  step 107,479,040  SPS 327,723  ep_ret 220.3  ep_len 94.8  rps 2.32 ...
```

Different trainer? Pass your own regex with named groups. Only `step` is
required; `upd`, `updtot`, `sps`, `ep_ret`, `ep_len`, and `rps` light up
gauges when present — and **any other named group you add shows up
automatically** in the diagnostics footer (`v_loss`, `EV`, `logstd`,
whatever your trainer prints):

```bash
python rldash.py --log train.log \
  --pattern "global step (?P<step>\d+).*?mean reward (?P<ep_ret>-?[\d.]+)"
```

Useful flags:

| flag | what it does |
|---|---|
| `--title "MY RUN"` | header text |
| `--interval 1.0` | refresh seconds |
| `--ep-len-max 650` | fixed full-scale for the ep_len bar |
| `--rps-max 6` | fixed full-scale for the reward/step bar |
| `--gpu-limit 80` | temperature gauge limit |
| `--done-pattern "COMPLETE\|Traceback"` | run-state markers: COMPLETE vs CRASHED in the footer |
| `--plain --once` | print one frame and exit (CI, piping) |

## PowerShell flavor (Windows + WSL)

The original lives in [`powershell/`](powershell/): a PowerShell dashboard
that watches training running **inside WSL** from a native Windows console,
via a small WSL-side snapshot script. Same gauges, same vibe:

```powershell
powershell -NoExit -ExecutionPolicy Bypass -File powershell\watch_rl.ps1
```

## Where this came from

Built live during an N=7 (seven-link) pendulum swing-up campaign on an
RTX 5090 — billions of PPO steps that needed watching without babysitting
raw logs. The details (GPU temp limit front and center, sparkline of
returns, auto-following the newest run) are exactly the things we kept
wanting mid-campaign.

More builds and write-ups: [bmdpat.com](https://bmdpat.com)

## License

MIT
