set terminal pngcairo size 1100,600 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/wal-restore-rate.png"
set title "WAL Fetch Rate During Restore by Plugin, Instance, and Thread Count" font "Sans,13"
set ylabel "MB/min fetched from S3"
set xlabel "Parallel jobs/threads"
set style data histogram
set style histogram clustered gap 2
set style fill solid 0.9 border -1
set boxwidth 0.85
set key outside right top
set grid ytics lt 0 lw 1 lc rgb "#cccccc"
set yrange [0:*]
set yrange [0:528660.0]
set xtics rotate by -30
set xtics ("1 jobs" 0, "8 jobs" 1, "16 jobs" 2, "24 jobs" 3, "32 jobs" 4)
set arrow from graph 0,first 6254.23828125 to graph 1,first 6254.23828125 nohead lc rgb "#cc0000" lw 2 dt 2 front
set label "peak replay (6254 MB/min)" at graph 0.01, first 6254.23828125 offset 0,-1 tc rgb "#cc0000" font "Sans,9"
plot "/home/ubuntu/projects/backups/charts/restore.dat" using 2:xtic(1) title "barman / ip-192-168-16-108" lc rgb "#7eb9e8", \
     "" using 3 title "barman / ip-192-168-58-26" lc rgb "#1a6aab", \
     "" using 4 title "opera / ip-192-168-16-108" lc rgb "#82d98a", \
     "" using 5 title "opera / ip-192-168-58-26" lc rgb "#1e8c2a", \
     "" using 6 title "dalibo / ip-192-168-16-108" lc rgb "#f7b87a", \
     "" using 7 title "dalibo / ip-192-168-58-26" lc rgb "#d46010"
