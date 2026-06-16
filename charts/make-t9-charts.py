#!/usr/bin/env python3
"""Generate gnuplot bar charts for T9 backup/restore benchmark (32g and 96g runs)."""

import os, glob, subprocess, sys

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

NODE_SHORT = {
    "ip-192-168-19-208.ec2.internal": "ip-192-168-19-208",
    "ip-192-168-40-103.ec2.internal": "ip-192-168-40-103",
}
PLUGINS = ["barman", "opera", "dalibo"]

# ── collect data ──────────────────────────────────────────────────────────────
# data[(size_gb, node, plugin, jobs, operation)] = rate_mb_min
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
            size_gb  = int(parts[0])
            plugin   = parts[1]
            jobs     = int(parts[2])
            operation= parts[3]
            time_sec = float(parts[4])
        except ValueError:
            continue
        if time_sec <= 0:
            continue
        rate_mb_min = size_gb * 1024 / time_sec * 60
        key = (size_gb, short, plugin, jobs, operation)
        # keep most recent (runs sorted, last wins)
        data[key] = rate_mb_min

print("Collected data points:")
for k, v in sorted(data.items()):
    print(f"  {k} → {v:.0f} MB/min")

# ── helpers ───────────────────────────────────────────────────────────────────
COLORS = {
    ("barman", "ip-192-168-19-208"): "#1a6aab",
    ("barman", "ip-192-168-40-103"): "#7eb9e8",
    ("opera",  "ip-192-168-19-208"): "#1e8c2a",
    ("opera",  "ip-192-168-40-103"): "#82d98a",
    ("dalibo", "ip-192-168-19-208"): "#d46010",
    ("dalibo", "ip-192-168-40-103"): "#f7b87a",
}
nodes = ["ip-192-168-19-208", "ip-192-168-40-103"]

def write_dat(path, threads_list, data_dict, plugins_present):
    """One row per thread count, cols: label  p1n1  p1n2  p2n1  p2n2 ..."""
    with open(path, "w") as f:
        header = "# jobs  " + "  ".join(
            f"{p}_{n}" for p in plugins_present for n in nodes)
        f.write(header + "\n")
        for t in threads_list:
            row = [str(t)]
            for p in plugins_present:
                for n in nodes:
                    row.append(f"{data_dict.get((n, p, t), 0):.0f}")
            f.write("  ".join(row) + "\n")

def make_gp(script_path, png_path, dat_path, threads_list, plugins_present,
            title, ylabel, ymax):
    lines = []
    lines.append(f'set terminal pngcairo size 1100,600 font "Sans,11"')
    lines.append(f'set output "{png_path}"')
    lines.append(f'set title "{title}" font "Sans,13"')
    lines.append(f'set ylabel "{ylabel}"')
    lines.append( 'set xlabel "Parallel jobs"')
    lines.append( 'set style data histogram')
    lines.append( 'set style histogram clustered gap 2')
    lines.append( 'set style fill solid 0.9 border -1')
    lines.append( 'set boxwidth 0.85')
    lines.append( 'set key outside right top')
    lines.append( 'set grid ytics lt 0 lw 1 lc rgb "#cccccc"')
    lines.append(f'set yrange [0:{ymax:.0f}]')

    xtic_str = "(" + ", ".join(f'"{t} jobs" {i}' for i, t in enumerate(threads_list)) + ")"
    lines.append(f'set xtics {xtic_str}')

    plot_parts = []
    col = 2
    for p in plugins_present:
        for n in nodes:
            color = COLORS.get((p, n), "#888888")
            label = f"{p} / {n}"
            if col == 2:
                plot_parts.append(
                    f'"{dat_path}" using {col}:xtic(1) title "{label}" lc rgb "{color}"')
            else:
                plot_parts.append(
                    f'"" using {col} title "{label}" lc rgb "{color}"')
            col += 1

    lines.append("plot " + ", \\\n     ".join(plot_parts))
    with open(script_path, "w") as f:
        f.write("\n".join(lines) + "\n")

# ── build charts per size_gb × operation ──────────────────────────────────────
size_ops = sorted(set((k[0], k[4]) for k in data))

for size_gb, operation in size_ops:
    # filter to this size+operation
    subset = {(n, p, j): v for (s, n, p, j, op), v in data.items()
              if s == size_gb and op == operation}

    threads_list = sorted(set(k[2] for k in subset))
    plugins_present = [p for p in PLUGINS if any(k[1] == p for k in subset)]

    dat_path    = os.path.join(OUT_DIR, f"t9_{size_gb}g_{operation}.dat")
    gp_path     = os.path.join(OUT_DIR, f"t9_{size_gb}g_{operation}.gp")
    png_path    = os.path.join(OUT_DIR, f"t9-{size_gb}g-{operation}.png")

    write_dat(dat_path, threads_list, subset, plugins_present)

    ymax = max(subset.values()) * 1.25
    make_gp(
        script_path     = gp_path,
        png_path        = png_path,
        dat_path        = dat_path,
        threads_list    = threads_list,
        plugins_present = plugins_present,
        title           = f"{size_gb}GB {operation.capitalize()} Rate by Plugin, Instance, and Jobs",
        ylabel          = "MB/min",
        ymax            = ymax,
    )

    result = subprocess.run(["gnuplot", gp_path], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR {gp_path}:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"Generated: {png_path}")
