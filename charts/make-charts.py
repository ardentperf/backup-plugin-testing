#!/usr/bin/env python3
"""Generate gnuplot bar charts for T12 WAL benchmark results."""

import os, glob, subprocess, sys
from collections import defaultdict

RUNS_DIR = os.path.join(os.path.dirname(__file__), "runs")
OUT_DIR   = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

CLUSTER_HOST = {
    "cnpg1wal": "ip-192-168-16-108",
    "cnpg4wal": "ip-192-168-58-26",
}
PLUGINS = ["barman", "opera", "dalibo"]

# ── collect data ──────────────────────────────────────────────────────────────
# archive_during[(cluster, plugin, threads)] = avg_archive_mb_per_min (during pgbench)
# archive_drain[(cluster, plugin, threads)]  = avg_drain_mb_per_min   (during drain)
# restore[(cluster, plugin, threads)]        = avg_replay_kb_s
# wal_gen[(cluster, plugin, threads)]        = avg_rate_kb_s
archive_during = {}
archive_drain  = {}
restore        = {}
restore_replay = {}
wal_gen        = {}

for run_dir in sorted(glob.glob(os.path.join(RUNS_DIR, "*waltest*"))):
    info_path = os.path.join(run_dir, "run-info.txt")
    tsv_path  = os.path.join(run_dir, "results.tsv")
    if not os.path.exists(info_path) or not os.path.exists(tsv_path):
        continue
    cluster = None
    for line in open(info_path):
        if line.startswith("cluster:"):
            cluster = line.split(":", 1)[1].strip()
    if cluster not in CLUSTER_HOST:
        continue
    for line in open(tsv_path):
        parts = line.strip().split("\t")
        if len(parts) < 6 or parts[0] == "plugin":
            continue
        try:
            value = float(parts[4].rstrip('+'))
        except ValueError:
            continue
        plugin, threads, phase, metric = parts[0], int(parts[1]), parts[2], parts[3]
        key = (cluster, plugin, threads)
        if phase == "wal_during" and metric == "avg_archive_mb_per_min":
            archive_during[key] = value
        if phase == "wal_drain" and metric == "avg_drain_mb_per_min":
            archive_drain[key] = value
        if phase == "restore" and metric == "avg_fetch_segs_per_min":
            restore[key] = value * 16          # segs/min × 16 MB/seg → MB/min
        if phase == "restore" and metric == "avg_replay_kb_s":
            restore_replay[key] = value / 1024 * 60  # KB/s → MB/min
        if phase == "wal_gen" and metric == "avg_rate_kb_s":
            wal_gen[key] = value

# ── derived: avg WAL gen rate across all data points ─────────────────────────
all_gen_vals = list(wal_gen.values())
avg_wal_gen_mb_min = (sum(all_gen_vals) / len(all_gen_vals)) / 1024 * 60  # KB/s → MB/min

# ── thread counts present ─────────────────────────────────────────────────────
archive_threads = sorted(set(k[2] for k in archive_during) | set(k[2] for k in archive_drain))
restore_threads = sorted(set(k[2] for k in restore))

clusters = ["cnpg1wal", "cnpg4wal"]

# ── write gnuplot data files ──────────────────────────────────────────────────
def write_dat(path, threads_list, data_dict):
    """
    Rows: one per thread count.
    Cols: thread  barman_cnpg1  barman_cnpg4  opera_cnpg1  opera_cnpg4  dalibo_cnpg1  dalibo_cnpg4
    """
    with open(path, "w") as f:
        f.write("# threads  barman_cnpg1  barman_cnpg4  opera_cnpg1  opera_cnpg4  dalibo_cnpg1  dalibo_cnpg4\n")
        for t in threads_list:
            row = [str(t)]
            for plugin in PLUGINS:
                for cluster in clusters:
                    row.append(str(data_dict.get((cluster, plugin, t), 0)))
            f.write("  ".join(row) + "\n")

during_dat = os.path.join(OUT_DIR, "archive_during.dat")
drain_dat  = os.path.join(OUT_DIR, "archive_drain.dat")
rest_dat   = os.path.join(OUT_DIR, "restore.dat")
write_dat(during_dat, archive_threads, archive_during)
write_dat(drain_dat,  archive_threads, archive_drain)
write_dat(rest_dat,   restore_threads, restore)

# ── gnuplot helpers ───────────────────────────────────────────────────────────
# Colors: barman=blue shades, opera=green shades, dalibo=orange shades
# cnpg1wal = lighter, cnpg4wal = darker
COLORS = {
    ("barman", "cnpg1wal"): "#7eb9e8",
    ("barman", "cnpg4wal"): "#1a6aab",
    ("opera",  "cnpg1wal"): "#82d98a",
    ("opera",  "cnpg4wal"): "#1e8c2a",
    ("dalibo", "cnpg1wal"): "#f7b87a",
    ("dalibo", "cnpg4wal"): "#d46010",
}

def host(cluster):
    return CLUSTER_HOST[cluster]

def make_gp(script_path, dat_path, png_path, threads_list, title, ylabel, ymax,
            avg_line=None, avg_label=None):
    n_clusters = len(clusters)
    n_plugins  = len(PLUGINS)
    n_bars     = n_clusters * n_plugins   # 6 bars per cluster-group
    gap        = 1.5                      # gap between thread-count groups
    bar_width  = 0.9 / n_bars

    lines = []
    lines.append(f'set terminal pngcairo size 1100,600 font "Sans,11"')
    lines.append(f'set output "{png_path}"')
    lines.append(f'set title "{title}" font "Sans,13"')
    lines.append(f'set ylabel "{ylabel}"')
    lines.append( 'set xlabel "Parallel jobs/threads"')
    lines.append( 'set style data histogram')
    lines.append( 'set style histogram clustered gap 2')
    lines.append(f'set style fill solid 0.9 border -1')
    lines.append( 'set boxwidth 0.85')
    lines.append( 'set key outside right top')
    lines.append( 'set grid ytics lt 0 lw 1 lc rgb "#cccccc"')
    lines.append( 'set yrange [0:*]')
    lines.append(f'set yrange [0:{ymax}]')
    lines.append( 'set xtics rotate by -30')

    # x-tic labels: thread count
    xtic_str = "(" + ", ".join(f'"{t} jobs" {i}' for i, t in enumerate(threads_list)) + ")"
    lines.append(f'set xtics {xtic_str}')

    if avg_line is not None:
        lines.append(f'set arrow from graph 0,first {avg_line} to graph 1,first {avg_line} '
                     f'nohead lc rgb "#cc0000" lw 2 dt 2 front')
        lines.append(f'set label "{avg_label}" at graph 0.01, first {avg_line} '
                     f'offset 0,-1 tc rgb "#cc0000" font "Sans,9"')

    # build plot command
    plot_parts = []
    col = 2  # first data col (1-indexed: col 1 = threads label)
    for pi, plugin in enumerate(PLUGINS):
        for ci, cluster in enumerate(clusters):
            color = COLORS[(plugin, cluster)]
            label = f'{plugin} / {host(cluster)}'
            if col == 2:
                plot_parts.append(
                    f'"{dat_path}" using {col}:xtic(1) title "{label}" lc rgb "{color}"'
                )
            else:
                plot_parts.append(
                    f'"" using {col} title "{label}" lc rgb "{color}"'
                )
            col += 1

    lines.append("plot " + ", \\\n     ".join(plot_parts))

    with open(script_path, "w") as f:
        f.write("\n".join(lines) + "\n")

# ── archive during chart ──────────────────────────────────────────────────────
make_gp(
    script_path = os.path.join(OUT_DIR, "archive_during.gp"),
    dat_path    = during_dat,
    png_path    = os.path.join(OUT_DIR, "wal-archive-during.png"),
    threads_list= archive_threads,
    title       = "WAL Archive Rate During pgbench Workload",
    ylabel      = "MB/min archived to S3",
    ymax        = 26000,
    avg_line    = avg_wal_gen_mb_min,
    avg_label   = f"avg WAL gen ({avg_wal_gen_mb_min:.0f} MB/min)",
)

# ── archive drain chart ───────────────────────────────────────────────────────
make_gp(
    script_path = os.path.join(OUT_DIR, "archive_drain.gp"),
    dat_path    = drain_dat,
    png_path    = os.path.join(OUT_DIR, "wal-archive-drain.png"),
    threads_list= archive_threads,
    title       = "WAL Archive Rate During Drain (no new WAL being generated)",
    ylabel      = "MB/min archived to S3",
    ymax        = 26000,
    avg_line    = avg_wal_gen_mb_min,
    avg_label   = f"avg WAL gen ({avg_wal_gen_mb_min:.0f} MB/min)",
)

# ── restore chart ─────────────────────────────────────────────────────────────
restore_dat = os.path.join(OUT_DIR, "restore.dat")
write_dat(restore_dat, restore_threads, restore)
peak_replay_mb_min = max(restore_replay.values())
rest_max = max(max(restore.values()), peak_replay_mb_min) * 1.25
make_gp(
    script_path = os.path.join(OUT_DIR, "restore.gp"),
    dat_path    = restore_dat,
    png_path    = os.path.join(OUT_DIR, "wal-restore-rate.png"),
    threads_list= restore_threads,
    title       = "WAL Fetch Rate During Restore by Plugin, Instance, and Thread Count",
    ylabel      = "MB/min fetched from S3",
    ymax        = rest_max,
    avg_line    = peak_replay_mb_min,
    avg_label   = f"peak replay ({peak_replay_mb_min:.0f} MB/min)",
)

# ── run gnuplot ───────────────────────────────────────────────────────────────
for gp in ["archive_during.gp", "archive_drain.gp", "restore.gp"]:
    path = os.path.join(OUT_DIR, gp)
    result = subprocess.run(["gnuplot", path], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR running {gp}:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"Generated: {path.replace('.gp', '.png')}")

print(f"\nAvg WAL gen rate across all runs: {avg_wal_gen_mb_min:.0f} MB/min")
