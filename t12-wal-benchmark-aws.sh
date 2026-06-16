#!/usr/bin/env bash
# T12 WAL Archiving & PITR Restore Benchmark — AWS / EKS
#
# Tests WAL archiving throughput and PITR restore performance under heavy
# write load. Designed to saturate NVMe write capacity and measure how
# each plugin's WAL archiver behaves under sustained high WAL generation.
#
# Usage:
#   source <cluster>-creds.env
#   bash t12-wal-benchmark-aws.sh [--sanity]
#
# --sanity: Quick validation run (4 GB DB, 4 min pgbench, 256 clients, 32 WAL threads).
#           Use to confirm plumbing works before committing to a full run.
#
# Full run: 16 GB DB, 16 min pgbench, 256 clients.
#           Requires node with >= 64 vCPUs (hard gate).
#           Expected instance: c6id.32xlarge (128 vCPU, 256 GiB RAM).
#
# For each plugin (Barman, Opera, Dalibo) and each WAL thread count in
# $WAL_THREAD_COUNTS (configured below for 16 and 24; the full benchmark
# swept 1, 8, 16, 24, and 32 across successive runs):
#   1. Full backup (parallel, untimed setup)
#   2. 20-min pgbench workload — measures:
#        - DB TPS (from pgbench output)
#        - WAL generation rate (pg_current_wal_lsn sampled every 1s)
#        - WAL archive rate (S3 object count sampled every 60s)
#   3. Wait for WAL drain (all generated WAL shipped to S3)
#   4. PITR restore to end of pgbench run — measures:
#        - Time for full base restore
#        - Time for WAL replay
#        - WAL restore rate (S3 GET rate via S3 object polling)
#        - WAL replay rate (pg_current_wal_lsn advance during recovery)
#
# Results written to: ./runs/<timestamp>-t12-{sanity,full}/
#   results.tsv        — timing + rate summary per run
#   pgbench-*.log      — raw pgbench output
#   wal-gen-*.tsv      — LSN samples (timestamp, lsn_bytes, rate_kb_s)
#   wal-archive-*.tsv  — S3 object count samples (timestamp, count, rate_per_min)
#   vmstat-*.txt       — node CPU/mem during each phase
#   diskstats-*.txt    — node NVMe I/O during each phase
#   netstat-*.txt      — node network during each phase

set -euo pipefail

# ── mode ──────────────────────────────────────────────────────────────────────
SANITY=false
ONLY_PLUGIN=""
DISK_TRIGGER_SECS=""   # if set, watchdog fires after this many seconds (test mode)
SKIP_ARCHIVE=false     # if true, skip pgbench/drain — only recreate+backup then restore
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --sanity) SANITY=true ;;
    --plugin)
      shift
      ONLY_PLUGIN="${1:-}"
      case "$ONLY_PLUGIN" in
        barman|opera|dalibo) ;;
        *) echo "ERROR: --plugin must be barman, opera, or dalibo" >&2; exit 1 ;;
      esac
      ;;
    --disk-trigger-secs)
      shift
      DISK_TRIGGER_SECS="${1:-}"
      ;;
    --skip-archive) SKIP_ARCHIVE=true ;;
    *) echo "ERROR: unknown argument: ${1:-}" >&2; exit 1 ;;
  esac
  shift
done

if [ "$SANITY" = "true" ]; then
  echo "=== T12 WAL BENCHMARK — SANITY MODE ==="
else
  echo "=== T12 WAL BENCHMARK — FULL RUN ==="
fi
[ -n "$ONLY_PLUGIN" ] && echo "=== SINGLE PLUGIN: $ONLY_PLUGIN ==="
[ -n "$DISK_TRIGGER_SECS" ] && echo "=== DISK WATCHDOG TEST: fires after ${DISK_TRIGGER_SECS}s ==="
[ "$SKIP_ARCHIVE" = "true" ] && echo "=== SKIP ARCHIVE: restore-only mode ==="

# ── validate required env vars ────────────────────────────────────────────────
for V in KUBECONFIG AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY REGION; do
  if [ -z "${!V:-}" ]; then
    echo "ERROR: $V is not set. Source <cluster>-creds.env first." >&2
    exit 1
  fi
done

S3_BUCKET_BARMAN="${S3_BUCKET_BARMAN:-${CLUSTER_NAME:+${CLUSTER_NAME}-barman}}"
S3_BUCKET_OPERA="${S3_BUCKET_OPERA:-${CLUSTER_NAME:+${CLUSTER_NAME}-opera}}"
S3_BUCKET_DALIBO="${S3_BUCKET_DALIBO:-${CLUSTER_NAME:+${CLUSTER_NAME}-dalibo}}"

for V in S3_BUCKET_BARMAN S3_BUCKET_OPERA S3_BUCKET_DALIBO; do
  if [ -z "${!V:-}" ]; then
    echo "ERROR: $V not set and CLUSTER_NAME unavailable." >&2; exit 1
  fi
done

# ── configuration ─────────────────────────────────────────────────────────────
UPDATES_PER_TXN=20    # pgbench-wal-stress.pgbench batches this many updates per transaction

if [ "$SANITY" = "true" ]; then
  MIN_VCPUS=1          # sanity runs on any instance
  DB_SIZE_GB=4
  SF=260               # ~4 GB
  PGBENCH_CLIENTS=256
  PGBENCH_JOBS=256
  PGBENCH_DURATION=240  # 4 minutes
  WAL_THREAD_COUNTS="32"         # sanity: highest thread count only
  RESTORE_THREAD_COUNTS="32"     # sanity: highest thread count only
  SETTLE=10
  DRAIN_MAX=180         # 3-minute drain cap
  REPLAY_MAX=180        # 3-minute replay cap
  # Same shared_buffers as full run — confirms DB starts and archiving works
  PG_SHARED_BUFFERS="64GB"
  PG_EFFECTIVE_CACHE="96GB"
else
  MIN_VCPUS=64
  DB_SIZE_GB=16
  SF=1040              # ~16 GB — more unique pages per checkpoint, more FPIs in WAL
  PGBENCH_CLIENTS=256
  PGBENCH_JOBS=256
  PGBENCH_DURATION=960  # 16 minutes
  WAL_THREAD_COUNTS="16 24"
  RESTORE_THREAD_COUNTS="16 24"
  SETTLE=60
  # 64 GB shared_buffers on c6id.32xlarge (256 GiB RAM):
  # - Covers the full 16 GB pgbench dataset
  # - Leaves headroom for pgbench_history growth during the 16-min run
  # - Leaves ~192 GB for OS, connections, plugin sidecars, and WAL buffers
  PG_SHARED_BUFFERS="64GB"
  PG_EFFECTIVE_CACHE="96GB"
  DRAIN_MAX=480         # 8-minute drain cap
  REPLAY_MAX=480        # 8-minute replay cap
fi

NS="default"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DALIBO_MANIFEST="${SCRIPT_DIR}/dalibo-manifest-patched.yaml"
RUN_MODE="t8-$([ "$SANITY" = "true" ] && echo sanity || echo full)"
RUN_DIR="${SCRIPT_DIR}/runs/$(date -u +%Y%m%dT%H%M%S)-${RUN_MODE}"
mkdir -p "$RUN_DIR"

RESULTS="${RUN_DIR}/results.tsv"
echo -e "plugin\twal_threads\tphase\tmetric\tvalue\tunit" > "$RESULTS"

echo "Run dir : $RUN_DIR"
echo "DB size : ${DB_SIZE_GB} GB (SF=${SF})"
echo "pgbench : ${PGBENCH_CLIENTS} clients / ${PGBENCH_JOBS} jobs / ${PGBENCH_DURATION}s"
echo "WAL archive threads: ${WAL_THREAD_COUNTS}"
echo "WAL restore threads: ${RESTORE_THREAD_COUNTS}"
echo ""

# ── helpers ───────────────────────────────────────────────────────────────────
primary_of() {
  kubectl get cluster "$1" -n "$NS" -o jsonpath='{.status.currentPrimary}' 2>/dev/null
}

record() {
  # record <plugin> <wal_threads> <phase> <metric> <value> <unit>
  echo -e "$1\t$2\t$3\t$4\t$5\t$6" >> "$RESULTS"
}

wait_backup() {
  local NAME=$1
  for i in $(seq 1 360); do
    local S
    S=$(kubectl get backup "$NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$S" = "completed" ]; then return 0; fi
    if [ "$S" = "failed" ]; then
      echo "  BACKUP FAILED: $NAME — $(kubectl get backup "$NAME" -n "$NS" \
        -o jsonpath='{.status.error}' 2>/dev/null)" >&2
      return 1
    fi
    sleep 5
  done
  echo "  BACKUP TIMEOUT: $NAME" >&2; return 1
}

wait_cluster_ready() {
  kubectl wait --for=condition=Ready cluster/"$1" -n "$NS" --timeout=1800s
}

# ── node stats (from inside postgres container via /proc) ─────────────────────
node_of() {
  kubectl get pod "$(primary_of "$1")" -n "$NS" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

start_node_stats() {
  local LABEL=$1 CLUSTER=$2 DIR="$RUN_DIR/$LABEL"
  mkdir -p "$DIR"
  local POD
  POD=$(primary_of "$CLUSTER")
  local NVME_DISK NET_IFACE
  NVME_DISK=$(cat "$RUN_DIR/devices.env" 2>/dev/null | grep NVME_DISK | cut -d= -f2 || echo "nvme1n1")
  NET_IFACE=$(cat "$RUN_DIR/devices.env" 2>/dev/null | grep NET_IFACE | cut -d= -f2 || echo "eth0")

  kubectl exec "$POD" -n "$NS" -c postgres -- vmstat 1 > "$DIR/vmstat.txt" 2>/dev/null &
  echo $! > "$DIR/vmstat.pid"; disown $!

  kubectl exec "$POD" -n "$NS" -c postgres \
    -- env DISK="$NVME_DISK" sh -c '
    echo "timestamp reads_kb/s writes_kb/s util_pct"
    prev=$(grep " $DISK " /proc/diskstats 2>/dev/null | awk "{print \$6,\$10,\$13}")
    prev_t=$(date +%s%N)
    while true; do
      sleep 1
      cur=$(grep " $DISK " /proc/diskstats 2>/dev/null | awk "{print \$6,\$10,\$13}")
      cur_t=$(date +%s%N)
      dt=$(( (cur_t - prev_t) / 1000000 ))
      [ "$dt" -le 0 ] && prev=$cur && prev_t=$cur_t && continue
      dr=$(echo "$prev $cur $dt" | awk "{printf \"%.0f\", ((\$4-\$1)*512000)/\$7}")
      dw=$(echo "$prev $cur $dt" | awk "{printf \"%.0f\", ((\$5-\$2)*512000)/\$7}")
      io=$(echo "$prev $cur" | awk "{v=\$6-\$3; printf \"%.1f\", v<0?0:v>100?100:v}")
      echo "$(date +%H:%M:%S) $dr $dw $io"
      prev=$cur; prev_t=$cur_t
    done
  ' > "$DIR/diskstats.txt" 2>/dev/null &
  echo $! > "$DIR/diskstats.pid"; disown $!

  kubectl exec "$POD" -n "$NS" -c postgres \
    -- env IFACE="$NET_IFACE" sh -c '
    echo "timestamp rx_kb/s tx_kb/s"
    prev=$(grep "^ *$IFACE:" /proc/net/dev | awk -F: "{print \$2}" | awk "{print \$1,\$9}")
    prev_t=$(date +%s%N)
    while true; do
      sleep 1
      cur=$(grep "^ *$IFACE:" /proc/net/dev | awk -F: "{print \$2}" | awk "{print \$1,\$9}")
      cur_t=$(date +%s%N)
      dt=$(( (cur_t - prev_t) / 1000000 ))
      [ "$dt" -le 0 ] && prev=$cur && prev_t=$cur_t && continue
      echo "$(date +%H:%M:%S) $(echo "$prev $cur $dt" | awk "{printf \"%.0f %.0f\", ((\$3-\$1)*1000)/(\$5*1024), ((\$4-\$2)*1000)/(\$5*1024)}")"
      prev=$cur; prev_t=$cur_t
    done
  ' > "$DIR/netstat.txt" 2>/dev/null &
  disown $!
  echo $! > "$DIR/netstat.pid"
}

stop_node_stats() {
  local DIR="$RUN_DIR/$1"
  local PIDS=()
  for F in vmstat.pid diskstats.pid netstat.pid; do
    local PID; PID=$(cat "$DIR/$F" 2>/dev/null) || true
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    [ -n "$PID" ] && PIDS+=("$PID")
  done
  for PID in "${PIDS[@]}"; do wait "$PID" 2>/dev/null || true; done
}

# ── WAL generation rate sampler (runs in background, 1s intervals) ────────────
start_wal_gen_sampler() {
  local LABEL=$1 CLUSTER=$2 DIR="$RUN_DIR"
  local POD
  POD=$(primary_of "$CLUSTER")
  echo "timestamp lsn_bytes lsn_delta_kb rate_kb_s" > "$DIR/wal-gen-${LABEL}.tsv"
  (
    prev_lsn=0
    prev_t=$(date +%s)
    while true; do
      sleep 1
      lsn_hex=$(kubectl exec "$POD" -n "$NS" -c postgres -- \
        psql -U postgres -tAc "SELECT pg_current_wal_lsn() - '0/0'::pg_lsn;" 2>/dev/null | tr -d '[:space:]')
      [ -z "$lsn_hex" ] && continue
      cur_t=$(date +%s)
      dt=$(( cur_t - prev_t ))
      [ "$dt" -le 0 ] && continue
      delta=$(( lsn_hex - prev_lsn ))
      rate=$(( delta / 1024 / dt ))
      echo "$(date +%H:%M:%S) $lsn_hex $(( delta/1024 )) $rate" >> "$DIR/wal-gen-${LABEL}.tsv"
      prev_lsn=$lsn_hex
      prev_t=$cur_t
    done
  ) &
  echo $! > "$DIR/wal-gen-${LABEL}.pid"; disown $!
}

stop_wal_gen_sampler() {
  local LABEL=$1
  local PID; PID=$(cat "$RUN_DIR/wal-gen-${LABEL}.pid" 2>/dev/null) || true
  [ -n "$PID" ] || return 0
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}

# ── WAL archive rate sampler (S3 object count, 60s intervals) ─────────────────
start_wal_archive_sampler() {
  local LABEL=$1 BUCKET=$2 WAL_PREFIX=$3 DIR="$RUN_DIR"
  echo "timestamp object_count delta rate_per_min" > "$DIR/wal-archive-${LABEL}.tsv"
  (
    prev_count=0
    while true; do
      sleep 60
      count=$(aws s3 ls "s3://${BUCKET}/${WAL_PREFIX}" --recursive --region "$REGION" 2>/dev/null | wc -l || echo 0)
      delta=$(( count - prev_count ))
      echo "$(date +%H:%M:%S) $count $delta $delta" >> "$DIR/wal-archive-${LABEL}.tsv"
      prev_count=$count
    done
  ) &
  echo $! > "$DIR/wal-archive-${LABEL}.pid"; disown $!
}

stop_wal_archive_sampler() {
  local LABEL=$1
  local PID; PID=$(cat "$RUN_DIR/wal-archive-${LABEL}.pid" 2>/dev/null) || true
  [ -n "$PID" ] || return 0
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}

# ── WAL drain: sample archiver every 60s for up to 10 minutes ────────────────
# Writes per-minute samples to wal-drain-<label>.tsv for graphing.
# Primary metric: peak per-minute archival rate.
# Returns when drained or after 10-minute cap.
wait_wal_drain() {
  local CLUSTER=$1 LABEL=$2
  local POD DRAIN_TSV
  POD=$(primary_of "$CLUSTER")
  DRAIN_TSV="$RUN_DIR/wal-drain-${LABEL}.tsv"
  echo "timestamp archived_count delta_per_min last_archived_wal" > "$DRAIN_TSV"
  echo "  Draining WAL (up to 10 min)..."

  local T_START PREV_CNT
  T_START=$(date +%s)
  PREV_CNT=$(kubectl exec "$POD" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "SELECT archived_count FROM pg_stat_archiver;" \
    2>/dev/null | tr -d '[:space:]')

  while true; do
    sleep 60
    local T_NOW RESULT ARCH_CNT LAST_ARCH CUR_WAL DELTA ELAPSED
    T_NOW=$(date +%s)
    ELAPSED=$(( T_NOW - T_START ))
    RESULT=$(kubectl exec "$POD" -n "$NS" -c postgres -- \
      psql -U postgres -tAc \
      "SELECT archived_count, last_archived_wal, pg_walfile_name(pg_current_wal_lsn()) FROM pg_stat_archiver;" \
      2>/dev/null | tr -d '[:space:]')
    ARCH_CNT=$(echo "$RESULT" | cut -d'|' -f1)
    LAST_ARCH=$(echo "$RESULT" | cut -d'|' -f2)
    CUR_WAL=$(echo  "$RESULT" | cut -d'|' -f3)
    DELTA=$(( ${ARCH_CNT:-0} - ${PREV_CNT:-0} ))
    echo "$(date -u +%H:%M:%S) ${ARCH_CNT} ${DELTA} ${LAST_ARCH}" >> "$DRAIN_TSV"
    echo "  drain: +${DELTA}/min archived | last=${LAST_ARCH} | current=${CUR_WAL}"

    # Done when last archived >= current WAL segment
    if [ "$LAST_ARCH" = "$CUR_WAL" ] || [ "$LAST_ARCH" \> "$CUR_WAL" ]; then
      echo "  WAL fully drained in ${ELAPSED}s"
      record "$3" "$4" "wal_drain" "drain_time_s" "$ELAPSED" "s"
      break
    fi
    if [ "$ELAPSED" -ge "$DRAIN_MAX" ]; then
      echo "  WAL drain cap reached (${DRAIN_MAX}s) — continuing with remaining backlog"
      record "$3" "$4" "wal_drain" "drain_time_s" "${DRAIN_MAX}+" "s"
      break
    fi
    PREV_CNT=$ARCH_CNT
  done

  # Compute average per-minute rate from drain TSV — trim first and last samples
  # (first may be partial-minute after drain start; last may straddle drain end)
  local AVG_RATE
  AVG_RATE=$(awk 'NR>1 && $3>0 {a[++n]=$3} END {sum=0; c=0; for(i=2;i<n;i++){sum+=a[i];c++} if(c>0) printf "%.0f",sum/c; else if(n>0) printf "%.0f",a[1]; else print 0}' "$DRAIN_TSV")
  echo "  Avg drain rate: ${AVG_RATE} segs/min (~$(( AVG_RATE * 16 )) MB/min)"
  record "$3" "$4" "wal_drain" "avg_rate_segs_per_min" "$AVG_RATE" "segs/min"
}

# ── Detect full-restore / WAL-replay boundary from postgres logs ──────────────
# PostgreSQL logs "redo starts at <LSN>" when base restore finishes and
# WAL replay begins. We watch kubectl logs until we see that line.
wait_for_wal_replay_start() {
  local POD=$1 LOGFILE=$2
  echo "  Watching for WAL replay start (redo starts at)..."
  local DEADLINE=$(( $(date +%s) + 1800 ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if { kubectl logs "$POD" -n "$NS" --tail=10000 2>/dev/null || true; } | \
       grep -q '"redo starts at\|redo starts at'; then
      local T_NOW
      T_NOW=$(date +%s)
      { kubectl logs "$POD" -n "$NS" --tail=10000 2>/dev/null || true; } | \
        grep '"redo starts at\|redo starts at' | tail -1 >> "$LOGFILE"
      echo "$T_NOW" > "${LOGFILE%.log}.redo-start-epoch"
      echo "  WAL replay started ($({ kubectl logs "$POD" -n "$NS" --tail=10000 2>/dev/null || true; } | \
        grep '"redo starts at\|redo starts at' | tail -1))"
      return 0
    fi
    sleep 2
  done
  echo "  WARNING: timed out waiting for WAL replay start" >&2
}

# ── Detect WAL replay complete ────────────────────────────────────────────────
wait_for_wal_replay_done() {
  local CLUSTER=$1 LOGFILE=$2
  echo "  Waiting for cluster to reach Ready (WAL replay complete)..."
  local T_START
  T_START=$(date +%s)
  kubectl wait --for=condition=Ready cluster/"$CLUSTER" -n "$NS" --timeout=1800s
  local T_END
  T_END=$(date +%s)
  echo "$T_END" > "${LOGFILE%.log}.redo-end-epoch"
  echo "  WAL replay done at $(date -u)"
}

# ── Recreate a single plugin cluster fresh for a new test run ────────────────
# Deletes the cluster, wipes its S3 bucket, recreates the cluster, runs pgbench
# init, and takes a fresh base backup. Called before each per-thread-count test
# to ensure no WAL backlog and a valid base backup for PITR restore.
recreate_cluster() {
  local PLUGIN=$1
  local CLUSTER BUCKET WAL_PREFIX BNAME P
  CLUSTER=$(cluster_for "$PLUGIN")
  BUCKET=$(bucket_for "$PLUGIN")
  WAL_PREFIX=$(wal_prefix_for "$PLUGIN")

  echo "  Recreating ${CLUSTER} for clean test state..."

  # Delete cluster and wipe S3
  kubectl delete cluster "$CLUSTER" -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl wait --for=delete pod -l "cnpg.io/cluster=${CLUSTER}" \
    -n "$NS" --timeout=120s 2>/dev/null || true
  kubectl delete backup --all -n "$NS" --ignore-not-found 2>/dev/null || true
  COUNT=$(aws s3 ls "s3://${BUCKET}/" --recursive --region "$REGION" \
    2>/dev/null | wc -l || echo 0)
  [ "$COUNT" -gt 0 ] && \
    aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" --quiet 2>/dev/null || true
  echo "  S3 cleared ($COUNT objects)"

  # Recreate cluster
  python3 -c "
import subprocess, sys, os
ns = os.environ.get('NS', 'default')
sb = '${PG_SHARED_BUFFERS}'
ec = '${PG_EFFECTIVE_CACHE}'
plugin_map = {
  'barman-pg': ('barman-cloud.cloudnative-pg.io', True,  {'barmanObjectName': 'barman-store'}),
  'opera-pg':  ('pgbackrest.cnpg.opera.com',      False, {'pgbackrestObjectName': 'opera-archive'}),
  'dalibo-pg': ('pgbackrest.dalibo.com',           True,  {'stanzaRef': 'dalibo-stanza'}),
}
name = '${CLUSTER}'
plugin, is_wal, params = plugin_map[name]
param_str = '\n'.join(f'        {k}: {v}' for k, v in params.items())
yaml = f'''apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {name}
  namespace: {ns}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
  postgresql:
    parameters:
      shared_buffers: \"{sb}\"
      effective_cache_size: \"{ec}\"
      max_connections: \"500\"
      max_wal_size: \"16GB\"
      checkpoint_completion_target: \"0.9\"
      checkpoint_timeout: \"2min\"
      synchronous_commit: \"off\"
      wal_compression: \"off\"
  plugins:
  - name: {plugin}
    isWALArchiver: {\"true\" if is_wal else \"false\"}
    parameters:
{param_str}
'''
r = subprocess.run(['kubectl','apply','-n',ns,'-f','-'],
  input=yaml.encode(), capture_output=True)
print(r.stdout.decode().strip())
if r.returncode != 0:
  print(r.stderr.decode().strip(), file=sys.stderr)
  sys.exit(r.returncode)
"
  kubectl wait --for=condition=Ready "cluster/${CLUSTER}" -n "$NS" --timeout=600s

  # Dalibo needs pod restart to reset stanza state
  if [ "$PLUGIN" = "dalibo" ]; then
    kubectl delete pod "$(primary_of "$CLUSTER")" -n "$NS" 2>/dev/null || true
    kubectl wait --for=condition=Ready "cluster/${CLUSTER}" -n "$NS" --timeout=120s
  fi

  # WAL switch + settle
  P=$(primary_of "$CLUSTER")
  kubectl exec "$P" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "SELECT pg_switch_wal();" 2>/dev/null || true
  sleep 20

  # pgbench init
  echo "  pgbench init (SF=${SF})..."
  kubectl exec "$P" -n "$NS" -c postgres -- \
    psql -U postgres -tAc \
    "DROP TABLE IF EXISTS pgbench_accounts,pgbench_branches,pgbench_history,pgbench_tellers CASCADE;" \
    2>/dev/null || true
  kubectl exec "$P" -n "$NS" -c postgres -- \
    pgbench -U postgres -i -s "$SF" --no-vacuum postgres \
    > "$RUN_DIR/pgbench-init-${CLUSTER}.log" 2>&1
  kubectl exec "$P" -n "$NS" -c postgres -- \
    psql -U postgres -c "VACUUM ANALYZE pgbench_accounts;" 2>/dev/null || true

  # Write pgbench stress script
  _PGBENCH_B64=$(echo "$_PGBENCH_SCRIPT" | base64 -w0)
  kubectl exec "$P" -n "$NS" -c postgres -- \
    sh -c "echo '${_PGBENCH_B64}' | base64 -d > /var/run/pgbench-wal-stress.pgbench"

  # Checkpoint + WAL switch before backup
  kubectl exec "$P" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "CHECKPOINT; SELECT pg_switch_wal();" 2>/dev/null || true
  sleep 10

  # Take base backup
  BNAME="setup-${PLUGIN}"
  kubectl delete backup "$BNAME" -n "$NS" --ignore-not-found 2>/dev/null || true
  case $PLUGIN in
    barman) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BNAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
YAML
      ;;
    opera) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BNAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: pgbackrest.cnpg.opera.com
    parameters:
      type: full
YAML
      ;;
    dalibo) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BNAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: pgbackrest.dalibo.com
    parameters:
      backupType: full
YAML
      ;;
  esac
  echo -n "  Base backup... "
  wait_backup "$BNAME" && echo "done" || { echo "FATAL: base backup $BNAME failed" >&2; exit 1; }
}

# ── Clear all three S3 buckets, show count not individual files ──────────────
clear_s3() {
  echo "  Clearing S3 buckets..."
  for BUCKET in "$S3_BUCKET_BARMAN" "$S3_BUCKET_OPERA" "$S3_BUCKET_DALIBO"; do
    COUNT=$(aws s3 ls "s3://${BUCKET}/" --recursive --region "$REGION" \
      2>/dev/null | wc -l || echo 0)
    if [ "$COUNT" -gt 0 ]; then
      aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" --quiet \
        2>/dev/null || true
      echo "  cleared $BUCKET ($COUNT objects)"
    else
      echo "  $BUCKET already empty"
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0: PREFLIGHT
# ══════════════════════════════════════════════════════════════════════════════

echo "── Preflight checks..."

# vCPU gate
VCPUS=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}' 2>/dev/null || echo 0)
echo "  Node vCPUs: $VCPUS (minimum required: $MIN_VCPUS)"
if [ "$VCPUS" -lt "$MIN_VCPUS" ]; then
  echo "ERROR: This benchmark requires at least $MIN_VCPUS vCPUs." >&2
  echo "       Current node has $VCPUS vCPUs." >&2
  echo "       Use --sanity for small-instance testing, or provision a larger node." >&2
  exit 1
fi

# Discover NVMe device and network interface once, write to devices.env
if [ ! -f "$RUN_DIR/devices.env" ]; then
  # Use any running postgres pod to inspect /proc
  PROBE_POD=$(kubectl get pods -n "$NS" -l cnpg.io/cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$PROBE_POD" ]; then
    NVME_DISK=$(kubectl exec "$PROBE_POD" -n "$NS" -c postgres -- \
      awk '$3 ~ /^nvme[0-9]+n1$/ && $3 != "nvme0n1" {print $3; exit}' \
      /proc/diskstats 2>/dev/null || echo "nvme1n1")
    NET_IFACE=$(kubectl exec "$PROBE_POD" -n "$NS" -c postgres -- \
      awk -F: 'NR>2 && $1 !~ /lo/ {gsub(/ /,"",$1); print $1; exit}' \
      /proc/net/dev 2>/dev/null || echo "eth0")
  else
    NVME_DISK="nvme1n1"; NET_IFACE="eth0"
  fi
  echo "NVME_DISK=${NVME_DISK}" > "$RUN_DIR/devices.env"
  echo "NET_IFACE=${NET_IFACE}" >> "$RUN_DIR/devices.env"
  echo "  NVMe disk: $NVME_DISK  Network: $NET_IFACE"
fi

# Write run metadata
cat > "${RUN_DIR}/run-info.txt" <<RUNINFO
run_mode: ${RUN_MODE}
started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
cluster: ${CLUSTER_NAME:-unknown}
region: ${REGION}
node_vcpus: ${VCPUS}
instance_type: $(kubectl get node -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo unknown)
db_size_gb: ${DB_SIZE_GB}
pgbench_clients: ${PGBENCH_CLIENTS}
pgbench_jobs: ${PGBENCH_JOBS}
pgbench_duration_s: ${PGBENCH_DURATION}
wal_thread_counts: ${WAL_THREAD_COUNTS}
buckets: barman=${S3_BUCKET_BARMAN} opera=${S3_BUCKET_OPERA} dalibo=${S3_BUCKET_DALIBO}
RUNINFO

echo "  Preflight OK"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: BOOTSTRAP (skipped if clusters already exist)
# ══════════════════════════════════════════════════════════════════════════════

# Full cleanup before bootstrap — delete all clusters, backups, restore clusters,
# and S3 data from any previously interrupted run.
echo "── Pre-run cleanup..."
echo "  Deleting all clusters and backups..."
kubectl delete backup --all -n "$NS" --ignore-not-found 2>/dev/null || true
kubectl delete cluster --all -n "$NS" --ignore-not-found 2>/dev/null || true
echo "  Waiting for all pods to terminate..."
kubectl wait --for=delete pod -l cnpg.io/podRole -n "$NS" --timeout=120s 2>/dev/null || true
clear_s3
echo "  Pre-run cleanup done"
echo ""

echo "── Bootstrapping clusters..."

# Install CNPG + cert-manager + plugins (reuse logic from t9)
kubectl cnpg install generate | kubectl apply -f - --server-side
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager --timeout=180s

kubectl apply -f \
  https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl rollout status deployment -n cert-manager cert-manager --timeout=600s
kubectl rollout status deployment -n cert-manager cert-manager-webhook --timeout=600s

# Patch and apply Dalibo manifest
DALIBO_RAW=$(mktemp)
LOCAL_DALIBO="${SCRIPT_DIR}/cnpg-plugin-pgbackrest-dalibo/cnpg-plugin-pgbackrest/manifest.yaml"
[ -f "$LOCAL_DALIBO" ] || LOCAL_DALIBO="/home/ubuntu/projects/backups/cnpg-plugin-pgbackrest-dalibo/cnpg-plugin-pgbackrest/manifest.yaml"
cp "$LOCAL_DALIBO" "$DALIBO_RAW"
python3 - "$DALIBO_RAW" "$DALIBO_MANIFEST" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
  docs = list(yaml.safe_load_all(f))
for doc in docs:
  if not doc or not isinstance(doc, dict): continue
  kind = doc.get('kind', ''); name = doc.get('metadata', {}).get('name', '')
  if kind == 'Role' and name == 'leader-election-role':
      doc['metadata']['name'] = 'dalibo-leader-election-role'
  if kind == 'RoleBinding' and name == 'leader-election-rolebinding':
      doc['metadata']['name'] = 'dalibo-leader-election-rolebinding'
      doc['roleRef']['name'] = 'dalibo-leader-election-role'
  if kind == 'Service' and name == 'pgbackrest':
      if doc.get('metadata',{}).get('labels',{}).get('cnpg.io/pluginName') == 'pgbackrest.dalibo.com':
          doc['metadata']['name'] = 'pgbackrest-dalibo'
  if kind == 'Certificate' and name == 'pgbackrest-controller-server':
      doc['spec']['commonName'] = 'pgbackrest-dalibo'
      doc['spec']['dnsNames'] = ['pgbackrest-dalibo','pgbackrest-dalibo.cnpg-system.svc']
with open(sys.argv[2], 'w') as f:
  yaml.dump_all(docs, f, default_flow_style=False)
PYEOF
rm -f "$DALIBO_RAW"

kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/latest/download/manifest.yaml
kubectl apply -f https://github.com/operasoftware/cnpg-plugin-pgbackrest/releases/latest/download/manifest.yaml
kubectl apply -f "$DALIBO_MANIFEST"
kubectl rollout status deployment -n cnpg-system barman-cloud --timeout=120s
kubectl rollout status deployment -n cnpg-system pgbackrest --timeout=120s
kubectl rollout status deployment -n cnpg-system pgbackrest-controller --timeout=120s

# S3 credentials
kubectl create secret generic s3-creds -n "$NS" \
  --from-literal=ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=ACCESS_SECRET_KEY="$AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Plugin object stores
kubectl apply -f - <<'YAML'
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: barman-store
  namespace: default
spec:
  configuration:
    destinationPath: BARMAN_BUCKET_PLACEHOLDER
    s3Credentials:
      accessKeyId:
        name: s3-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-creds
        key: ACCESS_SECRET_KEY
    data:
      compression: snappy
    wal:
      compression: lz4
      maxParallel: 1
YAML
# Re-apply with correct bucket (can't use vars in single-quoted heredoc)
kubectl patch objectstore barman-store -n "$NS" --type=merge \
  -p "{\"spec\":{\"configuration\":{\"destinationPath\":\"s3://${S3_BUCKET_BARMAN}/\"}}}" 2>/dev/null || true

kubectl apply -f - <<'YAML'
---
apiVersion: pgbackrest.cnpg.opera.com/v1
kind: Archive
metadata:
  name: opera-archive
  namespace: default
spec:
  configuration:
    compression: lz4
    repositories:
    - bucket: OPERA_BUCKET_PLACEHOLDER
      destinationPath: /pgbackrest
      endpointURL: OPERA_ENDPOINT_PLACEHOLDER
      s3Credentials:
        region: REGION_PLACEHOLDER
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: ACCESS_SECRET_KEY
    wal:
      maxParallel: 1
YAML
kubectl patch archive opera-archive -n "$NS" --type=merge -p \
  "{\"spec\":{\"configuration\":{\"repositories\":[{\"bucket\":\"${S3_BUCKET_OPERA}\",\"destinationPath\":\"/pgbackrest\",\"endpointURL\":\"https://s3.${REGION}.amazonaws.com\",\"s3Credentials\":{\"region\":\"${REGION}\",\"accessKeyId\":{\"name\":\"s3-creds\",\"key\":\"ACCESS_KEY_ID\"},\"secretAccessKey\":{\"name\":\"s3-creds\",\"key\":\"ACCESS_SECRET_KEY\"}}}]}}}" 2>/dev/null || true

kubectl apply -f - <<'YAML'
---
apiVersion: pgbackrest.dalibo.com/v1
kind: Stanza
metadata:
  name: dalibo-stanza
  namespace: default
spec:
  stanzaConfiguration:
    name: dalibo-pg
    compressConfig:
      type: lz4
    s3Repositories:
    - bucket: DALIBO_BUCKET_PLACEHOLDER
      region: REGION_PLACEHOLDER
      endpoint: DALIBO_ENDPOINT_PLACEHOLDER
      repoPath: /pgbackrest
      secretRef:
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: ACCESS_SECRET_KEY
YAML
kubectl patch stanza dalibo-stanza -n "$NS" --type=merge -p \
  "{\"spec\":{\"stanzaConfiguration\":{\"s3Repositories\":[{\"bucket\":\"${S3_BUCKET_DALIBO}\",\"region\":\"${REGION}\",\"endpoint\":\"https://s3.${REGION}.amazonaws.com\",\"repoPath\":\"/pgbackrest\",\"secretRef\":{\"accessKeyId\":{\"name\":\"s3-creds\",\"key\":\"ACCESS_KEY_ID\"},\"secretAccessKey\":{\"name\":\"s3-creds\",\"key\":\"ACCESS_SECRET_KEY\"}}}]}}}" 2>/dev/null || true

# Create clusters — use apply with properly indented inline YAML via python
# to avoid shell heredoc quoting/indentation issues with variable expansion.
python3 -c "
import subprocess, sys, os

ns = os.environ.get('NS', 'default')
sb = '${PG_SHARED_BUFFERS}'
ec = '${PG_EFFECTIVE_CACHE}'

clusters = [
  ('barman-pg', 'barman-cloud.cloudnative-pg.io', True,  {'barmanObjectName': 'barman-store'}),
  ('opera-pg',  'pgbackrest.cnpg.opera.com',      False, {'pgbackrestObjectName': 'opera-archive'}),
  ('dalibo-pg', 'pgbackrest.dalibo.com',           True,  {'stanzaRef': 'dalibo-stanza'}),
]

for name, plugin, is_wal, params in clusters:
  param_str = '\n'.join(f'        {k}: {v}' for k, v in params.items())
  yaml = f'''apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {name}
  namespace: {ns}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
  postgresql:
    parameters:
      shared_buffers: \"{sb}\"
      effective_cache_size: \"{ec}\"
      max_connections: \"500\"
      max_wal_size: \"16GB\"
      checkpoint_completion_target: \"0.9\"
      checkpoint_timeout: \"2min\"
      synchronous_commit: \"off\"
      wal_compression: \"off\"
  plugins:
  - name: {plugin}
    isWALArchiver: {\"true\" if is_wal else \"false\"}
    parameters:
{param_str}
'''
  r = subprocess.run(['kubectl','apply','-n',ns,'-f','-'],
    input=yaml.encode(), capture_output=True)
  print(r.stdout.decode().strip())
  if r.returncode != 0:
    print(r.stderr.decode().strip(), file=sys.stderr)
    sys.exit(r.returncode)
"

kubectl wait --for=condition=Ready \
  cluster/barman-pg cluster/opera-pg cluster/dalibo-pg \
  -n "$NS" --timeout=600s
echo "  Bootstrap complete"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ── Define pgbench WAL stress script (used by recreate_cluster) ──────────────
# Design: 20 random single-row UPDATEs per transaction reduces ProcarrayGroupUpdate
# contention (the commit-coordination bottleneck at high concurrency) and shifts the
# bottleneck to WAL generation and archiving, which is what this benchmark measures.
# Wide filler writes increase WAL volume per page touched (more FPIs on large DBs).
_PGBENCH_SCRIPT=$(cat <<'PGBENCH'
\set aid1  random(1, :scale * 100000)
\set aid2  random(1, :scale * 100000)
\set aid3  random(1, :scale * 100000)
\set aid4  random(1, :scale * 100000)
\set aid5  random(1, :scale * 100000)
\set aid6  random(1, :scale * 100000)
\set aid7  random(1, :scale * 100000)
\set aid8  random(1, :scale * 100000)
\set aid9  random(1, :scale * 100000)
\set aid10 random(1, :scale * 100000)
\set aid11 random(1, :scale * 100000)
\set aid12 random(1, :scale * 100000)
\set aid13 random(1, :scale * 100000)
\set aid14 random(1, :scale * 100000)
\set aid15 random(1, :scale * 100000)
\set aid16 random(1, :scale * 100000)
\set aid17 random(1, :scale * 100000)
\set aid18 random(1, :scale * 100000)
\set aid19 random(1, :scale * 100000)
\set aid20 random(1, :scale * 100000)
\set delta random(-5000, 5000)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid1;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid2;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid3;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid4;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid5;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid6;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid7;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid8;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid9;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid10;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid11;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid12;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid13;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid14;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid15;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid16;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid17;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid18;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid19;
UPDATE pgbench_accounts SET abalance = abalance + :delta, filler = repeat('x', 84) WHERE aid = :aid20;
END;
PGBENCH
)

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4: WAL ARCHIVING BENCHMARK (sequential per plugin × thread count)
# ══════════════════════════════════════════════════════════════════════════════

# WAL prefix paths per plugin (used for S3 object counting)
wal_prefix_for() {
  case $1 in
    barman) echo "barman-pg/wals/" ;;
    opera)  echo "pgbackrest/archive/opera-pg/" ;;
    dalibo) echo "pgbackrest/archive/dalibo-pg/" ;;
  esac
}
bucket_for() {
  case $1 in
    barman) echo "$S3_BUCKET_BARMAN" ;;
    opera)  echo "$S3_BUCKET_OPERA" ;;
    dalibo) echo "$S3_BUCKET_DALIBO" ;;
  esac
}
cluster_for() {
  case $1 in
    barman) echo "barman-pg" ;;
    opera)  echo "opera-pg" ;;
    dalibo) echo "dalibo-pg" ;;
  esac
}

for PLUGIN in barman opera dalibo; do
  [ -n "$ONLY_PLUGIN" ] && [ "$PLUGIN" != "$ONLY_PLUGIN" ] && continue

  CLUSTER=$(cluster_for "$PLUGIN")
  BUCKET=$(bucket_for "$PLUGIN")
  WAL_PREFIX=$(wal_prefix_for "$PLUGIN")

  # --skip-archive: run only the highest thread count per plugin so we get one
  # good backup+drain per plugin, then exercise all restore thread counts against it.
  THREADS="$WAL_THREAD_COUNTS"
  if [ "$SKIP_ARCHIVE" = "true" ]; then
    THREADS=$(echo "$THREADS" | awk '{print $NF}')
  fi
  FIRST_THREADS=$(echo "$THREADS" | awk '{print $1}')

  for WAL_THREADS in $THREADS; do
    LABEL="${PLUGIN}-w${WAL_THREADS}"
    echo "════════════════════════════════════════════"
    echo "WAL ARCHIVE TEST: ${PLUGIN} WAL threads=${WAL_THREADS}"
    echo "════════════════════════════════════════════"

    # Recreate cluster fresh for each test: wipes S3, reinitializes pgbench tables,
    # and takes a new base backup. Ensures no WAL backlog from prior runs and a
    # valid PITR base for restore.
    recreate_cluster "$PLUGIN"
    BCLUSTER=$(cluster_for "$PLUGIN")

    # ── Apply WAL thread config ────────────────────────────────────────────
    case $PLUGIN in
      barman)
        kubectl patch objectstore barman-store -n "$NS" --type=merge \
          -p "{\"spec\":{\"configuration\":{\"wal\":{\"maxParallel\":${WAL_THREADS}}}}}" \
          2>/dev/null || true ;;
      opera)
        kubectl patch archive opera-archive -n "$NS" --type=merge \
          -p "{\"spec\":{\"configuration\":{\"wal\":{\"maxParallel\":${WAL_THREADS}}}}}" \
          2>/dev/null || true ;;
      dalibo)
        kubectl patch stanza dalibo-stanza -n "$NS" --type=merge \
          -p "{\"spec\":{\"stanzaConfiguration\":{\"processMax\":${WAL_THREADS}}}}" \
          2>/dev/null || true ;;
    esac
    sleep 15   # let sidecar pick up new config

    # ── Capture initial WAL object count baseline ─────────────────────────
    P=$(primary_of "$CLUSTER")
    PRE_WAL_COUNT=$(aws s3 ls "s3://${BUCKET}/${WAL_PREFIX}" \
      --recursive --region "$REGION" 2>/dev/null | wc -l || echo 0)
    PRE_LSN=$(kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc \
      "SELECT pg_current_wal_lsn() - '0/0'::pg_lsn;" 2>/dev/null | tr -d '[:space:]' || echo 0)

    echo "  Baseline: S3 WAL objects=${PRE_WAL_COUNT}, LSN bytes=${PRE_LSN}"

    # ── Start background samplers ──────────────────────────────────────────
    start_node_stats "node-${LABEL}" "$CLUSTER"
    start_wal_gen_sampler "gen-${LABEL}" "$CLUSTER"
    start_wal_archive_sampler "arch-${LABEL}" "$BUCKET" "$WAL_PREFIX"

    # ── Run pgbench workload ───────────────────────────────────────────────
    echo "  Running pgbench: ${PGBENCH_CLIENTS} clients, ${PGBENCH_JOBS} jobs, ${PGBENCH_DURATION}s..."
    T_PGBENCH_START=$(date +%s)

    kubectl exec "$P" -n "$NS" -c postgres -- \
      pgbench -U postgres \
        -f /var/run/pgbench-wal-stress.pgbench \
        -s "$SF" \
        -c "$PGBENCH_CLIENTS" --no-vacuum \
        -j "$PGBENCH_JOBS" \
        -T "$PGBENCH_DURATION" \
        -P 60 \
        postgres \
      > "$RUN_DIR/pgbench-${LABEL}.log" 2>&1 &
    PGBENCH_PID=$!

    # Watchdog: stop pgbench early if disk usage exceeds 70%, or if --disk-trigger-secs fires
    WATCHDOG_START=$(date +%s)
    (
      while kill -0 "$PGBENCH_PID" 2>/dev/null; do
        DISK_PCT=$(kubectl exec "$P" -n "$NS" -c postgres -- \
          df /var/lib/postgresql/data 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
        if [ "${DISK_PCT:-0}" -gt 70 ]; then
          echo "  DISK ${DISK_PCT}% > 70% — stopping pgbench early to protect disk"
          kill "$PGBENCH_PID" 2>/dev/null
          break
        fi
        if [ -n "$DISK_TRIGGER_SECS" ]; then
          ELAPSED_W=$(( $(date +%s) - WATCHDOG_START ))
          if [ "$ELAPSED_W" -ge "$DISK_TRIGGER_SECS" ]; then
            echo "  DISK watchdog test trigger fired after ${ELAPSED_W}s — stopping pgbench early"
            kill "$PGBENCH_PID" 2>/dev/null
            break
          fi
        fi
        sleep 10
      done
    ) &
    disown $!

    wait "$PGBENCH_PID" || true
    T_PGBENCH_END=$(date +%s)
    PGBENCH_ELAPSED=$(( T_PGBENCH_END - T_PGBENCH_START ))

    # Capture PITR target timestamp immediately after pgbench ends
    PITR_TARGET=$(kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc "SELECT now()::text;" 2>/dev/null | tr -d '\n\r')
    POST_LSN=$(kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc \
      "SELECT pg_current_wal_lsn() - '0/0'::pg_lsn;" 2>/dev/null | tr -d '[:space:]' || echo 0)

    # Force WAL switch to ensure last segment is archived
    kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc "SELECT pg_switch_wal();" 2>/dev/null || true

    echo "  pgbench done. PITR target: $PITR_TARGET"
    echo "$PITR_TARGET" > "$RUN_DIR/pitr-target-${LABEL}.txt"

    # ── Parse pgbench TPS → rows/s ────────────────────────────────────────
    # Fall back to last progress line (tps=N) if pgbench was killed early by disk watchdog
    TPS=$(grep "^tps = " "$RUN_DIR/pgbench-${LABEL}.log" | tail -1 | awk '{print $3}')
    if [ -z "$TPS" ] || [ "$TPS" = "0" ]; then
      # pgbench killed early — use last progress line: "progress: N s, TPS tps, ..."
      TPS=$(grep "^progress:" "$RUN_DIR/pgbench-${LABEL}.log" | tail -1 | awk '{print $4}')
    fi
    TPS=${TPS:-0}
    ROWS_PER_S=$(echo "$TPS $UPDATES_PER_TXN" | awk '{printf "%.0f", $1 * $2}')
    echo "  Rows updated/s: $ROWS_PER_S (${TPS} txn/s × ${UPDATES_PER_TXN} updates/txn)"
    record "$PLUGIN" "$WAL_THREADS" "pgbench" "rows_updated_per_s"  "$ROWS_PER_S" "rows_updated/s"
    record "$PLUGIN" "$WAL_THREADS" "pgbench" "tps"         "$TPS"        "tps"
    record "$PLUGIN" "$WAL_THREADS" "pgbench" "duration_s"  "$PGBENCH_ELAPSED" "s"

    # ── Stop during-run samplers ──────────────────────────────────────────
    stop_wal_gen_sampler "gen-${LABEL}"
    stop_wal_archive_sampler "arch-${LABEL}"   # during-run archive samples
    stop_node_stats "node-${LABEL}"

    # ── Summarise during-run rates ────────────────────────────────────────
    TOTAL_WAL_GB=$(echo "$PRE_LSN $POST_LSN" | \
      awk '{printf "%.2f", ($2-$1)/1024/1024/1024}')
    # Average per-minute archival rate during the run — trim first and last samples
    # (first fires before pgbench is fully ramped; last may straddle pgbench end)
    AVG_ARCH_DURING=$(awk 'NR>1 && $3>0 {a[++n]=$3} END {sum=0; c=0; for(i=2;i<n;i++){sum+=a[i];c++} if(c>0) printf "%.0f",sum/c; else if(n>0) printf "%.0f",a[1]; else print 0}' \
      "$RUN_DIR/wal-archive-arch-${LABEL}.tsv" 2>/dev/null || echo "0")
    AVG_WAL_GEN=$(awk 'NR>1 {sum+=$4; n++} END {if(n>0) printf "%.0f", sum/n}' \
      "$RUN_DIR/wal-gen-gen-${LABEL}.tsv" 2>/dev/null || echo "0")
    echo "  WAL generated: ${TOTAL_WAL_GB} GB | avg gen rate: ${AVG_WAL_GEN} KB/s"
    echo "  Avg archive rate during run: ${AVG_ARCH_DURING} segs/min (~$(( AVG_ARCH_DURING * 16 )) MB/min)"
    record "$PLUGIN" "$WAL_THREADS" "wal_gen"    "total_gb"                   "$TOTAL_WAL_GB"       "GB"
    record "$PLUGIN" "$WAL_THREADS" "wal_gen"    "avg_rate_kb_s"              "$AVG_WAL_GEN"        "KB/s"
    record "$PLUGIN" "$WAL_THREADS" "wal_during" "avg_archive_segs_per_min"   "$AVG_ARCH_DURING"    "segs/min"
    record "$PLUGIN" "$WAL_THREADS" "wal_during" "avg_archive_mb_per_min"     "$(( AVG_ARCH_DURING * 16 ))" "MB/min"

    # ── Post-run drain: separate sampler, 10-min cap ──────────────────────
    # The archive-sampler (60s S3 object counts) keeps running during drain
    # to capture per-minute rates separately from the during-run samples.
    echo "  Starting post-run drain (up to 10 min)..."
    start_wal_archive_sampler "post-${LABEL}" "$BUCKET" "$WAL_PREFIX"
    wait_wal_drain "$CLUSTER" "$LABEL" "$PLUGIN" "$WAL_THREADS"
    stop_wal_archive_sampler "post-${LABEL}"

    # Average post-run drain rate — trim first and last samples
    AVG_DRAIN=$(awk 'NR>1 && $3>0 {a[++n]=$3} END {sum=0; c=0; for(i=2;i<n;i++){sum+=a[i];c++} if(c>0) printf "%.0f",sum/c; else if(n>0) printf "%.0f",a[1]; else print 0}' \
      "$RUN_DIR/wal-drain-${LABEL}.tsv" 2>/dev/null || echo "0")
    echo "  Avg drain rate: ${AVG_DRAIN} segs/min (~$(( AVG_DRAIN * 16 )) MB/min)"
    record "$PLUGIN" "$WAL_THREADS" "wal_drain" "avg_drain_segs_per_min"     "$AVG_DRAIN"          "segs/min"
    record "$PLUGIN" "$WAL_THREADS" "wal_drain" "avg_drain_mb_per_min"       "$(( AVG_DRAIN * 16 ))" "MB/min"

    # ── Capture restore target: last archived WAL LSN after drain ────────────
    # Use the last archived WAL segment as PITR target — this maximises WAL replay
    # during restore since all generated WAL has been shipped. We read the LSN
    # corresponding to the last archived WAL from pg_stat_archiver.
    P=$(primary_of "$CLUSTER")
    PITR_TARGET=$(kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc \
      "SELECT (pg_walfile_name_offset(pg_current_wal_lsn())).file_offset::text || ' ' || now()::text;" \
      2>/dev/null | tr -d '\n\r')
    # Simpler: just use current timestamp — all drained WAL predates this
    PITR_TARGET=$(kubectl exec "$P" -n "$NS" -c postgres -- \
      psql -U postgres -tAc "SELECT now()::text;" 2>/dev/null | tr -d '\n\r')
    echo "  PITR target (post-drain): $PITR_TARGET"
    echo "$PITR_TARGET" > "$RUN_DIR/pitr-target-${LABEL}.txt"

    # ── Delete source cluster to stop residual archiving ────────────────────
    echo "  Deleting source cluster ${CLUSTER}..."
    kubectl delete cluster "$CLUSTER" -n "$NS" --ignore-not-found 2>/dev/null || true
    kubectl wait --for=delete pod -l "cnpg.io/cluster=${CLUSTER}" \
      -n "$NS" --timeout=120s 2>/dev/null || true

    sleep "$SETTLE"

  done  # WAL_THREADS loop

  echo ""

done  # PLUGIN loop

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5: PITR RESTORE (sequential per plugin × thread count)
# ══════════════════════════════════════════════════════════════════════════════

echo "════════════════════════════════════════════"
echo "RESTORE PHASE"
echo "════════════════════════════════════════════"
echo ""

for PLUGIN in barman opera dalibo; do
  [ -n "$ONLY_PLUGIN" ] && [ "$PLUGIN" != "$ONLY_PLUGIN" ] && continue

  CLUSTER=$(cluster_for "$PLUGIN")
  BUCKET=$(bucket_for "$PLUGIN")
  WAL_PREFIX=$(wal_prefix_for "$PLUGIN")

  # Barman has no parallel WAL restore — always run once at threads=1
  RESTORE_THREADS="$RESTORE_THREAD_COUNTS"
  [ "$PLUGIN" = "barman" ] && RESTORE_THREADS="1"

  # Read PITR target from the LAST archive thread count — that's the backup
  # still in S3 (each recreate_cluster wipes S3, so only the final run's data survives)
  LAST_ARCHIVE_THREADS=$(echo "$WAL_THREAD_COUNTS" | awk '{print $NF}')
  PITR_TARGET=$(cat "$RUN_DIR/pitr-target-${PLUGIN}-w${LAST_ARCHIVE_THREADS}.txt" 2>/dev/null || echo "")
  if [ -z "$PITR_TARGET" ]; then
    echo "  WARNING: no PITR target for $PLUGIN — skipping restore" >&2
    continue
  fi
  echo "  PITR target for ${PLUGIN}: ${PITR_TARGET}"

  for RST_THREADS in $RESTORE_THREADS; do
    LABEL="${PLUGIN}-rst${RST_THREADS}"
    RST_NAME="rst-${PLUGIN}-r${RST_THREADS}"
    echo "── RESTORE: ${PLUGIN} restore threads=${RST_THREADS}"

    # Apply restore WAL thread count to plugin config before creating restore cluster
    case $PLUGIN in
      opera)
        # Opera: wal.maxParallel on the Archive CR controls both archive-push and archive-get
        kubectl patch archive opera-archive -n "$NS" --type=merge \
          -p "{\"spec\":{\"configuration\":{\"wal\":{\"maxParallel\":${RST_THREADS}}}}}" \
          2>/dev/null || true
        sleep 5
        ;;
      dalibo)
        # Dalibo: stanzaConfiguration.processMax controls WAL parallelism
        kubectl patch stanza dalibo-stanza -n "$NS" --type=merge \
          -p "{\"spec\":{\"stanzaConfiguration\":{\"processMax\":${RST_THREADS}}}}" \
          2>/dev/null || true
        sleep 5
        ;;
    esac

    kubectl delete cluster "$RST_NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
    sleep 10

    # Start stats capture — node stats only if source cluster still exists
    if kubectl get cluster "$CLUSTER" -n "$NS" &>/dev/null; then
      start_node_stats "restore-node-${LABEL}" "$CLUSTER"
    fi
    start_wal_archive_sampler "restore-wal-${LABEL}" "$BUCKET" "$WAL_PREFIX"

    # Quick S3 sanity check before restore
    S3_WAL_COUNT=$(aws s3 ls "s3://${BUCKET}/${WAL_PREFIX}" --recursive --region "$REGION" 2>/dev/null | wc -l || echo 0)
    S3_BAK_COUNT=$(aws s3 ls "s3://${BUCKET}/" --recursive --region "$REGION" 2>/dev/null | grep -v "${WAL_PREFIX}" | wc -l || echo 0)
    echo "  S3 check: ${S3_WAL_COUNT} WAL objects, ${S3_BAK_COUNT} backup objects"

    T_RESTORE_START=$(date +%s)
    RST_LOG="$RUN_DIR/restore-${LABEL}.log"

    # Create restore cluster
    case $PLUGIN in
      barman) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RST_NAME
  namespace: ${NS}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "${PITR_TARGET}"
  externalClusters:
  - name: src
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: barman-store
        serverName: barman-pg
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: false
    parameters:
      barmanObjectName: barman-store
YAML
        ;;
      opera) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RST_NAME
  namespace: ${NS}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "${PITR_TARGET}"
  externalClusters:
  - name: src
    plugin:
      name: pgbackrest.cnpg.opera.com
      parameters:
        pgbackrestObjectName: opera-archive
        stanza: opera-pg
  plugins:
  - name: pgbackrest.cnpg.opera.com
    parameters:
      pgbackrestObjectName: opera-archive
YAML
        ;;
      dalibo) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RST_NAME
  namespace: ${NS}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
  bootstrap:
    recovery:
      source: src
      recoveryTarget:
        targetTime: "${PITR_TARGET}"
        targetTLI: "1"
  externalClusters:
  - name: src
    plugin:
      name: pgbackrest.dalibo.com
      parameters:
        stanzaRef: dalibo-stanza
  plugins:
  - name: pgbackrest.dalibo.com
    parameters:
      stanzaRef: dalibo-stanza
YAML
        ;;
    esac

    # Wait for the recovery pod to appear
    echo "  Waiting for recovery pod..."
    RECOVERY_POD=""
    for i in $(seq 1 60); do
      RECOVERY_POD=$(kubectl get pods -n "$NS" \
        -l "cnpg.io/cluster=${RST_NAME}" \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1)
      [ -n "$RECOVERY_POD" ] && break
      sleep 5
    done

    if [ -n "$RECOVERY_POD" ]; then
      # Watch for "redo starts at" — marks end of base restore, start of WAL replay
      T_BASE_END=""
      T_WAL_START=""
      echo "  Recovery pod: $RECOVERY_POD"
      echo "  Watching for base restore completion..."
      for i in $(seq 1 360); do
        # Use --tail to avoid streaming indefinitely (grep -q exits on match but
        # pipefail holds until kubectl logs exits too — --tail forces a bounded read)
        if { kubectl logs "$RECOVERY_POD" -n "$NS" --tail=10000 2>/dev/null || true; } | \
           grep -q '"redo starts at\|redo starts at'; then
          T_BASE_END=$(date +%s)
          T_WAL_START=$T_BASE_END
          { kubectl logs "$RECOVERY_POD" -n "$NS" --tail=10000 2>/dev/null || true; } | \
            grep '"redo starts at\|redo starts at' | tail -1 >> "$RST_LOG" 2>/dev/null || true
          echo "  Base restore done at $(date -u +%H:%M:%S) — WAL replay starting"
          break
        fi
        sleep 5
      done

      BASE_RESTORE_S=$(( T_BASE_END - T_RESTORE_START ))
      echo "  Base restore time: ${BASE_RESTORE_S}s"
    fi

    # ── WAL replay phase: capped at 10 min, sampled per minute ──────────────
    # Sample pg_last_wal_replay_lsn() every 60s to get per-minute WAL fetch+replay
    # rate. Primary metric: peak segs/min (mirrors backup archive rate).
    REPLAY_TSV="$RUN_DIR/wal-replay-${LABEL}.tsv"
    echo "timestamp lsn_bytes delta_kb rate_kb_s" > "$REPLAY_TSV"
    # REPLAY_MAX set globally in config block
    T_REPLAY_START=${T_WAL_START:-$(date +%s)}
    PREV_REPLAY_LSN=0
    REPLAY_DONE=false

    start_wal_gen_sampler "restore-replay-${LABEL}" "$RST_NAME" 2>/dev/null || true

    echo "  WAL replay in progress (up to 10 min)..."
    while true; do
      sleep 60
      T_NOW= ELAPSED= REPLAY_LSN= DELTA= RATE= CLUSTER_READY=
      T_NOW=$(date +%s)
      ELAPSED=$(( T_NOW - T_REPLAY_START ))

      # Check if cluster became Ready (replay done)
      CLUSTER_READY=$(kubectl get cluster "$RST_NAME" -n "$NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

      # Sample replay LSN
      RST_POD=$(kubectl get pods -n "$NS" -l "cnpg.io/cluster=${RST_NAME}" \
        --no-headers 2>/dev/null | awk '{print $1}' | head -1)
      REPLAY_LSN=0
      if [ -n "$RST_POD" ]; then
        REPLAY_LSN=$(kubectl exec "$RST_POD" -n "$NS" -- \
          psql -U postgres -tAc \
          "SELECT COALESCE(pg_last_wal_replay_lsn(),pg_current_wal_lsn()) - '0/0'::pg_lsn;" \
          2>/dev/null | tr -d '[:space:]' || echo 0)
      fi
      DELTA=$(( (${REPLAY_LSN:-0} - ${PREV_REPLAY_LSN:-0}) / 1024 ))
      RATE=$(( DELTA / 60 ))
      echo "$(date -u +%H:%M:%S) ${REPLAY_LSN:-0} ${DELTA} ${RATE}" >> "$REPLAY_TSV"
      echo "  replay: +${DELTA}KB in last min | rate: ${RATE}KB/s"

      if [ "$CLUSTER_READY" = "True" ]; then
        echo "  WAL replay complete in ${ELAPSED}s"
        REPLAY_DONE=true
        break
      fi
      if [ "$ELAPSED" -ge "$REPLAY_MAX" ]; then
        echo "  WAL replay cap reached (${REPLAY_MAX}s) — continuing"
        break
      fi
      PREV_REPLAY_LSN=${REPLAY_LSN:-0}
    done

    T_RESTORE_END=$(date +%s)
    stop_wal_gen_sampler "restore-replay-${LABEL}" 2>/dev/null || true
    stop_wal_archive_sampler "restore-wal-${LABEL}"
    stop_node_stats "restore-node-${LABEL}"

    TOTAL_RESTORE_S=$(( T_RESTORE_END - T_RESTORE_START ))
    WAL_REPLAY_S=$(( T_RESTORE_END - T_REPLAY_START ))

    # Average per-minute WAL fetch rate — trim first and last samples
    AVG_FETCH=$(awk 'NR>1 && $3>0 {a[++n]=$3} END {sum=0; c=0; for(i=2;i<n;i++){sum+=a[i];c++} if(c>0) printf "%.0f",sum/c; else if(n>0) printf "%.0f",a[1]; else print 0}' \
      "$RUN_DIR/wal-archive-restore-wal-${LABEL}.tsv" 2>/dev/null || echo "0")
    # Average replay rate from LSN sampler — trim first and last samples
    AVG_REPLAY=$(awk 'NR>1 && $4>0 {a[++n]=$4} END {sum=0; c=0; for(i=2;i<n;i++){sum+=a[i];c++} if(c>0) printf "%.0f",sum/c; else if(n>0) printf "%.0f",a[1]; else print 0}' \
      "$REPLAY_TSV" 2>/dev/null || echo "0")

    echo "  Total restore: ${TOTAL_RESTORE_S}s (base: ${BASE_RESTORE_S:-?}s, WAL replay: ${WAL_REPLAY_S}s)"
    echo "  Avg WAL fetch: ${AVG_FETCH} segs/min | Avg WAL replay: ${AVG_REPLAY} KB/s"
    record "$PLUGIN" "$RST_THREADS" "restore" "base_restore_s"         "$BASE_RESTORE_S"   "s"
    record "$PLUGIN" "$RST_THREADS" "restore" "total_restore_s"        "$TOTAL_RESTORE_S"  "s"
    record "$PLUGIN" "$RST_THREADS" "restore" "wal_replay_s"           "$WAL_REPLAY_S"     "s"
    record "$PLUGIN" "$RST_THREADS" "restore" "avg_fetch_segs_per_min" "$AVG_FETCH"        "segs/min"
    record "$PLUGIN" "$RST_THREADS" "restore" "avg_replay_kb_s"        "$AVG_REPLAY"       "KB/s"

    # ── Delete restore cluster ────────────────────────────────────────────
    kubectl delete cluster "$RST_NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
    kubectl wait --for=delete pod -l "cnpg.io/cluster=${RST_NAME}" \
      -n "$NS" --timeout=120s 2>/dev/null || true

    # S3 cleanup and cluster recreation happens at the start of the next archive
    # test run via recreate_cluster — no deferred cleanup needed here.

    sleep "$SETTLE"

  done  # RESTORE_THREADS loop

  echo ""

done  # PLUGIN loop

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════

echo "════════════════════════════════════════════"
echo "T12 COMPLETE"
echo "════════════════════════════════════════════"
echo ""
echo "Results: $RESULTS"
echo ""
column -t -s $'\t' "$RESULTS"
echo ""
echo "Run directory: $RUN_DIR"
echo ""
echo "Files:"
find "$RUN_DIR" -type f | sort | sed 's|'"$RUN_DIR"'/|  |'
