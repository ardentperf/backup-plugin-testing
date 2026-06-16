#!/usr/bin/env python3
"""Single restore chart: barman 1 job + opera 32 jobs, 32g+96g sizes, clustered by size."""

import os, glob, subprocess, sys

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

NODE_SHORT = {
    "ip-192-168-19-208.ec2.internal": "ip-192-168-19-208",
    "ip-192-168-40-103.ec2.internal": "ip-192-168-40-103",
}
NODES  = ["ip-192-168-19-208", "ip-192-168-40-103"]
SIZES  = [32, 96]
# (plugin, jobs) pairs to include
SERIES = [("barman", 1), ("opera", 32)]

# ── collect ───────────────────────────────────────────────────────────────────
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
        if op == "restore" and (plugin, jobs) in SERIES:
            data[(size_gb, plugin, jobs, short)] = size_gb * 1024 / t * 60

# ── data file ─────────────────────────────────────────────────────────────────
# cols: barman_1j_node1  barman_1j_node2  opera_32j_node1  opera_32j_node2
dat_path = os.path.join(OUT_DIR, "t9_restore.dat")
with open(dat_path, "w") as f:
    f.write("# size_gb  barman_1j_19208  barman_1j_40103  opera_32j_19208  opera_32j_40103\n")
    for size in SIZES:
        row = [f"{size}GB"]
        for plugin, jobs in SERIES:
            for node in NODES:
                row.append(f"{data.get((size, plugin, jobs, node), 0):.0f}")
        f.write("  ".join(row) + "\n")

# ── colors ────────────────────────────────────────────────────────────────────
COLORS = {
    ("barman", 1,  "ip-192-168-19-208"): "#1a6aab",
    ("barman", 1,  "ip-192-168-40-103"): "#7eb9e8",
    ("opera",  32, "ip-192-168-19-208"): "#1e8c2a",
    ("opera",  32, "ip-192-168-40-103"): "#82d98a",
}

# ── gnuplot script ────────────────────────────────────────────────────────────
gp_path  = os.path.join(OUT_DIR, "t9_restore.gp")
png_path = os.path.join(OUT_DIR, "t9-restore.png")
ymax = max(data.values()) * 1.25

lines = []
lines.append(f'set terminal pngcairo size 900,550 font "Sans,11"')
lines.append(f'set output "{png_path}"')
lines.append( 'set title "Restore Rate — Barman (1 job) vs Opera (32 jobs), 32GB vs 96GB" font "Sans,13"')
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
for plugin, jobs in SERIES:
    for node in NODES:
        color = COLORS[(plugin, jobs, node)]
        label = f"{plugin} ({jobs}j) / {node}"
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
