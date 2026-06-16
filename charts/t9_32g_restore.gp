set terminal pngcairo size 1100,600 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/t9-32g-restore.png"
set title "32GB Restore Rate by Plugin, Instance, and Jobs" font "Sans,13"
set ylabel "MB/min"
set xlabel "Parallel jobs"
set style data histogram
set style histogram clustered gap 2
set style fill solid 0.9 border -1
set boxwidth 0.85
set key outside right top
set grid ytics lt 0 lw 1 lc rgb "#cccccc"
set yrange [0:8474]
set xtics ("1 jobs" 0, "8 jobs" 1, "32 jobs" 2)
plot "/home/ubuntu/projects/backups/charts/t9_32g_restore.dat" using 2:xtic(1) title "barman / ip-192-168-19-208" lc rgb "#1a6aab", \
     "" using 3 title "barman / ip-192-168-40-103" lc rgb "#7eb9e8", \
     "" using 4 title "opera / ip-192-168-19-208" lc rgb "#1e8c2a", \
     "" using 5 title "opera / ip-192-168-40-103" lc rgb "#82d98a", \
     "" using 6 title "dalibo / ip-192-168-19-208" lc rgb "#d46010", \
     "" using 7 title "dalibo / ip-192-168-40-103" lc rgb "#f7b87a"
