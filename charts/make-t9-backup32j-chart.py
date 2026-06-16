#!/usr/bin/env python3
"""Single backup chart: 32 jobs, barman+opera, 32g+96g sizes, clustered by size."""

import os, glob, subprocess, sys

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

NODE_SHORT = {
    "ip-192-168-19-208.ec2.internal": "ip-192-168-19-208",
    "ip-192-168-40-103.ec2.internal": "ip-192-168-40-103",
}
PLUGINS = ["barman", "opera"]
NODES   = ["ip-192-168-19-208", "ip-192-168-40-103"]
SIZES   = [32, 96]

# ── collect ───────────────────────────────────────────────────────────────────
# data[(size_gb, plugin, node)] = rate_mb_min
data = {}
for run_dir in sorted(glob.glob(os.path.join(RUNS_DIR, "*-full-*g"))):
    info_path = os.path.join(run_dir, "run-info.txt")
    tsv_path  = os.path.join(run_dir, "results.tsv")
    if not os.path.exists(info_path) or not os.path.exists(tsv_path):
        continue
    node = None
    for line in open(info_path):
        if line.startswith("node:"):
            node = line.split(":", 1)[1].strip()
    if node not in NODE_SHORT:
        continue
    short = NODE_SHORT[node]
    for line in open(tsv_path):
        parts = line.strip().split("\t")
        if len(parts) < 5 or parts[0] == "size_gb":
            continue
        try:
            size_gb=int(parts[0]); plugin=parts[1]; jobs=int(parts[2])
            op=parts[3]; t=float(parts[4])
        except ValueError:
            continue
        if jobs == 32 and op == "backup" and plugin in PLUGINS:
            data[(size_gb, plugin, short)] = size_gb * 1024 / t * 60

# ── data file ─────────────────────────────────────────────────────────────────
# Rows = one per size; cols = barman_node1, barman_node2, opera_node1, opera_node2
# (node2 may be 0 if not present for that size)
dat_path = os.path.join(OUT_DIR, "t9_backup_32j.dat")
with open(dat_path, "w") as f:
    f.write("# size_gb  barman_19208  barman_40103  opera_19208  opera_40103\n")
    for size in SIZES:
        row = [f"{size}GB"]
        for plugin in PLUGINS:
            for node in NODES:
                row.append(f"{data.get((size, plugin, node), 0):.0f}")
        f.write("  ".join(row) + "\n")

# ── colors ────────────────────────────────────────────────────────────────────
COLORS = {
    ("barman", "ip-192-168-19-208"): "#1a6aab",
    ("barman", "ip-192-168-40-103"): "#7eb9e8",
    ("opera",  "ip-192-168-19-208"): "#1e8c2a",
    ("opera",  "ip-192-168-40-103"): "#82d98a",
}

# ── gnuplot script ────────────────────────────────────────────────────────────
gp_path  = os.path.join(OUT_DIR, "t9_backup_32j.gp")
png_path = os.path.join(OUT_DIR, "t9-backup-32j.png")
ymax = max(data.values()) * 1.25

lines = []
lines.append(f'set terminal pngcairo size 900,550 font "Sans,11"')
lines.append(f'set output "{png_path}"')
lines.append( 'set title "Backup Rate at 32 Jobs — Barman vs Opera, 32GB vs 96GB" font "Sans,13"')
lines.append( 'set ylabel "MB/min"')
lines.append( 'set xlabel "Database size"')
lines.append( 'set style data histogram')
lines.append( 'set style histogram clustered gap 2')
lines.append( 'set style fill solid 0.9 border -1')
lines.append( 'set boxwidth 0.85')
lines.append( 'set key outside right top')
lines.append( 'set grid ytics lt 0 lw 1 lc rgb "#cccccc"')
lines.append(f'set yrange [0:{ymax:.0f}]')
lines.append( 'set xtics ("32 GB" 0, "96 GB" 1)')

plot_parts = []
col = 2
for plugin in PLUGINS:
    for node in NODES:
        color = COLORS[(plugin, node)]
        label = f"{plugin} / {node}"
        if col == 2:
            plot_parts.append(
                f'"{dat_path}" using {col}:xtic(1) title "{label}" lc rgb "{color}"')
        else:
            plot_parts.append(
                f'"" using {col} title "{label}" lc rgb "{color}"')
        col += 1

lines.append("plot " + ", \\\n     ".join(plot_parts))

with open(gp_path, "w") as f:
    f.write("\n".join(lines) + "\n")

result = subprocess.run(["gnuplot", gp_path], capture_output=True, text=True)
if result.returncode != 0:
    print(f"ERROR:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)
print(f"Generated: {png_path}")
