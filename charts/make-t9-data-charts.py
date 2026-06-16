#!/usr/bin/env python3
"""Generate gnuplot bar charts for T9 data backup and restore rates (128GB, cnpg11 + cnpg12)."""

import os, glob, subprocess, sys

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR  = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

CLUSTER_NODE = {
    "cnpg11": "ip-192-168-58-166",
    "cnpg12": "ip-192-168-45-226",
}
CLUSTERS = ["cnpg11", "cnpg12"]
PLUGINS  = ["barman", "opera", "dalibo"]

COLORS = {
    ("barman", "cnpg11"): "#7eb9e8",
    ("barman", "cnpg12"): "#1a6aab",
    ("opera",  "cnpg11"): "#82d98a",
    ("opera",  "cnpg12"): "#1e8c2a",
    ("dalibo", "cnpg11"): "#f7b87a",
    ("dalibo", "cnpg12"): "#d46010",
}

# ── collect ───────────────────────────────────────────────────────────────────
# data[(cluster, plugin, jobs, operation)] = MB/s
data = {}

for run_dir in sorted(glob.glob(os.path.join(RUNS_DIR, "*-full"))):
    info_path = os.path.join(run_dir, "run-info.txt")
    tsv_path  = os.path.join(run_dir, "results.tsv")
    if not os.path.exists(info_path) or not os.path.exists(tsv_path):
        continue
    cluster = None
    for line in open(info_path):
        if line.startswith("cluster:"):
            cluster = line.split(":", 1)[1].strip()
    if cluster not in CLUSTER_NODE:
        continue
    for line in open(tsv_path):
        parts = line.strip().split("\t")
        if len(parts) < 5 or parts[0] == "size_gb":
            continue
        try:
            size_gb   = int(parts[0])
            plugin    = parts[1]
            jobs      = int(parts[2])
            operation = parts[3]
            time_sec  = float(parts[4])
        except ValueError:
            continue
        if time_sec <= 0:
            continue
        mb_s = size_gb * 1024 / time_sec
        key = (cluster, plugin, jobs, operation)
        data[key] = mb_s  # last run wins

print("Collected data points:")
for k, v in sorted(data.items()):
    print(f"  {k} → {v:.1f} MB/s")

# ── helpers ───────────────────────────────────────────────────────────────────
def write_dat(path, jobs_list, subset, plugins_present):
    with open(path, "w") as f:
        header = "# jobs  " + "  ".join(
            f"{p}_{c}" for p in plugins_present for c in CLUSTERS)
        f.write(header + "\n")
        for j in jobs_list:
            row = [str(j)]
            for p in plugins_present:
                for c in CLUSTERS:
                    row.append(f"{subset.get((c, p, j), 0):.2f}")
            f.write("  ".join(row) + "\n")

def make_gp(script_path, png_path, dat_path, jobs_list, plugins_present, title, ymax):
    lines = []
    lines.append(f'set terminal pngcairo size 1200,600 font "Sans,11"')
    lines.append(f'set output "{png_path}"')
    lines.append(f'set title "{title}" font "Sans,13"')
    lines.append( 'set ylabel "MB/s"')
    lines.append( 'set xlabel "Parallel jobs"')
    lines.append( 'set style data histogram')
    lines.append( 'set style histogram clustered gap 2')
    lines.append( 'set style fill solid 0.9 border -1')
    lines.append( 'set boxwidth 0.85')
    lines.append( 'set key outside right top')
    lines.append( 'set grid ytics lt 0 lw 1 lc rgb "#cccccc"')
    lines.append(f'set yrange [0:{ymax:.0f}]')
    lines.append( 'set xtics rotate by -30')

    xtic_str = "(" + ", ".join(
        f'"{j} job{"s" if j != 1 else ""}" {i}' for i, j in enumerate(jobs_list)) + ")"
    lines.append(f'set xtics {xtic_str}')

    plot_parts = []
    col = 2
    for p in plugins_present:
        for c in CLUSTERS:
            color = COLORS.get((p, c), "#888888")
            label = f"{p} / {CLUSTER_NODE[c]}"
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

# ── backup chart ──────────────────────────────────────────────────────────────
backup_data = {(c, p, j): v for (c, p, j, op), v in data.items() if op == "backup"}
backup_jobs = sorted(set(k[2] for k in backup_data))
backup_plugins = [p for p in PLUGINS if any(k[1] == p for k in backup_data)]

backup_dat = os.path.join(OUT_DIR, "t9_backup.dat")
backup_gp  = os.path.join(OUT_DIR, "t9_backup.gp")
backup_png = os.path.join(OUT_DIR, "t9-backup-rate.png")

write_dat(backup_dat, backup_jobs, backup_data, backup_plugins)
make_gp(backup_gp, backup_png, backup_dat, backup_jobs, backup_plugins,
        title="Data Backup Rate by Plugin, Cluster, and Jobs (128GB)",
        ymax=max(backup_data.values()) * 1.25)

# ── restore chart ─────────────────────────────────────────────────────────────
restore_data = {(c, p, j): v for (c, p, j, op), v in data.items() if op == "restore"}
restore_jobs = sorted(set(k[2] for k in restore_data))
restore_plugins = [p for p in PLUGINS if any(k[1] == p for k in restore_data)]

restore_dat = os.path.join(OUT_DIR, "t9_restore.dat")
restore_gp  = os.path.join(OUT_DIR, "t9_restore.gp")
restore_png = os.path.join(OUT_DIR, "t9-restore-rate.png")

write_dat(restore_dat, restore_jobs, restore_data, restore_plugins)
make_gp(restore_gp, restore_png, restore_dat, restore_jobs, restore_plugins,
        title="Data Restore Rate by Plugin, Cluster, and Jobs (128GB)",
        ymax=max(restore_data.values()) * 1.25)

# ── run gnuplot ───────────────────────────────────────────────────────────────
for gp, png in [(backup_gp, backup_png), (restore_gp, restore_png)]:
    result = subprocess.run(["gnuplot", gp], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR {gp}:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"Generated: {png}")
