#!/usr/bin/env bash
# T9 Parallel Backup & Restore Scaling Benchmark — AWS / EKS
#
# Installs CNPG, cert-manager, and all three plugins onto a fresh EKS cluster,
# then benchmarks backup and restore.
#
# Usage:
#   source cnpg-benchmark-creds.env   # or export vars manually
#   bash t9-benchmark-aws.sh
#
# Required env vars (all written by aws-setup.sh):
#   KUBECONFIG               path to EKS kubeconfig
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   REGION                   AWS region (e.g. us-east-1)
#   S3_BUCKET_BARMAN
#   S3_BUCKET_OPERA
#   S3_BUCKET_DALIBO
#
# Results written to: ./t9-results.tsv
# Per-run stats:       ./t9-stats/<label>/{iostat,vmstat}.txt

set -euo pipefail

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

trap 'echo ""; echo "ABORTED at $(ts) (exit $?)"' ERR

# ── mode ──────────────────────────────────────────────────────────────────────
# Default:          full benchmark (128 GB, all plugins)
# --sanity          1 GB pass, all plugins (~33 min)
# --sanity barman   1 GB pass, barman only (~11 min)
# --sanity opera    1 GB pass, opera only  (~11 min)
# --sanity dalibo   1 GB pass, dalibo only (~11 min)
SANITY=false
SANITY_PLUGIN=""   # empty = all plugins
if [ "${1:-}" = "--sanity" ]; then
  SANITY=true
  SANITY_PLUGIN="${2:-}"
  if [ -n "$SANITY_PLUGIN" ]; then
    echo "=== SANITY MODE (1 GB, plugin: ${SANITY_PLUGIN}) ==="
  else
    echo "=== SANITY MODE (1 GB, all plugins) ==="
  fi
fi

# ── validate required vars ────────────────────────────────────────────────────
for V in KUBECONFIG AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY REGION; do
  if [ -z "${!V:-}" ]; then
    echo "ERROR: $V is not set. Source <cluster>-creds.env first." >&2
    exit 1
  fi
done

# Bucket names default to <CLUSTER_NAME>-{barman,opera,dalibo} when CLUSTER_NAME
# is set (written by aws-setup.sh into the creds file). Override individually
# by setting S3_BUCKET_* env vars before sourcing or running the script.
S3_BUCKET_BARMAN="${S3_BUCKET_BARMAN:-${CLUSTER_NAME:+${CLUSTER_NAME}-barman}}"
S3_BUCKET_OPERA="${S3_BUCKET_OPERA:-${CLUSTER_NAME:+${CLUSTER_NAME}-opera}}"
S3_BUCKET_DALIBO="${S3_BUCKET_DALIBO:-${CLUSTER_NAME:+${CLUSTER_NAME}-dalibo}}"

for V in S3_BUCKET_BARMAN S3_BUCKET_OPERA S3_BUCKET_DALIBO; do
  if [ -z "${!V:-}" ]; then
    echo "ERROR: $V is not set and CLUSTER_NAME is not available to derive a default." >&2
    echo "       Set S3_BUCKET_* vars explicitly or ensure CLUSTER_NAME is set." >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DALIBO_MANIFEST="${SCRIPT_DIR}/dalibo-manifest-patched.yaml"

# Each run gets its own timestamped directory for results + stats
RUN_MODE="full"
[ "$SANITY" = "true" ] && RUN_MODE="sanity"
RUN_DIR="${SCRIPT_DIR}/runs/$(date -u +%Y%m%dT%H%M%S)-${RUN_MODE}"
mkdir -p "$RUN_DIR"

exec > >(tee -a "${RUN_DIR}/run.log") 2>&1

RESULTS="${RUN_DIR}/results.tsv"
STATS_DIR="${RUN_DIR}/stats"
mkdir -p "$STATS_DIR"
echo -e "size_gb\tplugin\tjobs\toperation\ttime_sec" > "$RESULTS"

# Also write a run metadata file
NODE_INSTANCE_ID=$(kubectl get node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
NODE_INSTANCE_TYPE=$(kubectl get node -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")
cat > "${RUN_DIR}/run-info.txt" <<RUNINFO
run_mode: ${RUN_MODE}
started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
cluster: ${CLUSTER_NAME:-unknown}
region: ${REGION}
node: ${NODE_INSTANCE_ID}
instance_type: ${NODE_INSTANCE_TYPE}
buckets: barman=${S3_BUCKET_BARMAN} opera=${S3_BUCKET_OPERA} dalibo=${S3_BUCKET_DALIBO}
kubeconfig: ${KUBECONFIG}
RUNINFO

CTX=""   # use default context from KUBECONFIG
SETTLE=60   # seconds between runs (S3 is fast; less settling needed than local disk)
[ "$SANITY" = "true" ] && SETTLE=15
NS="default"

echo "=== T9 AWS Benchmark === $(ts)"
echo "Kubeconfig : $KUBECONFIG"
echo "Region     : $REGION"
echo "Buckets    : $S3_BUCKET_BARMAN  $S3_BUCKET_OPERA  $S3_BUCKET_DALIBO"
echo "Run dir    : $RUN_DIR"
echo "Results    : $RESULTS"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0: ENVIRONMENT BOOTSTRAP
# ══════════════════════════════════════════════════════════════════════════════

install_prerequisites() {
  echo "── Installing CNPG..."
  kubectl cnpg install generate \
    | kubectl apply -f - --server-side
  kubectl rollout status deployment -n cnpg-system cnpg-controller-manager \
    --timeout=180s

  echo "── Installing cert-manager..."
  kubectl apply -f \
    https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  # quay.io (cert-manager's registry) has occasional outages. Wait up to 10 min
  # for image pulls to succeed before declaring failure.
  kubectl rollout status deployment -n cert-manager cert-manager --timeout=600s
  kubectl rollout status deployment -n cert-manager cert-manager-webhook --timeout=600s

  echo "── Patching Dalibo manifest (unique role/service names)..."
  # Dalibo has no published release manifest — use the local repo copy.
  # The patched file ($DALIBO_MANIFEST) is written next to this script.
  DALIBO_RAW=$(mktemp)
  LOCAL_DALIBO="/home/ubuntu/projects/backups/cnpg-plugin-pgbackrest-dalibo/cnpg-plugin-pgbackrest/manifest.yaml"
  if [ ! -f "$LOCAL_DALIBO" ]; then
    echo "ERROR: Dalibo manifest not found at $LOCAL_DALIBO" >&2
    echo "       Clone the repo or copy manifest.yaml to that path." >&2
    exit 1
  fi
  cp "$LOCAL_DALIBO" "$DALIBO_RAW"
  python3 - "$DALIBO_RAW" "$DALIBO_MANIFEST" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    docs = list(yaml.safe_load_all(f))

for doc in docs:
    if not doc or not isinstance(doc, dict):
        continue
    kind = doc.get('kind', '')
    name = doc.get('metadata', {}).get('name', '')
    # Rename conflicting Role
    if kind == 'Role' and name == 'leader-election-role':
        doc['metadata']['name'] = 'dalibo-leader-election-role'
    # Rename conflicting RoleBinding
    if kind == 'RoleBinding' and name == 'leader-election-rolebinding':
        doc['metadata']['name'] = 'dalibo-leader-election-rolebinding'
        for s in doc.get('roleRef', {}):
            pass
        doc['roleRef']['name'] = 'dalibo-leader-election-role'
    # Rename conflicting Service and fix its cert annotations
    if kind == 'Service' and name == 'pgbackrest':
        labels = doc.get('metadata', {}).get('labels', {})
        if labels.get('cnpg.io/pluginName') == 'pgbackrest.dalibo.com':
            doc['metadata']['name'] = 'pgbackrest-dalibo'
    # Fix server Certificate DNS names to match renamed service
    if kind == 'Certificate' and name == 'pgbackrest-controller-server':
        doc['spec']['commonName'] = 'pgbackrest-dalibo'
        doc['spec']['dnsNames'] = [
            'pgbackrest-dalibo',
            'pgbackrest-dalibo.cnpg-system.svc',
        ]

with open(sys.argv[2], 'w') as f:
    yaml.dump_all(docs, f, default_flow_style=False)
PYEOF
  rm -f "$DALIBO_RAW"

  echo "── Installing plugins (Barman, Opera, Dalibo)..."
  kubectl apply -f \
    https://github.com/cloudnative-pg/plugin-barman-cloud/releases/latest/download/manifest.yaml
  kubectl apply -f \
    https://github.com/operasoftware/cnpg-plugin-pgbackrest/releases/latest/download/manifest.yaml
  kubectl apply -f "$DALIBO_MANIFEST"

  kubectl rollout status deployment -n cnpg-system barman-cloud --timeout=120s
  kubectl rollout status deployment -n cnpg-system pgbackrest --timeout=120s
  kubectl rollout status deployment -n cnpg-system pgbackrest-controller --timeout=120s

  echo "── Creating S3 credentials secret..."
  kubectl create secret generic s3-creds \
    --namespace="$NS" \
    --from-literal=ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=ACCESS_SECRET_KEY="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "── Creating plugin object store configs..."
  kubectl apply -f - <<YAML
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: barman-store
  namespace: ${NS}
spec:
  configuration:
    destinationPath: s3://${S3_BUCKET_BARMAN}/
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
---
apiVersion: pgbackrest.cnpg.opera.com/v1
kind: Archive
metadata:
  name: opera-archive
  namespace: ${NS}
spec:
  configuration:
    compression: lz4
    repositories:
    - bucket: ${S3_BUCKET_OPERA}
      destinationPath: /pgbackrest
      endpointURL: https://s3.${REGION}.amazonaws.com
      s3Credentials:
        region: ${REGION}
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: ACCESS_SECRET_KEY
---
apiVersion: pgbackrest.dalibo.com/v1
kind: Stanza
metadata:
  name: dalibo-stanza
  namespace: ${NS}
spec:
  stanzaConfiguration:
    name: dalibo-pg
    compressConfig:
      type: lz4
    s3Repositories:
      - bucket: ${S3_BUCKET_DALIBO}
        region: ${REGION}
        endpoint: https://s3.${REGION}.amazonaws.com
        repoPath: /pgbackrest
        secretRef:
          accessKeyId:
            name: s3-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: s3-creds
            key: ACCESS_SECRET_KEY
YAML

  echo "Bootstrap complete."
  echo ""
}

# Create a single source cluster for the given plugin, wait for Ready.
create_source_cluster() {
  local CLUSTER="src-pg"
  echo "  Creating source cluster (no plugin — plugin attached after pgbench init)..."
  kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER}
  namespace: ${NS}
spec:
  instances: 1
  storage:
    size: 200Gi
    storageClass: local-nvme
YAML
  kubectl wait --for=condition=Ready cluster/${CLUSTER} \
    -n "$NS" --timeout=600s
  echo "  Source cluster ready"
}

# Patch the backup plugin onto the running src-pg cluster after pgbench init.
# This ensures archive-push starts with zero WAL backlog — only the small amount
# of WAL generated during the timed backups needs to be archived.
attach_plugin() {
  local PLUGIN_LABEL=$1
  local CLUSTER="src-pg"
  echo "  Attaching ${PLUGIN_LABEL} plugin to source cluster..."
  case $PLUGIN_LABEL in
    barman)
      kubectl patch cluster "$CLUSTER" -n "$NS" --type=merge -p '{
        "spec": {
          "plugins": [{"name": "barman-cloud.cloudnative-pg.io", "isWALArchiver": true,
            "parameters": {"barmanObjectName": "barman-store"}}]
        }
      }'
      ;;
    opera)
      kubectl patch cluster "$CLUSTER" -n "$NS" --type=merge -p '{
        "spec": {
          "plugins": [{"name": "pgbackrest.cnpg.opera.com",
            "parameters": {"pgbackrestObjectName": "opera-archive"}}]
        }
      }'
      ;;
    dalibo)
      kubectl patch cluster "$CLUSTER" -n "$NS" --type=merge -p '{
        "spec": {
          "plugins": [{"name": "pgbackrest.dalibo.com", "isWALArchiver": true,
            "parameters": {"stanzaRef": "dalibo-stanza"}}]
        }
      }'
      ;;
  esac
  # Wait for cluster to be Ready again after plugin sidecar injection
  kubectl wait --for=condition=Ready cluster/${CLUSTER} \
    -n "$NS" --timeout=300s
  echo "  Plugin attached"
}

# Delete the source cluster and wait for disk space to be physically reclaimed.
# The PVC object disappearing is not enough — local-path-provisioner removes
# the directory asynchronously. We wait until the NVMe has enough free space
# to accommodate the restore (need at least SIZE_GB + 20% headroom).
# delete_cluster NAME SIZE_GB
# Deletes a cluster by name, waits for pod termination, PVC deletion, and
# filesystem reclaim. SIZE_GB controls the extra wait for disk reclaim —
# local-path-provisioner removes directories asynchronously after PVC deletion.
delete_cluster() {
  local NAME=$1 SIZE_GB="${2:-0}"
  echo "  Deleting cluster ${NAME}..."
  kubectl delete cluster "$NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
  # Wait for pods to terminate
  kubectl wait --for=delete pod -l "cnpg.io/cluster=${NAME}" \
    -n "$NS" --timeout=120s 2>/dev/null || true
  # Wait for PVC object to disappear
  for i in $(seq 1 30); do
    PVC=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | grep -c "^${NAME}" || true)
    [ "$PVC" -eq 0 ] && break || true
    sleep 5
  done
  # Wait for local-path-provisioner's helper pod to finish rm -rf.
  # The provisioner logs "deleted" when the helper pod starts, not when it
  # finishes. At 128GB with millions of pgbench files this takes several minutes.
  # Spin up a temporary pod with /mnt/nvme mounted to check free space,
  # poll every 60s, bail early once enough space is free, cap at 10 min.
  if [ "$SIZE_GB" -gt 0 ]; then
    local NEED_GB=$(( SIZE_GB + 20 ))
    echo "  Waiting for ${NEED_GB}GB free on NVMe (checking every 60s, max 10 min)..."

    # Create a persistent df-check pod with hostPath access to /mnt/nvme
    kubectl run nvme-df-check --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
      --restart=Never --namespace=kube-system \
      --overrides='{
        "spec":{
          "tolerations":[{"operator":"Exists"}],
          "volumes":[{"name":"nvme","hostPath":{"path":"/mnt/nvme"}}],
          "containers":[{"name":"df","image":"public.ecr.aws/amazonlinux/amazonlinux:2023",
            "command":["sleep","700"],
            "volumeMounts":[{"name":"nvme","mountPath":"/mnt/nvme"}]}]
        }}' 2>/dev/null || true
    kubectl wait --for=condition=Ready pod/nvme-df-check \
      -n kube-system --timeout=60s 2>/dev/null || true

    for i in $(seq 1 10); do
      AVAIL_GB=$(kubectl exec nvme-df-check -n kube-system -- \
        df /mnt/nvme 2>/dev/null \
        | awk 'NR==2{printf "%d", $4/1024/1024}' || echo "?")
      echo "  $(date -u +%H:%M:%S) NVMe free: ${AVAIL_GB}GB (threshold: ${NEED_GB}GB)"
      if [ "$AVAIL_GB" != "?" ] && [ "$AVAIL_GB" -ge "$NEED_GB" ]; then
        echo "  Sufficient space — proceeding"
        break
      fi
      sleep 60
    done

    kubectl delete pod nvme-df-check -n kube-system --ignore-not-found 2>/dev/null || true
  fi
  echo "  Cluster ${NAME} deleted"
}

delete_source_cluster() {
  delete_cluster src-pg "${1:-0}"
}

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

primary_of() {
  kubectl get cluster "$1" -n "$NS" \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null
}

wait_backup() {
  local NAME=$1
  for i in $(seq 1 360); do   # up to 30 min
    local S
    S=$(kubectl get backup "$NAME" -n "$NS" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$S" = "completed" ]; then return 0; fi
    if [ "$S" = "failed" ]; then
      echo "  FAILED: $NAME — $(kubectl get backup "$NAME" -n "$NS" \
        -o jsonpath='{.status.error}' 2>/dev/null)" >&2
      return 1
    fi
    sleep 5
  done
  echo "  TIMEOUT: $NAME" >&2; return 1
}

wait_cluster_ready() {
  # 128GB restore from S3 + WAL replay can take 15-30+ min. Use 3 hours to be safe.
  kubectl wait --for=condition=Ready cluster/"$1" \
    -n "$NS" --timeout=10800s
}

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

# Stats are captured from inside each EKS node via kubectl exec into the
# postgres container (which shares the node's network and disk namespaces).
# Each cluster's primary pod is on a dedicated node with its own NVMe device,
# so per-cluster stats cleanly represent per-node resource usage.
#
# node_of <cluster>  — returns the node name the primary pod is running on
node_of() {
  kubectl get pod "$(primary_of "$1")" -n "$NS" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

# ── Node-level stats collector ────────────────────────────────────────────────
# A single privileged pod with hostPID+hostNetwork reads /proc directly from
# the node, eliminating any dependency on which postgres pod is running.
# All four collectors (vmstat, diskstats, netstat, pidstat) run inside the pod;
# stop_stats deletes the pod and kubectl cp pulls the files to the stats dir.
#
# The collector pod name is written to ${STATS_DIR}/collector.pod so
# stop_stats can find it without extra state.

# ── Node-level stats collector (nicolaka/netshoot) ────────────────────────────
# A privileged pod with hostPID+hostNetwork gives full node visibility.
# vmstat, iostat, pidstat, and sar are all available in netshoot.
# stop_stats kills the background kubectl-exec streams and deletes the pod.

start_stats() {
  local LABEL=$1 JOBS=${2:-1}
  local DIR="${STATS_DIR}/${LABEL}"
  mkdir -p "$DIR"

  local TOP_N=$(( JOBS * 3 ))
  [ "$TOP_N" -lt 6 ] && TOP_N=6

  local POD_NAME="stats-collector"
  kubectl delete pod "$POD_NAME" -n kube-system --ignore-not-found 2>/dev/null || true

  kubectl run "$POD_NAME" \
    --image=nicolaka/netshoot \
    --restart=Never --namespace=kube-system \
    --overrides="{
      \"spec\": {
        \"hostPID\": true,
        \"hostNetwork\": true,
        \"tolerations\": [{\"operator\": \"Exists\"}],
        \"containers\": [{
          \"name\": \"collector\",
          \"image\": \"nicolaka/netshoot\",
          \"command\": [\"sh\", \"-c\", \"apk add --quiet procps sysstat && sleep 10800\"],
          \"securityContext\": {\"privileged\": true}
        }]
      }
    }" 2>/dev/null

  kubectl wait --for=condition=Ready pod/"$POD_NAME" \
    -n kube-system --timeout=120s 2>/dev/null

  echo "$POD_NAME" > "${STATS_DIR}/collector.pod"

  # Wait for apk install to finish before launching collectors
  for i in $(seq 1 30); do
    kubectl exec "$POD_NAME" -n kube-system -- \
      sh -c 'command -v vmstat && command -v pidstat' 2>/dev/null && break
    sleep 2
  done

  # vmstat: aggregate CPU (us/sy/id/wa) and memory, 1-second intervals
  kubectl exec "$POD_NAME" -n kube-system -- vmstat 1 \
    > "$DIR/vmstat.txt" 2>/dev/null &
  echo $! > "${STATS_DIR}/vmstat.bgpid"

  # iostat: disk read/write throughput and %util for all block devices
  kubectl exec "$POD_NAME" -n kube-system -- \
    iostat -xd 1 \
    > "$DIR/iostat.txt" 2>/dev/null &
  echo $! > "${STATS_DIR}/iostat.bgpid"

  # sar: network interface RX/TX KB/s
  kubectl exec "$POD_NAME" -n kube-system -- \
    sar -n DEV 1 \
    > "$DIR/sar-net.txt" 2>/dev/null &
  echo $! > "${STATS_DIR}/sar-net.bgpid"

  # pidstat: per-process CPU%, top N processes (all processes via hostPID)
  kubectl exec "$POD_NAME" -n kube-system -- \
    pidstat -u 1 \
    > "$DIR/pidstat.txt" 2>/dev/null &
  echo $! > "${STATS_DIR}/pidstat.bgpid"
}

stop_stats() {
  local LABEL=$1
  local DIR="${STATS_DIR}/${LABEL}"
  local POD_NAME
  POD_NAME=$(cat "${STATS_DIR}/collector.pod" 2>/dev/null || echo "stats-collector")

  for f in vmstat iostat sar-net pidstat; do
    kill "$(cat "${STATS_DIR}/${f}.bgpid" 2>/dev/null)" 2>/dev/null || true
    rm -f "${STATS_DIR}/${f}.bgpid"
  done
  wait 2>/dev/null || true

  kubectl delete pod "$POD_NAME" -n kube-system --ignore-not-found 2>/dev/null || true
}

# Reset a plugin's stanza state by restarting its primary pod and waiting for
# ContinuousArchiving=True. Required after any S3 wipe because:
# - Dalibo tracks StanzaCreated as an in-memory flag; pod restart clears it so
#   stanza-create runs automatically on the next WAL archive.
# - Opera holds a backup.lock during stanza-create; if archive-push is racing
#   it or a previous stanza-create left a stale lock (exit 40), a pod restart
#   clears the lock directory and lets stanza-create run cleanly via the first
#   backup trigger.
reset_stanza() {
  local CLUSTER=$1 LABEL=$2
  echo "  Restarting ${LABEL} pod to reset stanza state..."
  local POD
  POD=$(primary_of "$CLUSTER")
  kubectl delete pod "$POD" -n "$NS"
  kubectl wait --for=condition=Ready "cluster/${CLUSTER}" \
    -n "$NS" --timeout=300s
  POD=$(primary_of "$CLUSTER")
  kubectl exec "$POD" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "SELECT pg_switch_wal();" 2>/dev/null || true
  echo "  Waiting for ${LABEL} ContinuousArchiving=True (up to 15 min)..."
  for i in $(seq 1 180); do
    local ARCH
    ARCH=$(kubectl get cluster "$CLUSTER" -n "$NS" \
      -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' \
      2>/dev/null || echo "")
    if [ "$ARCH" = "True" ]; then echo "  ${LABEL} archiving healthy"; return 0; fi
    sleep 5
  done
  echo "ERROR: ${LABEL} archiving did not become healthy within 15 minutes" >&2
  echo "  Check plugin logs: kubectl logs \$(kubectl get cluster ${CLUSTER} -n ${NS} -o jsonpath='{.status.currentPrimary}') -c plugin-pgbackrest -n ${NS} --tail=20" >&2
  exit 1
}

# Convenience wrappers.
# Dalibo: full reset — pod restart clears in-memory StanzaCreated flag, then
#         wait for ContinuousArchiving=True (Dalibo auto-creates stanza on WAL).
# Opera:  pod restart only — Opera requires a backup to trigger stanza-create,
#         so ContinuousArchiving will never turn True on an empty bucket. We just
#         clear any stale lock files and let the init backup handle stanza-create.
reset_dalibo_stanza() { reset_stanza src-pg Dalibo; }
reset_opera_stanza() {
  local POD
  echo "  Restarting Opera pod to clear stale locks..."
  POD=$(primary_of src-pg)
  kubectl delete pod "$POD" -n "$NS"
  kubectl wait --for=condition=Ready cluster/src-pg \
    -n "$NS" --timeout=300s
  echo "  Opera pod restarted (stanza-create will run during init backup)"
}

# ── timed backup ──────────────────────────────────────────────────────────────
do_backup() {
  local NAME=$1 CLUSTER=$2 PLUGIN=$3 JOBS=$4 SIZE_GB=$5 LABEL=$6

  echo ""
  echo "  BACKUP ${SIZE_GB}GB ${LABEL} jobs=${JOBS}... $(ts)"

  kubectl delete backup "$NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
  sleep 5

  local STAT_LABEL="backup-${LABEL}-j${JOBS}-${SIZE_GB}gb"
  start_stats "$STAT_LABEL" "$JOBS"
  local T_START
  T_START=$(date +%s)

  case $LABEL in
    barman) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $NAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: $PLUGIN
YAML
      ;;
    opera) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $NAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: $PLUGIN
    parameters:
      type: full
YAML
      ;;
    dalibo) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $NAME
  namespace: ${NS}
spec:
  cluster:
    name: $CLUSTER
  method: plugin
  pluginConfiguration:
    name: $PLUGIN
    parameters:
      backupType: full
YAML
      ;;
  esac

  wait_backup "$NAME"
  local T_END
  T_END=$(date +%s)
  stop_stats "$STAT_LABEL"

  local T=$((T_END - T_START))
  echo "    -> ${T}s $(ts)"
  echo -e "${SIZE_GB}\t${LABEL}\t${JOBS}\tbackup\t${T}" >> "$RESULTS"
}

# ── timed restore ─────────────────────────────────────────────────────────────
do_restore() {
  local DST=$1 LABEL=$2 JOBS=$3 SIZE_GB=$4

  echo ""
  echo "  RESTORE ${SIZE_GB}GB ${LABEL} jobs=${JOBS}... $(ts)"

  # Opera restore jobs config is patched in the benchmark loop before this
  # function is called — not here — to avoid patching while a lock may be held.

  kubectl delete cluster "$DST" -n "$NS" --ignore-not-found 2>/dev/null || true
  sleep 10

  local STAT_LABEL="restore-${LABEL}-j${JOBS}-${SIZE_GB}gb"
  local T_START
  T_START=$(date +%s)

  case $LABEL in
    barman) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $DST
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
        targetImmediate: true
        backupID: ${LAST_BACKUP_NAME}
  externalClusters:
  - name: src
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: barman-store
        serverName: src-pg
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
  name: $DST
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
        targetImmediate: true
        backupID: ${LAST_BACKUP_NAME}
  externalClusters:
  - name: src
    plugin:
      name: pgbackrest.cnpg.opera.com
      parameters:
        pgbackrestObjectName: opera-archive
        stanza: src-pg
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
  name: $DST
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
        targetImmediate: true
        backupID: ${LAST_BACKUP_NAME}
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

  start_stats "$STAT_LABEL" "$JOBS"

  wait_cluster_ready "$DST"
  local T_END
  T_END=$(date +%s)
  stop_stats "$STAT_LABEL"

  local T=$((T_END - T_START))
  echo "    -> ${T}s $(ts)"
  echo -e "${SIZE_GB}\t${LABEL}\t${JOBS}\trestore\t${T}" >> "$RESULTS"
}

# ── init backup: create stanza and seed backup store, wait, then settle ───────
init_backup() {
  local NAME=$1 CLUSTER=$2 LABEL=$3

  kubectl delete backup "$NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
  sleep 3

  case $LABEL in
    barman) kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $NAME
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
  name: $NAME
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
  name: $NAME
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

  wait_backup "$NAME"
  echo "  $NAME: done"
  sleep "$SETTLE"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0: BOOTSTRAP
# ══════════════════════════════════════════════════════════════════════════════

# ── Pre-run cleanup ──────────────────────────────────────────────────────────
# Runs BEFORE bootstrap so clusters are deleted fresh then recreated cleanly.
# Clears all backup objects, clusters, and S3 buckets from any prior run.
echo "Pre-run cleanup..."
echo "  Deleting all clusters and backups..."
kubectl delete backup --all -n "$NS" --ignore-not-found 2>/dev/null || true
kubectl delete cluster --all -n "$NS" --ignore-not-found 2>/dev/null || true
echo "  Waiting for all pods to terminate..."
kubectl wait --for=delete pod -l cnpg.io/podRole -n "$NS" --timeout=120s 2>/dev/null || true
echo "  Waiting for all PVCs to be deleted and disk reclaimed..."
for i in $(seq 1 60); do
  COUNT=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | wc -l || echo 0)
  [ "$COUNT" -eq 0 ] && break || true
  sleep 5
done
# Extra wait for local-path-provisioner to physically remove directories
sleep 30
clear_s3
echo "  Pre-run cleanup done"
echo ""

install_prerequisites


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: BENCHMARK LOOP — one cluster per size, plugins rotate on it
#
# For each size:
#   create cluster → pgbench init (once)
#   for each plugin:
#     attach plugin → stanza reset → init backup → timed backups → timed restores
#     (restore targets deleted after each restore; source cluster stays alive)
#   delete source cluster
# ══════════════════════════════════════════════════════════════════════════════

#SIZES="96 64 32"
SIZES="128"
if [ "$SANITY" = "true" ]; then
  SIZES="1"
fi

# Plugin definitions: label, plugin-name, stanza/object param
# Format: "label:plugin-name:param-key:param-value"
PLUGINS=(
  "barman:barman-cloud.cloudnative-pg.io:barmanObjectName:barman-store"
  "opera:pgbackrest.cnpg.opera.com:pgbackrestObjectName:opera-archive"
  "dalibo:pgbackrest.dalibo.com:stanzaRef:dalibo-stanza"
)

for SIZE_GB in $SIZES; do
  case $SIZE_GB in
    1)   SF=67    ;;
    32)  SF=2200  ;;
    64)  SF=4300  ;;
    96)  SF=6400  ;;
    128) SF=8600  ;;
  esac

  echo ""
  echo "════════════════════════════════════════════"
  echo "SIZE: ${SIZE_GB}GB  (SF=${SF})"
  echo "════════════════════════════════════════════"

  # ── Create source cluster and run pgbench init once per size ───────────────
  create_source_cluster
  SRC_POD=$(primary_of src-pg)

  echo "  pgbench init ${SIZE_GB}GB... $(ts)"
  kubectl exec "$SRC_POD" -n "$NS" -c postgres -- \
    psql -U postgres -tAc \
      "DROP TABLE IF EXISTS pgbench_accounts,pgbench_branches,pgbench_history,pgbench_tellers CASCADE;" \
    2>/dev/null || true
  kubectl exec "$SRC_POD" -n "$NS" -c postgres -- \
    pgbench -U postgres -i -s "$SF" postgres \
    > "/tmp/pgbench-init-${SIZE_GB}.log" 2>&1
  SZ=$(kubectl exec "$SRC_POD" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "SELECT pg_size_pretty(pg_database_size('postgres'));" \
    2>/dev/null | tr -d '[:space:]')
  echo "  pgbench init done: $SZ $(ts)"

  # WAL switch to flush pgbench WAL before any plugin starts archiving
  kubectl exec "$SRC_POD" -n "$NS" -c postgres -- \
    psql -U postgres -tAc "SELECT pg_switch_wal();" 2>/dev/null || true

  for PLUGIN_DEF in "${PLUGINS[@]}"; do
    LABEL="${PLUGIN_DEF%%:*}"
    REST="${PLUGIN_DEF#*:}"
    PLUGIN_NAME="${REST%%:*}"
    REST="${REST#*:}"
    PARAM_KEY="${REST%%:*}"
    PARAM_VAL="${REST#*:}"

    # Skip plugins not selected by --sanity <plugin>
    if [ -n "$SANITY_PLUGIN" ] && [ "$LABEL" != "$SANITY_PLUGIN" ]; then
      continue
    fi

    echo ""
    echo "  ── ${LABEL} ────────────────────────────────── $(ts)"

    # Clear S3 before each plugin so stanzas start fresh
    clear_s3

    # ── Attach plugin (replaces any previously attached plugin) ────────────
    attach_plugin "$LABEL"
    SRC_POD=$(primary_of src-pg)

    # ── Stanza reset (Opera/Dalibo need pod state cleared after S3 wipe) ───
    case $LABEL in
      opera)  reset_opera_stanza  ;;
      dalibo) reset_dalibo_stanza ;;
    esac
    # Re-get pod name after potential restart
    SRC_POD=$(primary_of src-pg)

    sleep 10

    # ── Init backup (creates stanza, seeds backup store) ────────────────────
    init_backup "init-${LABEL}-${SIZE_GB}" src-pg "$LABEL"

    # ── Timed backups ────────────────────────────────────────────────────────
    for JOBS in 1 8 32 64 128; do
      # Dalibo has no jobs parameter — only run j1
      [ "$LABEL" = "dalibo" ] && [ "$JOBS" -gt 1 ] && continue

      echo ""
      echo "    Patching jobs=${JOBS}..."
      case $LABEL in
        barman) kubectl patch objectstore barman-store -n "$NS" --type=merge \
                  -p "{\"spec\":{\"configuration\":{\"data\":{\"jobs\":${JOBS}}}}}" \
                  2>/dev/null || true ;;
        opera)  kubectl patch archive opera-archive -n "$NS" --type=merge \
                  -p "{\"spec\":{\"configuration\":{\"data\":{\"jobs\":${JOBS}}}}}" \
                  2>/dev/null || true ;;
      esac
      sleep 15

      do_backup "${LABEL}-j${JOBS}-${SIZE_GB}" src-pg "$PLUGIN_NAME" \
        "$JOBS" "$SIZE_GB" "$LABEL"
      sleep "$SETTLE"
    done

    # ── Capture backup name for targetImmediate restore ─────────────────────
    # Get the backupId from the last timed backup. Using targetImmediate with
    # a specific backupID tells CNPG to restore that exact backup and stop at
    # the first consistent state — no additional WAL segments needed beyond what
    # pgBackRest/barman already archived during the backup itself.
    LAST_BACKUP_NAME=""
    for JOBS in 128 64 32 8 1; do
      [ "$LABEL" = "dalibo" ] && [ "$JOBS" -gt 1 ] && continue
      # Dalibo populates .status.backupName; barman and opera use .status.backupId
      if [ "$LABEL" = "dalibo" ]; then
        BN=$(kubectl get backup "${LABEL}-j${JOBS}-${SIZE_GB}" -n "$NS" \
          -o jsonpath='{.status.backupName}' 2>/dev/null || echo "")
      else
        BN=$(kubectl get backup "${LABEL}-j${JOBS}-${SIZE_GB}" -n "$NS" \
          -o jsonpath='{.status.backupId}' 2>/dev/null || echo "")
      fi
      if [ -n "$BN" ]; then
        LAST_BACKUP_NAME="$BN"
        echo "  Using backupID: $LAST_BACKUP_NAME (from ${LABEL}-j${JOBS}-${SIZE_GB})"
        break
      fi
    done
    if [ -z "$LAST_BACKUP_NAME" ]; then
      echo "ERROR: could not find backupId for ${LABEL} — cannot proceed with restore" >&2
      exit 1
    fi

    # ── Timed restores (source cluster stays alive) ──────────────────────────
    for JOBS in 1 8 32 64 128; do
      # Barman has no parallel restore; Dalibo has none either
      [ "$LABEL" = "barman" ] && [ "$JOBS" -gt 1 ] && continue
      [ "$LABEL" = "dalibo" ] && [ "$JOBS" -gt 1 ] && continue

      if [ "$LABEL" = "opera" ] && [ "$JOBS" -gt 1 ]; then
        kubectl patch archive opera-archive -n "$NS" --type=merge \
          -p "{\"spec\":{\"configuration\":{\"restore\":{\"jobs\":${JOBS}}}}}" \
          2>/dev/null || true
        sleep 15
      fi

      do_restore "rst-${LABEL}-j${JOBS}-${SIZE_GB}" "$LABEL" "$JOBS" "$SIZE_GB"
      sleep "$SETTLE"

      # Delete restore cluster (no disk-reclaim wait needed — source stays alive
      # and restore targets are much smaller than the NVMe free space)
      delete_cluster "rst-${LABEL}-j${JOBS}-${SIZE_GB}"
    done

    # Reset jobs config to 1 for next plugin
    kubectl patch objectstore barman-store -n "$NS" --type=merge \
      -p '{"spec":{"configuration":{"data":{"jobs":1}}}}' 2>/dev/null || true
    kubectl patch archive opera-archive -n "$NS" --type=merge \
      -p '{"spec":{"configuration":{"data":{"jobs":1},"restore":{"jobs":1}}}}' \
      2>/dev/null || true

  done  # end plugin loop

  # ── Delete source cluster after all plugins are done for this size ─────────
  delete_source_cluster

done    # end size loop

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "T9 COMPLETE — $(ts)"
echo "════════════════════════════════════════════"
echo ""
echo "Results:"
column -t -s $'\t' "$RESULTS"
echo ""
echo "Per-run iostat/vmstat: $STATS_DIR"
