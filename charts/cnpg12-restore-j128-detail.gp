set terminal pngcairo size 1400,550 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/cnpg12-restore-j128-detail.png"
set title "Opera j128 Restore — cnpg12 128GB (3s smoothed)" font "Sans,13"
set xlabel "Elapsed time (seconds)"
set ylabel "Network RX (MB/s)"
set y2label "CPU / Disk Utilization (%)"
set yrange  [0:1438]
set y2range [0:100]
set xrange  [0:200]
set ytics nomirror
set y2tics
set key outside right top
set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"
set style line 1 lc rgb "#1a6aab" lw 3
set style line 2 lc rgb "#d46010" lw 2 dt 2
set style line 3 lc rgb "#1e8c2a" lw 1 dt 3
set style line 4 lc rgb "#9b2ea8" lw 1 dt 3
set style line 5 lc rgb "#c0392b" lw 1 dt 3
set style line 6 lc rgb "#7f8c8d" lw 1 dt 3
plot "/home/ubuntu/projects/backups/charts/cnpg12_j128_rx.dat" using 1:2 axes x1y1 with lines ls 1 title "RX MB/s", \
     "/home/ubuntu/projects/backups/charts/cnpg12_j128_disk.dat" using 1:2 axes x1y2 with lines ls 2 title "nvme0n1 %util", \
     "/home/ubuntu/projects/backups/charts/cnpg12_j128_proc_0.dat" using 1:2 axes x1y2 with lines ls 3 title "0 CPU%", \
     "/home/ubuntu/projects/backups/charts/cnpg12_j128_proc_78.dat" using 1:2 axes x1y2 with lines ls 4 title "78 CPU%", \
     "/home/ubuntu/projects/backups/charts/cnpg12_j128_proc_32.dat" using 1:2 axes x1y2 with lines ls 5 title "32 CPU%", \
     "/home/ubuntu/projects/backups/charts/cnpg12_j128_proc_11.dat" using 1:2 axes x1y2 with lines ls 6 title "11 CPU%"
