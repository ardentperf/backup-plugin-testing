set terminal pngcairo size 1400,550 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/cnpg12-backup-opera-j64-detail.png"
set title "opera j64 Backup — cnpg12 128GB (3s smoothed)" font "Sans,13"
set xlabel "Elapsed time (seconds)"
set ylabel "Network TX MB/s / CPU%"
set y2label "Disk Utilization (%)"
set yrange  [0:5175]
set y2range [0:100]
set xrange  [0:*]
set xtics nomirror
set ytics nomirror
set y2tics nomirror
set key outside right top
set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"
set border 11
set style line 1 lc rgb "#1a6aab" lw 2
set style line 2 lc rgb "#d46010" lw 1.5
set style line 3 lc rgb "#1e8c2a" lw 1
plot "/home/ubuntu/projects/backups/charts/cnpg12_backup_opera_j64_net.dat" using 1:2 axes x1y1 with lines ls 1 title "TX MB/s", \
     "/home/ubuntu/projects/backups/charts/cnpg12_backup_opera_j64_disk.dat" using 1:2 axes x1y2 with lines ls 2 title "nvme0n1 %util", \
     "/home/ubuntu/projects/backups/charts/cnpg12_backup_opera_j64_proc_pgbackrest.dat" using 1:2 axes x1y1 with lines ls 3 title "pgbackrest CPU%"
