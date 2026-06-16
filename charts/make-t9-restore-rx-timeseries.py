#!/usr/bin/env python3
"""Line chart of opera restore RX throughput over time for each job count (cnpg11 128GB run)."""

import os, subprocess, sys

RUN_DIR  = os.path.join(os.path.dirname(__file__), "runs", "20260604T013336-full")
STATS    = os.path.join(RUN_DIR, "stats")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

JOBS = [1, 8, 32, 64, 128]
COLORS = {1: "#aaaaaa", 8: "#7eb9e8", 32: "#1a6aab", 64: "#1e8c2a", 128: "#d46010"}
SMOOTH_WINDOW = 5  # seconds

def load_sar_rx(path):
    """Return list of (elapsed_s, rx_mb_s) from sar -n DEV output."""
    rows = []
    t0 = None
    for line in open(path):
        parts = line.split()
        if len(parts) < 6 or parts[1] != "ens5":
            continue
        try:
            rx_kbs = float(parts[4])
        except ValueError:
            continue
        # parse HH:MM:SS
        try:
            h, m, s = parts[0].split(":")
            ts = int(h) * 3600 + int(m) * 60 + int(s)
        except Exception:
            continue
        if t0 is None:
            t0 = ts
        rows.append((ts - t0, rx_kbs / 1024))
    return rows

def smooth(rows, window):
    out = []
    for i, (t, v) in enumerate(rows):
        lo = max(0, i - window // 2)
        hi = min(len(rows), i + window // 2 + 1)
        avg = sum(r[1] for r in rows[lo:hi]) / (hi - lo)
        out.append((t, avg))
    return out

dat_files = {}
max_rx = 0

for j in JOBS:
    sar_path = os.path.join(STATS, f"restore-opera-j{j}-128gb", "sar-net.txt")
    if not os.path.exists(sar_path):
        print(f"WARNING: missing {sar_path}", file=sys.stderr)
        continue
    rows = smooth(load_sar_rx(sar_path), SMOOTH_WINDOW)
    dat_path = os.path.join(OUT_DIR, f"restore_opera_j{j}_rx.dat")
    with open(dat_path, "w") as f:
        f.write("# elapsed_s  rx_mb_s\n")
        for t, v in rows:
            f.write(f"{t}  {v:.3f}\n")
            if v > max_rx:
                max_rx = v
    dat_files[j] = dat_path

gp_path  = os.path.join(OUT_DIR, "restore-opera-rx-timeseries.gp")
png_path = os.path.join(OUT_DIR, "restore-opera-rx-timeseries.png")

lines = []
lines.append(f'set terminal pngcairo size 1200,550 font "Sans,11"')
lines.append(f'set output "{png_path}"')
lines.append( 'set title "Opera Restore RX Throughput over Time — 128GB (cnpg11, 5s smoothed)" font "Sans,13"')
lines.append( 'set xlabel "Elapsed time (seconds)"')
lines.append( 'set ylabel "RX MB/s"')
lines.append(f'set yrange [0:{max_rx * 1.15:.0f}]')
lines.append( 'set xrange [0:150]')
lines.append( 'set key outside right top')
lines.append( 'set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"')

for idx, j in enumerate(JOBS, 1):
    if j in dat_files:
        lines.append(f'set style line {idx} lc rgb "{COLORS[j]}" lw 2')

plot_parts = []
for idx, j in enumerate(JOBS, 1):
    if j not in dat_files:
        continue
    plot_parts.append(f'"{dat_files[j]}" using 1:2 with lines ls {idx} title "j{j}"')

lines.append("plot " + ", \\\n     ".join(plot_parts))

with open(gp_path, "w") as f:
    f.write("\n".join(lines) + "\n")

result = subprocess.run(["gnuplot", gp_path], capture_output=True, text=True)
if result.returncode != 0:
    print(f"ERROR:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)
print(f"Generated: {png_path}")
