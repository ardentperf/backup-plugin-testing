#!/usr/bin/env bash
# Generate system utilization charts for 96GB j32 backup runs.
# Output: charts/backup-j32-utilization.png

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATS="${SCRIPT_DIR}/../runs/20260603T045122-full-96g/stats"
OUT="${SCRIPT_DIR}/backup-j32-utilization.png"

# Extract vmstat (cols: second us sy id wa) — skip 2 headers + 1 boot-sample line
awk 'NR>3 && NF>=16 {print NR-3, $13, $14, $15, $16}' \
    "$STATS/backup-barman-j32-96gb/vmstat.txt" > /tmp/vmstat-barman-j32.dat
awk 'NR>3 && NF>=16 {print NR-3, $13, $14, $15, $16}' \
    "$STATS/backup-opera-j32-96gb/vmstat.txt"  > /tmp/vmstat-opera-j32.dat

# Extract netstat tx in MB/s (col 3 is KB/s)
awk 'NR>1 && NF==3 {print NR-1, $3/1024}' \
    "$STATS/backup-barman-j32-96gb/netstat.txt" > /tmp/netstat-barman-j32.dat
awk 'NR>1 && NF==3 {print NR-1, $3/1024}' \
    "$STATS/backup-opera-j32-96gb/netstat.txt"  > /tmp/netstat-opera-j32.dat

gnuplot <<EOF
set terminal pngcairo size 1400,900 enhanced font "Sans,11"
set output "${OUT}"

set multiplot layout 2,2 title "96GB Backup — j32 — System Utilization" font "Sans,13"

set grid
set key top right

set title "Barman j32 — CPU %"
set xlabel "seconds"
set ylabel "percent"
set yrange [0:100]
plot "/tmp/vmstat-barman-j32.dat" using 1:(\$2+\$3) with filledcurves x1 lc rgb "#cc4444" title "us+sy", \
     "/tmp/vmstat-barman-j32.dat" using 1:5         with lines lw 2 lc rgb "#e8a020" title "wa", \
     "/tmp/vmstat-barman-j32.dat" using 1:4         with lines lw 1 lc rgb "#888888" title "id"

set title "Barman j32 — S3 Upload (TX)"
set ylabel "MB/s"
set yrange [0:200]
plot "/tmp/netstat-barman-j32.dat" using 1:2 with lines lw 2 lc rgb "#4466cc" title "tx MB/s"

set title "Opera j32 — CPU %"
set ylabel "percent"
set yrange [0:100]
plot "/tmp/vmstat-opera-j32.dat" using 1:(\$2+\$3) with filledcurves x1 lc rgb "#cc4444" title "us+sy", \
     "/tmp/vmstat-opera-j32.dat" using 1:5         with lines lw 2 lc rgb "#e8a020" title "wa", \
     "/tmp/vmstat-opera-j32.dat" using 1:4         with lines lw 1 lc rgb "#888888" title "id"

set title "Opera j32 — S3 Upload (TX)"
set ylabel "MB/s"
set yrange [0:200]
plot "/tmp/netstat-opera-j32.dat" using 1:2 with lines lw 2 lc rgb "#4466cc" title "tx MB/s"

unset multiplot
EOF

echo "Written: ${OUT}"
