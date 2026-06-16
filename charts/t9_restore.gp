set terminal pngcairo size 1200,600 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/t9-restore-rate.png"
set title "Data Restore Rate by Plugin, Cluster, and Jobs (128GB)" font "Sans,13"
set ylabel "MB/s"
set xlabel "Parallel jobs"
set style data histogram
set style histogram clustered gap 2
set style fill solid 0.9 border -1
set boxwidth 0.85
set key outside right top
set grid ytics lt 0 lw 1 lc rgb "#cccccc"
set yrange [0:981]
set xtics rotate by -30
set xtics ("1 job" 0, "8 jobs" 1, "32 jobs" 2, "64 jobs" 3, "128 jobs" 4)
plot "/home/ubuntu/projects/backups/charts/t9_restore.dat" using 2:xtic(1) title "barman / ip-192-168-58-166" lc rgb "#7eb9e8", \
     "" using 3 title "barman / ip-192-168-45-226" lc rgb "#1a6aab", \
     "" using 4 title "opera / ip-192-168-58-166" lc rgb "#82d98a", \
     "" using 5 title "opera / ip-192-168-45-226" lc rgb "#1e8c2a", \
     "" using 6 title "dalibo / ip-192-168-58-166" lc rgb "#f7b87a", \
     "" using 7 title "dalibo / ip-192-168-45-226" lc rgb "#d46010"
