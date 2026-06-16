set terminal pngcairo size 1200,550 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/restore-opera-rx-timeseries.png"
set title "Opera Restore RX Throughput over Time — 128GB (cnpg11, 5s smoothed)" font "Sans,13"
set xlabel "Elapsed time (seconds)"
set ylabel "RX MB/s"
set yrange [0:756]
set xrange [0:150]
set key outside right top
set grid xtics ytics lt 0 lw 1 lc rgb "#cccccc"
set style line 1 lc rgb "#aaaaaa" lw 2
set style line 2 lc rgb "#7eb9e8" lw 2
set style line 3 lc rgb "#1a6aab" lw 2
set style line 4 lc rgb "#1e8c2a" lw 2
set style line 5 lc rgb "#d46010" lw 2
plot "/home/ubuntu/projects/backups/charts/restore_opera_j1_rx.dat" using 1:2 with lines ls 1 title "j1", \
     "/home/ubuntu/projects/backups/charts/restore_opera_j8_rx.dat" using 1:2 with lines ls 2 title "j8", \
     "/home/ubuntu/projects/backups/charts/restore_opera_j32_rx.dat" using 1:2 with lines ls 3 title "j32", \
     "/home/ubuntu/projects/backups/charts/restore_opera_j64_rx.dat" using 1:2 with lines ls 4 title "j64", \
     "/home/ubuntu/projects/backups/charts/restore_opera_j128_rx.dat" using 1:2 with lines ls 5 title "j128"
