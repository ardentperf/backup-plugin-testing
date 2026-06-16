#!/usr/bin/env python3
"""Generate gnuplot line chart of network TX rate over time for 32-thread runs."""

import os, glob, subprocess, sys
from datetime import datetime

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

CLUSTER_HOST = {
    "cnpg1wal": "ip-192-168-16-108",
    "cnpg4wal": "ip-192-168-58-26",
}
PLUGINS  = ["barman", "opera", "dalibo"]
THREADS  = "32"

# Only use the full-archive runs (not skip-archive), identified by having
# all three plugins with w32 data
TARGET_RUNS = []
for run_dir in sorted(glob.glob(os.path.join(RUNS_DIR, "*waltest*"))):
    info_path = os.path.join(run_dir, "run-info.txt")
    if not os.path.exists(info_path):
        continue
    cluster = None
    thread_counts = []
    for line in open(info_path):
        if line.startswith("cluster:"):
            cluster = line.split(":", 1)[1].strip()
        if line.startswith("wal_thread_counts:"):
            thread_counts = line.split(":", 1)[1].strip().split()
    if cluster in CLUSTER_HOST and THREADS in thread_counts:
        # check all three plugins have data
        if all(os.path.exists(os.path.join(run_dir, f"{p}-w{THREADS}", "netstat.txt"))
               for p in PLUGINS):
            TARGET_RUNS.append((run_dir, cluster))

print(f"Found {len(TARGET_RUNS)} runs with 32-thread data:")
for r, c in TARGET_RUNS:
    print(f"  {c}: {os.path.basename(r)}")

# ── load and normalise netstat data ──────────────────────────────────────────
def load_netstat(path):
    """Return list of (elapsed_seconds, tx_mb_s) trimmed to active TX window."""
    rows = []
    t0 = None
    for line in open(path):
        parts = line.strip().split()
        if len(parts) != 3 or parts[0] == "timestamp":
            continue
        ts = datetime.strptime(parts[0], "%H:%M:%S")
        tx_kb_s = float(parts[2])
        tx_mb_s = tx_kb_s / 1024 * 60
        if t0 is None:
            t0 = ts
        elapsed = (ts.hour * 3600 + ts.minute * 60 + ts.second) - \
                  (t0.hour * 3600 + t0.minute * 60 + t0.second)
        rows.append((elapsed, tx_mb_s))
    return [r for r in rows if r[0] <= 1600]

# smooth with a 15-second rolling average to reduce noise
def smooth(rows, window=15):
    out = []
    for i, (t, v) in enumerate(rows):
        lo = max(0, i - window // 2)
        hi = min(len(rows), i + window // 2 + 1)
        avg = sum(r[1] for r in rows[lo:hi]) / (hi - lo)
        out.append((t, avg))
    return out

# ── write one .dat per (cluster, plugin) ──────────────────────────────────────
# For each cluster, pick the run with the most data lines (most complete)
best_run = {}
for run_dir, cluster in TARGET_RUNS:
    for plugin in PLUGINS:
        path = os.path.join(run_dir, f"{plugin}-w{THREADS}", "netstat.txt")
        n = sum(1 for _ in open(path))
        key = (cluster, plugin)
        if key not in best_run or n > best_run[key][1]:
            best_run[key] = (path, n)

dat_files = {}
max_tx = 0
for (cluster, plugin), (path, _) in best_run.items():
    rows = smooth(load_netstat(path))
    dat_path = os.path.join(OUT_DIR, f"net_{cluster}_{plugin}_w{THREADS}.dat")
    with open(dat_path, "w") as f:
        f.write("# elapsed_s  tx_mb_s\n")
        for t, v in rows:
            f.write(f"{t}  {v:.3f}\n")
            if v > max_tx:
                max_tx = v
    dat_files[(cluster, plugin)] = dat_path

# ── build gnuplot script ──────────────────────────────────────────────────────
# Colors: barman=blue, opera=green, dalibo=orange; cnpg1wal=solid, cnpg4wal=dashed
STYLES = {
    ("barman", "cnpg1wal"): ("#1a6aab", 1),
    ("barman", "cnpg4wal"): ("#7eb9e8", 2),
    ("opera",  "cnpg1wal"): ("#1e8c2a", 1),
    ("opera",  "cnpg4wal"): ("#82d98a", 2),
    ("dalibo", "cnpg1wal"): ("#d46010", 1),
    ("dalibo", "cnpg4wal"): ("#f7b87a", 2),
}

gp_path  = os.path.join(OUT_DIR, "net_32threads.gp")
png_path = os.path.join(OUT_DIR, "net-32threads.png")

lines = []
lines.append(f'set terminal pngcairo size 1200,550 font "Sans,11"')
lines.append(f'set output "{png_path}"')
lines.append( 'set title "Network TX Rate — 32-thread archive runs (15s smoothed)" font "Sans,13"')
lines.append( 'set xlabel "Elapsed time (seconds)"')
lines.append( 'set ylabel "TX MB/min"')
lines.append(f'set yrange [0:{max_tx * 1.15:.0f}]')
lines.append( 'set xrange [0:*]')
lines.append( 'set key outside right top')
lines.append( 'set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"')

# define line styles
idx = 1
style_map = {}
for plugin in PLUGINS:
    for cluster in ["cnpg1wal", "cnpg4wal"]:
        color, dt = STYLES[(plugin, cluster)]
        lines.append(f'set style line {idx} lc rgb "{color}" lw 2 dt {dt}')
        style_map[(plugin, cluster)] = idx
        idx += 1

# plot command — order: barman1, barman4, opera1, opera4, dalibo1, dalibo4
plot_parts = []
for plugin in PLUGINS:
    for cluster in ["cnpg1wal", "cnpg4wal"]:
        key = (cluster, plugin)
        if key not in dat_files:
            continue
        dat  = dat_files[key]
        host = CLUSTER_HOST[cluster]
        ls   = style_map[(plugin, cluster)]
        label = f"{plugin} / {host}"
        plot_parts.append(f'"{dat}" using 1:2 with lines ls {ls} title "{label}"')

lines.append("plot " + ", \\\n     ".join(plot_parts))

with open(gp_path, "w") as f:
    f.write("\n".join(lines) + "\n")

result = subprocess.run(["gnuplot", gp_path], capture_output=True, text=True)
if result.returncode != 0:
    print(f"ERROR:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)
print(f"Generated: {png_path}")
