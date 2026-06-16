set terminal pngcairo size 900,550 font "Sans,11"
set output "/home/ubuntu/projects/backups/charts/t9-backup-32j.png"
set title "Backup Rate at 32 Jobs — Barman vs Opera, 32GB vs 96GB" font "Sans,13"
set ylabel "MB/min"
set xlabel "Database size"
set style data histogram
set style histogram clustered gap 2
set style fill solid 0.9 border -1
set boxwidth 0.85
set key outside right top
set grid ytics lt 0 lw 1 lc rgb "#cccccc"
set yrange [0:22547]
set xtics ("32 GB" 0, "96 GB" 1)
plot "/home/ubuntu/projects/backups/charts/t9_backup_32j.dat" using 2:xtic(1) title "barman / ip-192-168-19-208" lc rgb "#1a6aab", \
     "" using 3 title "barman / ip-192-168-40-103" lc rgb "#7eb9e8", \
     "" using 4 title "opera / ip-192-168-19-208" lc rgb "#1e8c2a", \
     "" using 5 title "opera / ip-192-168-40-103" lc rgb "#82d98a"
