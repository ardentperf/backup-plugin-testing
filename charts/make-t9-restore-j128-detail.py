#!/usr/bin/env python3
"""Single-panel chart: backup or restore — network TX/RX (left axis) + disk %util + top-4 proc CPU% (right axis).
Generates one PNG per cluster (cnpg11, cnpg12).

Usage: python3 make-t9-restore-j128-detail.py [operation] [plugin] [jobs]
  operation: restore (default) or backup
  plugin:    opera (default) or barman
  jobs:      128 (default)
"""

import os, subprocess, sys, collections

OUT_DIR = os.path.join(os.path.dirname(__file__), "charts")
os.makedirs(OUT_DIR, exist_ok=True)

RUNS = {
    "cnpg11": os.path.join(os.path.dirname(__file__), "runs", "20260604T013336-full"),
    "cnpg12": os.path.join(os.path.dirname(__file__), "runs", "20260604T014924-full"),
}

OPERATION = sys.argv[1] if len(sys.argv) > 1 else "restore"
PLUGIN    = sys.argv[2] if len(sys.argv) > 2 else "opera"
JOBS      = sys.argv[3] if len(sys.argv) > 3 else "128"
SMOOTH    = 3

# backup reads from disk and uploads (TX); restore downloads (RX) and writes to disk
NET_COL       = 5 if OPERATION == "backup" else 4   # sar col index: txkB/s=5, rxkB/s=4
NET_LABEL     = "TX MB/s" if OPERATION == "backup" else "RX MB/s"

def ts_to_sec(s):
    h, m, sec = s.split(":")
    return int(h) * 3600 + int(m) * 60 + int(sec)

def smooth(rows, window):
    out = []
    for i, (t, v) in enumerate(rows):
        lo = max(0, i - window // 2)
        hi = min(len(rows), i + window // 2 + 1)
        out.append((t, sum(r[1] for r in rows[lo:hi]) / (hi - lo)))
    return out

def load_sar_net(path):
    rows, t0 = [], None
    for line in open(path):
        p = line.split()
        if len(p) < 6 or p[1] != "ens5":
            continue
        try:
            ts  = ts_to_sec(p[0])
            val = float(p[NET_COL]) / 1024
        except (ValueError, IndexError):
            continue
        if t0 is None: t0 = ts
        rows.append((ts - t0, val))
    return smooth(rows, SMOOTH)

def detect_nvme(path):
    """Return the NVMe device with the highest total %util across all snapshots."""
    totals = collections.defaultdict(float)
    for line in open(path):
        p = line.split()
        if len(p) < 2 or not p[0].startswith("nvme"): continue
        try: totals[p[0]] += float(p[-1])
        except ValueError: continue
    return max(totals, key=totals.__getitem__) if totals else "nvme1n1"

def load_iostat_util(path, nvme):
    # iostat -xd 1 has no timestamps; each "Device" header starts a new snapshot.
    # The first snapshot is cumulative since boot — skip it (snapshot_num == 1).
    rows, sec, snapshot_num = [], 0, 0
    for line in open(path):
        p = line.split()
        if not p: continue
        if p[0] == "Device":
            snapshot_num += 1
            sec += 1
            continue
        if snapshot_num > 1 and p[0] == nvme:
            try:
                util = float(p[-1])
            except (ValueError, IndexError):
                continue
            rows.append((sec - 1, util))
    return smooth(rows, SMOOTH)

def load_pidstat_top1(path):
    # sum %CPU per command per second, return top-1 command by total CPU
    per_sec = collections.defaultdict(lambda: collections.defaultdict(float))
    t0 = None
    for line in open(path):
        p = line.split()
        if len(p) < 10: continue
        try:
            ts = ts_to_sec(p[0])
            cpu = float(p[7])
            cmd = p[9]
        except (ValueError, IndexError):
            continue
        if t0 is None: t0 = ts
        elapsed = ts - t0
        per_sec[elapsed][cmd] += cpu

    totals = collections.defaultdict(float)
    for sec_data in per_sec.values():
        for cmd, v in sec_data.items():
            totals[cmd] += v
    top1 = max(totals, key=totals.__getitem__) if totals else None

    if top1 is None:
        return {}
    all_times = sorted(per_sec.keys())
    rows = [(t, per_sec[t].get(top1, 0.0)) for t in all_times]
    return {top1: smooth(rows, SMOOTH)}

COLORS = {
    "rx":        ("#1a6aab", 3),   # blue, thick
    "disk_util": ("#d46010", 2),   # orange
    # proc colors assigned in order
}
PROC_COLORS = ["#1e8c2a", "#9b2ea8", "#c0392b", "#7f8c8d"]

for cluster, run_dir in RUNS.items():
    stats = os.path.join(run_dir, "stats", f"{OPERATION}-{PLUGIN}-j{JOBS}-128gb")

    iostat_path = os.path.join(stats, "iostat.txt")
    nvme    = detect_nvme(iostat_path)
    print(f"  {cluster}: using {nvme} for disk util")
    rx      = load_sar_net(os.path.join(stats, "sar-net.txt"))
    disk    = load_iostat_util(iostat_path, nvme)
    procs   = load_pidstat_top1(os.path.join(stats, "pidstat.txt"))

    max_rx   = max(v for _, v in rx) if rx else 1
    max_cpu  = max((v for rows in procs.values() for _, v in rows), default=0)
    proc_on_left = max_cpu > 100

    # write dat files
    rx_dat = os.path.join(OUT_DIR, f"{cluster}_{OPERATION}_{PLUGIN}_j{JOBS}_net.dat")
    with open(rx_dat, "w") as f:
        for t, v in rx: f.write(f"{t} {v:.3f}\n")

    disk_dat = os.path.join(OUT_DIR, f"{cluster}_{OPERATION}_{PLUGIN}_j{JOBS}_disk.dat")
    with open(disk_dat, "w") as f:
        for t, v in disk: f.write(f"{t} {v:.3f}\n")

    proc_dats = {}
    for cmd, rows in procs.items():
        p = os.path.join(OUT_DIR, f"{cluster}_{OPERATION}_{PLUGIN}_j{JOBS}_proc_{cmd}.dat")
        with open(p, "w") as f:
            for t, v in rows: f.write(f"{t} {v:.3f}\n")
        proc_dats[cmd] = p

    gp_path  = os.path.join(OUT_DIR, f"{cluster}-{OPERATION}-{PLUGIN}-j{JOBS}-detail.gp")
    png_path = os.path.join(OUT_DIR, f"{cluster}-{OPERATION}-{PLUGIN}-j{JOBS}-detail.png")

    lines = []
    lines.append(f'set terminal pngcairo size 1400,550 font "Sans,11"')
    lines.append(f'set output "{png_path}"')
    lines.append(f'set title "{PLUGIN} j{JOBS} {OPERATION.capitalize()} — {cluster} 128GB ({SMOOTH}s smoothed)" font "Sans,13"')
    if proc_on_left:
        y1max = max(max_rx, max_cpu) * 1.15
        y1label = f"Network {NET_LABEL} / CPU%"
    else:
        y1max = max_rx * 1.15
        y1label = f"Network {NET_LABEL}"

    lines.append( 'set xlabel "Elapsed time (seconds)"')
    lines.append(f'set ylabel "{y1label}"')
    lines.append( 'set y2label "Disk Utilization (%)"')
    lines.append(f'set yrange  [0:{y1max:.0f}]')
    lines.append( 'set y2range [0:100]')
    lines.append( 'set xrange  [0:*]')
    lines.append( 'set xtics nomirror')
    lines.append( 'set ytics nomirror')
    lines.append( 'set y2tics nomirror')
    lines.append( 'set key outside right top')
    lines.append( 'set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"')
    lines.append( 'set border 11')  # bottom+left+right, no top

    # line styles
    lines.append(f'set style line 1 lc rgb "{COLORS["rx"][0]}" lw 2')
    lines.append(f'set style line 2 lc rgb "{COLORS["disk_util"][0]}" lw 1.5')
    lines.append(f'set style line 3 lc rgb "{PROC_COLORS[0]}" lw 1')

    proc_axis = "x1y1" if proc_on_left else "x1y2"
    plot_parts = []
    plot_parts.append(f'"{rx_dat}" using 1:2 axes x1y1 with lines ls 1 title "{NET_LABEL}"')
    plot_parts.append(f'"{disk_dat}" using 1:2 axes x1y2 with lines ls 2 title "{nvme} %util"')
    for cmd, dat in proc_dats.items():
        plot_parts.append(f'"{dat}" using 1:2 axes {proc_axis} with lines ls 3 title "{cmd} CPU%"')

    lines.append("plot " + ", \\\n     ".join(plot_parts))

    with open(gp_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    result = subprocess.run(["gnuplot", gp_path], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR ({cluster}):\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"Generated: {png_path}")
