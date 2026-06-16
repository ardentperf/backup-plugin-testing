set terminal pngcairo size 1200,550 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/net-32threads.png"
set title "Network TX Rate — 32-thread archive runs (15s smoothed)" font "Sans,13"
set xlabel "Elapsed time (seconds)"
set ylabel "TX MB/min"
set yrange [0:7648]
set xrange [0:*]
set key outside right top
set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"
set style line 1 lc rgb "#1a6aab" lw 2 dt 1
set style line 2 lc rgb "#7eb9e8" lw 2 dt 2
set style line 3 lc rgb "#1e8c2a" lw 2 dt 1
set style line 4 lc rgb "#82d98a" lw 2 dt 2
set style line 5 lc rgb "#d46010" lw 2 dt 1
set style line 6 lc rgb "#f7b87a" lw 2 dt 2
plot "/home/ubuntu/projects/backups/charts/net_cnpg1wal_barman_w32.dat" using 1:2 with lines ls 1 title "barman / ip-192-168-16-108", \
     "/home/ubuntu/projects/backups/charts/net_cnpg4wal_barman_w32.dat" using 1:2 with lines ls 2 title "barman / ip-192-168-58-26", \
     "/home/ubuntu/projects/backups/charts/net_cnpg1wal_opera_w32.dat" using 1:2 with lines ls 3 title "opera / ip-192-168-16-108", \
     "/home/ubuntu/projects/backups/charts/net_cnpg4wal_opera_w32.dat" using 1:2 with lines ls 4 title "opera / ip-192-168-58-26", \
     "/home/ubuntu/projects/backups/charts/net_cnpg1wal_dalibo_w32.dat" using 1:2 with lines ls 5 title "dalibo / ip-192-168-16-108", \
     "/home/ubuntu/projects/backups/charts/net_cnpg4wal_dalibo_w32.dat" using 1:2 with lines ls 6 title "dalibo / ip-192-168-58-26"
