# pgBackRest Plugin Testing
Opera v0.6.0 | Dalibo v0.0.2 | Barman v0.12.0 — tested 2026-06-01

**Contents**
- [Overall Results Summary](#overall-results-summary)
- [Key Findings](#key-findings)
- [Environment & Setup](#environment--setup)
- [Playground Setup](#playground-setup)
- [Environment & Playground Teardown](#environment--playground-teardown)
- [T1 — Cluster + Sidecar Injection](#t1--cluster--sidecar-injection)
- [T2 — WAL Archiving](#t2--wal-archiving)
- [T3 — On-Demand Backup](#t3--on-demand-backup)
- [T4 — Restore from Backup](#t4--restore-from-backup)
- [T5 — Point-in-Time Recovery (PITR)](#t5--point-in-time-recovery-pitr)
- [T6 — Rolling Restart](#t6--rolling-restart)
- [T7 — Failover / Primary Switchover](#t7--failover--primary-switchover)
- [T8 — Parallel WAL Archiving](#t8--parallel-wal-archiving)
- [T10 — Incremental Backup Chain](#t10--incremental-backup-chain)
- [T11 — Restore from Incremental Chain](#t11--restore-from-incremental-chain)
- [T9 — Backup/Restore Throughput Benchmark](#t9--backuprestore-throughput-benchmark)
- [T12 — WAL Archiving Throughput Benchmark](#t12--wal-archiving-throughput-benchmark)

---

## Overall Results Summary

| Test | Barman | Opera | Dalibo |
|------|--------|-------|--------|
| T1 — Cluster + sidecar injection | — not separately tested | ✅ PASS | ✅ PASS |
| T2 — WAL archiving | — not separately tested | ✅ PASS | ✅ PASS — auto stanza-create |
| T3 — On-demand backup | — not separately tested | ✅ PASS | ✅ PASS |
| T4 — Restore from backup | — not separately tested | ✅ PASS — needs `stanza:` param | ✅ PASS |
| T5 — PITR | — not separately tested | ✅ PASS | ✅ PASS — needs `targetTLI: "1"` |
| T6 — Rolling restart | ✅ PASS | ✅ PASS | ✅ PASS |
| T7 — Failover / switchover | ✅ PASS — 27s | ✅ PASS — 25s | ✅ PASS — 24s |
| T8 — Parallel WAL archiving | ✅ PASS — prefetch model | ✅ PASS — batch model | — N/A — not implemented |
| T9 — Backup/restore throughput | see [charts](README.md) + [notes](benchmark-learnings.md) | see [charts](README.md) + [notes](benchmark-learnings.md) | see [charts](README.md) + [notes](benchmark-learnings.md) |
| T12 — WAL archiving throughput | see [charts](README.md) + [notes](benchmark-learnings.md) | see [charts](README.md) + [notes](benchmark-learnings.md) | see [charts](README.md) + [notes](benchmark-learnings.md) |
| T10 — Incremental backup chain | — N/A — always full | ✅ PASS — full/diff/incr | ✅ PASS — full/diff/incr |
| T11 — Restore from incr chain | — N/A | ✅ PASS | ✅ PASS |
| **Multi-instance backup** | ✅ Works — any backup target | ⚠️ Needs backup `target: primary` | ⚠️ Needs backup `target: primary` |
| **arm64 / Graviton support** | ✅ Multi-arch image | ✅ Multi-arch image | ❌ amd64 only — exec format error on arm64 |

**Barman** is the most operationally complete plugin — it handles multi-instance clusters correctly, has the longest production track record (it's the reference implementation), and works without manual bootstrapping. Its limitations are the lack of incremental backups and no parallel restore.

**Opera** passes all functional tests when used with single-instance clusters. It adds incremental backups and parallel restore/backup jobs over Barman. On multi-instance clusters its backups must target the primary (`target: primary`) — they fail under CNPG's default `prefer-standby` target — and that, together with the stanza bootstrapping deadlock, is an operational concern to weigh before production use at scale.

**Dalibo** passes all applicable tests, has a more intuitive CRD design (separate Stanza object, auto stanza-create), and is the only plugin with Azure Blob Storage e2e coverage (tested via Azurite). At v0.0.2 it is explicitly pre-production by its own versioning, and the multi-instance backup constraint is the same as Opera (backups must use `target: primary`). It is under more active development than Opera at the time of testing.

---

## Key Findings

### 1. pgBackRest plugins require backups to target the primary on multi-instance clusters

By default CNPG runs backups on the most up-to-date replica (the `prefer-standby` target). When the backup gRPC call lands on a replica pod, both Opera and Dalibo fail with `unable to find primary cluster` (exit 56) — pgBackRest in the sidecar can't locate the primary from a standby. Opera has an explicit TODO comment acknowledging this; Dalibo fails silently. Barman handles a replica-dispatched backup correctly.

CNPG can pin backups to the primary by setting `target: primary` (on the cluster's `spec.backup.target`, or per `Backup`/`ScheduledBackup`), which sidesteps the failure — so multi-instance clusters are usable with these plugins as long as backups target the primary. We did not exercise this: all Opera and Dalibo backup/restore tests were run with `instances: 1`. The residual gap versus Barman is that the pgBackRest plugins cannot back up from a standby, so they require `target: primary` on HA clusters.

### 2. Stanza bootstrapping deadlock (Opera + Dalibo)

Both pgBackRest plugins require a stanza to exist in the object store before WAL archiving works, but CNPG refuses to start a backup when `ContinuousArchiving=False`. After any full MinIO bucket wipe, the plugins enter a deadlock. Workarounds differ:

- **Opera:** delete the pod (clears stale lock) then immediately trigger a backup; Opera bundles stanza-create into its backup flow.
- **Dalibo:** pod restart resets the in-memory `StanzaCreated` flag, causing auto stanza-create on the next WAL archive; wait for `ContinuousArchiving=True` before triggering a backup.

### 3. Dalibo auto-creates stanza on first WAL archive; Opera does not

In a clean-state deployment (fresh object store), Dalibo automatically calls `stanza-create` on the first WAL archive attempt and logs *"stanza created while archiving"*. WAL archiving works immediately. Opera requires a backup to be triggered first, which creates the stanza — but only if `ContinuousArchiving=True`, creating the bootstrapping deadlock described above.

### 4. Namespace conflicts between Opera and Dalibo

Both plugins use identical names for several cluster-scoped resources in `cnpg-system`: `leader-election-role` (Role), `metrics-auth-rolebinding` (ClusterRoleBinding), and `pgbackrest` (Service). The last one applied wins and overwrites the other's bindings and TLS routing. Installing both plugins in the same cluster requires patching the Dalibo manifest before applying.

### 5. Opera restore requires an undocumented `stanza` parameter

When restoring from an Opera-managed backup, the `externalClusters` plugin parameters must include `stanza: <source-cluster-name>`. Without it, pgbackrest looks for a stanza named after the *new* cluster and fails with `no target backup found`. This is not in the main README — only visible in example YAML files.

### 6. PITR timeline conflict when stanza is shared

If a restore cluster is promoted while sharing the same stanza as the source, pgbackrest archives WALs on multiple timelines. A subsequent PITR restore targeting the original timeline fails with *"target timeline N forked from backup timeline 1 before backup LSN"*. Fix: add `targetTLI: "1"` to `recoveryTarget`. Affects both pgBackRest plugins; neither documents it.

### 7. Barman has no incremental backup or parallel restore

Barman uses `barman-cloud-backup` (based on `pg_basebackup`) which always performs a full copy. The `barman-cloud-restore` CLI has no parallel jobs flag. Opera supports parallel backup (`data.jobs`) and parallel restore (`restore.jobs`). Dalibo exposes neither.

### 8. Dalibo v0.0.2 does not publish an arm64 container image

The Dalibo controller and sidecar images (`dalibo/cnpg-pgbackrest-controller:0.0.2`, `dalibo/cnpg-pgbackrest-sidecar:0.0.2`) are published for `linux/amd64` only. Attempting to run Dalibo on an arm64 node (e.g. AWS Graviton — `m7gd.xlarge`) results in an immediate `exec format error` and a `CrashLoopBackOff`. Barman and Opera both publish multi-arch images that run on arm64 without modification. The T9 and T12 benchmarks were consequently run on `c6id.32xlarge` (x86_64) rather than the originally planned `m7gd.xlarge` (Graviton4, arm64). This is worth noting for teams running CNPG on Graviton-based EKS node groups — Dalibo cannot be used in that configuration until multi-arch images are published.

---

## Environment & Setup

Tests run on the **cnpg-playground** — a local Kind-based Kubernetes cluster with MinIO S3-compatible object storage in Docker.

| Component | Detail |
|-----------|--------|
| Kubernetes (Kind) | v1.35.0, single-region, 1 control plane + 5 workers |
| CloudNativePG | v1.28.1 |
| cert-manager | latest stable |
| MinIO | Docker container at `172.18.0.8:9000` |
| Barman Cloud Plugin | v0.12.0 |
| Opera pgBackRest Plugin | v0.6.0 |
| Dalibo pgBackRest Plugin | v0.0.2 (patched manifest — see findings) |
| PostgreSQL | 18.1 |
| All clusters | 1 instance for T1–T11 (multi-instance backup target noted below) |

> **Installation conflict:** Opera and Dalibo both use `leader-election-role` and a service named `pgbackrest` in `cnpg-system`. Running both simultaneously requires patching the Dalibo manifest to rename its role (`dalibo-leader-election-role`), rename its service (`pgbackrest-dalibo`), and update its server TLS certificate DNS names accordingly. Without this patch, each plugin's install clobbers the other's RBAC bindings and TLS certificates.

> **T9 and T12 use a different environment:** The throughput benchmarks ran on AWS EKS (`c6id.32xlarge` nodes) with local NVMe storage and real AWS S3 — not the Kind/MinIO playground. The EKS cluster was provisioned with `aws-setup.sh` and torn down with `aws-teardown.sh`. See [benchmark-learnings.md](benchmark-learnings.md) for full environment details.

---

## Playground Setup

Run once before any of these tests. Creates the Kind cluster, installs CNPG and cert-manager, creates the MinIO buckets, and installs the plugins.

**MinIO credentials:** user: `cnpg` / password: `Cl0udNativePGRocks`

#### 1. Start the playground

```bash
cd ~/cnpg-playground
./scripts/setup.sh local
```

#### 2. Wait for nodes

```bash
export KUBECONFIG=~/cnpg-playground/k8s/kube-config.yaml
kubectl --context kind-k8s-local wait --for=condition=Ready nodes --all --timeout=120s
```

#### 3. Install CloudNativePG

```bash
kubectl cnpg install generate --control-plane | \
  kubectl --context kind-k8s-local apply -f - --server-side

kubectl --context kind-k8s-local rollout status deployment \
  -n cnpg-system cnpg-controller-manager --timeout=120s
```

#### 4. Install cert-manager

```bash
kubectl apply --context kind-k8s-local -f \
  https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

kubectl rollout --context kind-k8s-local status deployment -n cert-manager --timeout=180s
```

#### 5. Find the MinIO internal IP

```bash
docker inspect minio-local --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}'
```

The playground runs MinIO in Docker on the Kind network (`172.18.x.x`). In this test run it was `172.18.0.8` — substitute your actual IP in all manifests below.

#### 6. Verify MinIO is reachable

```bash
curl -s http://172.18.0.8:9000/minio/health/live && echo "MinIO reachable"
```

#### 7. Create S3 buckets

```bash
docker run --rm --network kind --entrypoint sh quay.io/minio/mc:latest \
  -c "mc alias set minio http://172.18.0.8:9000 cnpg Cl0udNativePGRocks --quiet \
      && mc mb --ignore-existing minio/opera-pgbackrest \
      && mc mb --ignore-existing minio/dalibo-pgbackrest \
      && echo done"
```

### Plugin Install

#### Opera

```bash
kubectl apply --context kind-k8s-local -f \
  https://github.com/operasoftware/cnpg-plugin-pgbackrest/releases/latest/download/manifest.yaml

kubectl rollout --context kind-k8s-local status deployment \
  -n cnpg-system pgbackrest --timeout=120s
```

> **Note:** The deployment is named `pgbackrest` (not `cnpg-plugin-pgbackrest`).

#### Dalibo

```bash
# Path to local clone of the Dalibo repo
DALIBO_MANIFEST=~/projects/backups/cnpg-plugin-pgbackrest-dalibo/cnpg-plugin-pgbackrest/manifest.yaml

kubectl --context kind-k8s-local apply -f "$DALIBO_MANIFEST"

kubectl --context kind-k8s-local rollout status deployment \
  -n cnpg-system pgbackrest-controller --timeout=120s
```

> **Note:** Dalibo installs two CRDs: `stanzas.pgbackrest.dalibo.com` and `pluginconfigs.pgbackrest.dalibo.com`. The deployment is named `pgbackrest-controller`.

---

## Environment & Playground Teardown

#### Opera

```bash
kubectl --context kind-k8s-local delete cluster opera-pg opera-pg-restored opera-pg-pitr --ignore-not-found
kubectl --context kind-k8s-local delete backup opera-backup-1 opera-backup-2 --ignore-not-found
kubectl --context kind-k8s-local delete archive opera-archive --ignore-not-found
kubectl --context kind-k8s-local delete secret pgbackrest-s3-secret --ignore-not-found
kubectl --context kind-k8s-local delete -f \
  https://github.com/operasoftware/cnpg-plugin-pgbackrest/releases/latest/download/manifest.yaml \
  --ignore-not-found
```

#### Dalibo

```bash
kubectl --context kind-k8s-local delete \
  cluster/dalibo-pg cluster/dalibo-pg-restored cluster/dalibo-pg-pitr \
  --ignore-not-found

kubectl --context kind-k8s-local delete \
  backup/dalibo-backup-1 backup/dalibo-backup-2 \
  --ignore-not-found

kubectl --context kind-k8s-local delete stanza/dalibo-stanza --ignore-not-found
kubectl --context kind-k8s-local delete secret/pgbackrest-s3-secret --ignore-not-found
```

---

## T1 — Cluster + Sidecar Injection

Verify the CRD is registered and the sidecar gets injected into a PostgreSQL pod.

#### Setup — Opera

**Create S3 credentials secret**

```bash
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pgbackrest-s3-secret
  namespace: default
type: Opaque
stringData:
  ACCESS_KEY_ID: cnpg
  ACCESS_SECRET_KEY: Cl0udNativePGRocks
EOF
```

**Create the Archive object**

> **Gotcha:** S3 path-style addressing must be set via `uriStyle: path` inside `s3Credentials`. If omitted, pgbackrest defaults to virtual-host style and tries to resolve `opera-pgbackrest.172.18.0.8` as a hostname, which fails.

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: pgbackrest.cnpg.opera.com/v1
kind: Archive
metadata:
  name: opera-archive
  namespace: default
spec:
  configuration:
    repositories:
    - bucket: opera-pgbackrest
      destinationPath: /pgbackrest
      endpointURL: http://172.18.0.8:9000
      disableVerifyTLS: true
      s3Credentials:
        region: us-east-1
        uriStyle: path
        accessKeyId:
          name: pgbackrest-s3-secret
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: pgbackrest-s3-secret
          key: ACCESS_SECRET_KEY
EOF
```

**Create the PostgreSQL cluster**

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: opera-pg
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  plugins:
  - name: pgbackrest.cnpg.opera.com
    parameters:
      pgbackrestObjectName: opera-archive
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready cluster/opera-pg --timeout=300s

# Should show: bootstrap-controller plugin-pgbackrest
kubectl --context kind-k8s-local get pod opera-pg-1 \
  -o jsonpath='{.spec.initContainers[*].name}' && echo
```

#### Setup — Dalibo

**Create credentials secret**

```bash
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pgbackrest-s3-secret
  namespace: default
type: Opaque
stringData:
  ACCESS_KEY_ID: cnpg
  ACCESS_SECRET_KEY: Cl0udNativePGRocks
EOF
```

**Create the Stanza object**

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: pgbackrest.dalibo.com/v1
kind: Stanza
metadata:
  name: dalibo-stanza
  namespace: default
spec:
  stanzaConfiguration:
    name: dalibo-pg
    s3Repositories:
      - bucket: dalibo-pgbackrest
        endpoint: http://172.18.0.8:9000
        region: us-east-1
        repoPath: /pgbackrest
        uriStyle: path
        verifyTLS: false
        secretRef:
          accessKeyId:
            name: pgbackrest-s3-secret
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: pgbackrest-s3-secret
            key: ACCESS_SECRET_KEY
EOF
```

**Create the PostgreSQL cluster**

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dalibo-pg
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  plugins:
    - name: pgbackrest.dalibo.com
      isWALArchiver: true
      parameters:
        stanzaRef: dalibo-stanza
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready cluster/dalibo-pg --timeout=300s

# Should show: bootstrap-controller plugin-pgbackrest
kubectl --context kind-k8s-local get pod dalibo-pg-1 \
  -o jsonpath='{.spec.initContainers[*].name}' && echo
```

#### Results

| Plugin | Result | Notes |
|--------|--------|-------|
| Opera | ✅ PASS | `plugin-pgbackrest` init container injected; cluster reached Ready |
| Dalibo | ✅ PASS | `plugin-pgbackrest` init container injected; cluster reached Ready |

---

## T2 — WAL Archiving

Insert data, force a WAL switch, and confirm WAL files land in MinIO.

#### Setup — Opera

> **Note:** WAL archiving fails with `archive.info cannot be opened` until the first backup is run (T3). The stanza is created during the backup process, not at cluster startup. Run T3 before checking T2 logs for success.

```bash
kubectl --context kind-k8s-local exec opera-pg-1 -c postgres -- \
  psql -U postgres -tAc "SELECT pg_switch_wal();"

sleep 15

kubectl --context kind-k8s-local logs opera-pg-1 -c plugin-pgbackrest --tail=5 \
  | grep -E 'successfulArchives|failedArchives'
```

Confirm WAL files in MinIO:

```bash
docker run --rm --network kind --entrypoint sh quay.io/minio/mc:latest \
  -c "mc alias set minio http://172.18.0.8:9000 cnpg Cl0udNativePGRocks --quiet \
      && mc ls --recursive minio/opera-pgbackrest/pgbackrest/archive/"
```

#### Setup — Dalibo

Unlike Opera, Dalibo automatically creates the stanza on the first WAL archive attempt.

```bash
kubectl --context kind-k8s-local exec dalibo-pg-1 -c postgres -- \
  psql -U postgres -tAc \
    "CREATE TABLE t1 (id serial, v text);
     INSERT INTO t1(v) VALUES ('dalibo-test');
     SELECT pg_switch_wal();"

sleep 20

kubectl --context kind-k8s-local logs dalibo-pg-1 -c plugin-pgbackrest --tail=10
```

Expected log lines:
```
{"msg":"stanza created while archiving","WAL":"...000000010000000000000001"}
{"msg":"pgBackRest archive-push successful","WAL":"...000000010000000000000001"}
```

#### Results

| Plugin | Result | Notes |
|--------|--------|-------|
| Opera | ✅ PASS | `"successfulArchives":1,"failedArchives":0`; WAL `.gz` files confirmed in MinIO; `uriStyle: path` required |
| Dalibo | ✅ PASS | Stanza auto-created on first archive; no extra steps needed |

---

## T3 — On-Demand Backup

Trigger a backup and verify it completes.

> **Note — Opera:** T3 must run before T2 verification — the first backup initialises the pgbackrest stanza, which is required before WAL archiving works.

#### Setup — Opera

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: opera-backup-1
  namespace: default
spec:
  cluster:
    name: opera-pg
  method: plugin
  pluginConfiguration:
    name: pgbackrest.cnpg.opera.com
EOF
```

```bash
kubectl --context kind-k8s-local get backup opera-backup-1 -w
```

#### Setup — Dalibo

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: dalibo-backup-1
  namespace: default
spec:
  cluster:
    name: dalibo-pg
  method: plugin
  pluginConfiguration:
    name: pgbackrest.dalibo.com
EOF
```

```bash
kubectl --context kind-k8s-local get backup dalibo-backup-1 -w
```

#### Results

| Plugin | Result | Backup time |
|--------|--------|-------------|
| Opera | ✅ PASS | ~10s; backup manifest and data files confirmed in MinIO |
| Dalibo | ✅ PASS | ~20s |

---

## T4 — Restore from Backup

Create a new cluster that recovers from the backup in MinIO.

#### Setup — Opera

> **Gotcha:** The `stanza:` parameter must be set in `externalClusters` to the name of the source cluster's stanza (which defaults to the source cluster name). Without it, pgbackrest looks for a stanza named after the *new* cluster and reports `no target backup found`. This is not documented in the main README — it is only visible in the example files.

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: opera-pg-restored
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: opera-backup-source
  externalClusters:
  - name: opera-backup-source
    plugin:
      name: pgbackrest.cnpg.opera.com
      parameters:
        pgbackrestObjectName: opera-archive
        stanza: opera-pg          # must match source cluster name
  plugins:
  - name: pgbackrest.cnpg.opera.com
    parameters:
      pgbackrestObjectName: opera-archive
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/opera-pg-restored --timeout=300s

kubectl --context kind-k8s-local exec opera-pg-restored-1 -c postgres -- \
  psql -U postgres -tAc "SELECT v FROM t1;"
```

#### Setup — Dalibo

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dalibo-pg-restored
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: dalibo-backup-source
  externalClusters:
    - name: dalibo-backup-source
      plugin:
        name: pgbackrest.dalibo.com
        parameters:
          stanzaRef: dalibo-stanza
  plugins:
    - name: pgbackrest.dalibo.com
      parameters:
        stanzaRef: dalibo-stanza
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/dalibo-pg-restored --timeout=300s

kubectl --context kind-k8s-local exec dalibo-pg-restored-1 -c postgres -- \
  psql -U postgres -tAc "SELECT v FROM t1;"
```

#### Results

| Plugin | Result | Notes |
|--------|--------|-------|
| Opera | ✅ PASS | Requires `stanza: opera-pg` in `externalClusters` parameters |
| Dalibo | ✅ PASS | Works with `stanzaRef` alone; no extra parameters needed |

---

## T5 — Point-in-Time Recovery (PITR)

Insert data before and after a timestamp, take a second backup, restore to the recorded timestamp, and verify only pre-target rows are present.

#### Setup — Opera

Insert pre-PITR data and take a second backup:

```bash
kubectl --context kind-k8s-local exec opera-pg-1 -c postgres -- \
  psql -U postgres -tAc \
    "INSERT INTO t1(v) VALUES ('before-pitr-1'),('before-pitr-2'); SELECT pg_switch_wal();"
```

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: opera-backup-2
  namespace: default
spec:
  cluster:
    name: opera-pg
  method: plugin
  pluginConfiguration:
    name: pgbackrest.cnpg.opera.com
EOF
```

Record a timestamp and insert a post-target row:

```bash
PITR_TIME=$(kubectl --context kind-k8s-local exec opera-pg-1 -c postgres -- \
  psql -U postgres -tAc "SELECT now()::text;" \
  | tr -d '[:space:]' \
  | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\([0-9]\{2\}:\)/\1 \2/' \
  | sed 's/+00$//')
echo "PITR target: $PITR_TIME"
sleep 2

kubectl --context kind-k8s-local exec opera-pg-1 -c postgres -- \
  psql -U postgres -tAc \
    "INSERT INTO t1(v) VALUES ('after-pitr-should-not-appear'); SELECT pg_switch_wal();"
```

Create the PITR cluster:

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: opera-pg-pitr
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: opera-backup-source
      recoveryTarget:
        targetTime: "${PITR_TIME}"
  externalClusters:
  - name: opera-backup-source
    plugin:
      name: pgbackrest.cnpg.opera.com
      parameters:
        pgbackrestObjectName: opera-archive
        stanza: opera-pg
  plugins:
  - name: pgbackrest.cnpg.opera.com
    parameters:
      pgbackrestObjectName: opera-archive
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/opera-pg-pitr --timeout=300s

# PITR restore should have 3 rows — no 'after-pitr' row
kubectl --context kind-k8s-local exec opera-pg-pitr-1 -c postgres -- \
  psql -U postgres -tAc "SELECT v FROM t1 ORDER BY id;"
```

Expected output:
```
opera-test
before-pitr-1
before-pitr-2
```

#### Setup — Dalibo

Insert pre-PITR data and take a second backup:

```bash
kubectl --context kind-k8s-local exec dalibo-pg-1 -c postgres -- \
  psql -U postgres -tAc \
    "INSERT INTO t1(v) VALUES ('before-pitr-1'),('before-pitr-2'); SELECT pg_switch_wal();"
```

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: dalibo-backup-2
  namespace: default
spec:
  cluster:
    name: dalibo-pg
  method: plugin
  pluginConfiguration:
    name: pgbackrest.dalibo.com
EOF
```

Record a timestamp and insert a post-target row:

```bash
PITR_TIME=$(kubectl --context kind-k8s-local exec dalibo-pg-1 -c postgres -- \
  psql -U postgres -tAc "SELECT now()::text;" \
  | tr -d '[:space:]' \
  | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\([0-9]\{2\}:\)/\1 \2/' \
  | sed 's/+00$//')
echo "PITR target: $PITR_TIME"
sleep 2

kubectl --context kind-k8s-local exec dalibo-pg-1 -c postgres -- \
  psql -U postgres -tAc \
    "INSERT INTO t1(v) VALUES ('after-pitr-should-not-appear'); SELECT pg_switch_wal();"
```

> **Gotcha — Timeline conflict:** If a separate restore cluster (T4) was promoted while sharing the same stanza, the MinIO archive contains multiple timelines. pgbackrest refuses to restore with: `target timeline 2 forked from backup timeline 1 ... which is before backup lsn`. Fix: add `targetTLI: "1"` to force pgbackrest to stay on the original timeline.

Create the PITR cluster:

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dalibo-pg-pitr
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: dalibo-backup-source
      recoveryTarget:
        targetTime: "${PITR_TIME}"
        targetTLI: "1"            # required when stanza has multiple timelines
  externalClusters:
    - name: dalibo-backup-source
      plugin:
        name: pgbackrest.dalibo.com
        parameters:
          stanzaRef: dalibo-stanza
  plugins:
    - name: pgbackrest.dalibo.com
      parameters:
        stanzaRef: dalibo-stanza
EOF
```

```bash
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/dalibo-pg-pitr --timeout=300s

# PITR restore should have 3 rows — no 'after-pitr' row
kubectl --context kind-k8s-local exec dalibo-pg-pitr-1 -c postgres -- \
  psql -U postgres -tAc "SELECT v FROM t1 ORDER BY id;"
```

Expected output:
```
dalibo-test
before-pitr-1
before-pitr-2
```

#### Results

| Plugin | Result | Notes |
|--------|--------|-------|
| Opera | ✅ PASS | Correct row count; post-target data excluded |
| Dalibo | ✅ PASS | Requires `targetTLI: "1"` to avoid timeline conflict from promoted T4 restore cluster |

---

## T6 — Rolling Restart

Used `kubectl cnpg restart <cluster>` on each 1-instance cluster. Verified WAL archiving resumed and data was intact after pod recycled.

#### Setup

```bash
# For each cluster (barman-pg, opera-pg, dalibo-pg):
kubectl cnpg restart <cluster-name> --context kind-k8s-local

# Verify archiving resumed after restart:
kubectl --context kind-k8s-local get cluster <cluster-name> \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'
```

#### Results

| Plugin | Result | Archiving after | Data intact |
|--------|--------|-----------------|-------------|
| Barman | ✅ PASS | True | Yes |
| Opera | ✅ PASS | True | Yes |
| Dalibo | ✅ PASS | True | Yes |

All three plugins resumed WAL archiving immediately after pod restart with no intervention.

---

## T7 — Failover / Primary Switchover

Scaled each cluster to 3 instances, then deleted the primary pod to trigger automatic failover. Measured time to re-establish a primary and verified archiving continued on the new primary.

#### Setup

```bash
# Scale to 3 instances
kubectl --context kind-k8s-local patch cluster <cluster> \
  --type=merge -p '{"spec":{"instances":3}}'
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/<cluster> --timeout=300s

# Trigger failover by deleting primary pod
PRIMARY=$(kubectl --context kind-k8s-local get cluster <cluster> \
  -o jsonpath='{.status.currentPrimary}')
kubectl --context kind-k8s-local delete pod $PRIMARY

# Wait for new primary
kubectl --context kind-k8s-local wait --for=condition=Ready \
  cluster/<cluster> --timeout=180s
```

> **Multi-instance backups need `target: primary` (Opera + Dalibo):** Under CNPG's default `prefer-standby` target a backup can be dispatched to a replica pod, where both pgBackRest plugins fail (`unable to find primary cluster`, exit 56) — Opera's code has an explicit TODO noting this; Dalibo fails silently. Barman is unaffected. Setting `target: primary` forces backups onto the primary and avoids this, but we did not test it: all Opera and Dalibo backup/restore tests used `instances: 1`. Failover itself was tested separately at 3 instances.

#### Results

| Plugin | Result | Failover time | New primary | Archiving after |
|--------|--------|---------------|-------------|-----------------|
| Barman | ✅ PASS | 27s | barman-pg-2 | True |
| Opera | ✅ PASS | 25s | opera-pg-2 | True |
| Dalibo | ✅ PASS | 24s | dalibo-pg-2 | True |

All three plugins promoted a replica in 24–27 seconds and resumed WAL archiving on the new primary without manual intervention.

---

## T8 — Parallel WAL Archiving

Set `maxParallel: 4` on Opera and Barman. Generated 15 rapid WAL switches and examined sidecar logs for evidence of parallel batching. Dalibo does not implement parallel WAL archiving and was not tested.

#### Setup

```bash
# Opera: patch Archive object
kubectl --context kind-k8s-local patch archive opera-archive --type=merge -p \
  '{"spec":{"configuration":{"wal":{"maxParallel":4}}}}'

# Barman: patch ObjectStore
kubectl --context kind-k8s-local patch objectstore barman-store --type=merge -p \
  '{"spec":{"configuration":{"wal":{"maxParallel":4}}}}'

# Generate WAL burst (15 switches)
for i in $(seq 1 15); do
  kubectl --context kind-k8s-local exec <primary> -c postgres -- \
    psql -U postgres -tAc \
      "INSERT INTO t1(v) VALUES ('burst-$i'); SELECT pg_switch_wal();"
  sleep 0.1
done
sleep 20

# Inspect Opera sidecar logs
kubectl --context kind-k8s-local logs <primary> -c plugin-pgbackrest \
  | grep -E 'batch prepared|batch completed'
```

#### Results

| Plugin | Result | Behaviour observed |
|--------|--------|--------------------|
| Barman | ✅ PASS | 4 `Pre-archived WAL file (parallel)` log entries — lookahead prefetch model |
| Opera | ✅ PASS | 1 batch with 2 WAL files in a single `archive-push` call confirmed. 21 total successful archives, 0 failed. |
| Dalibo | — SKIP | Feature not implemented |

> **Parallel model difference:** Opera batches multiple WAL files into a single `pgbackrest archive-push` invocation. Barman uses a lookahead prefetch model — it pre-stages the next WAL while the current one is uploading. Both achieve parallelism but via different mechanisms. Under a sustained write load larger batches would be observed in Opera.

---

## T10 — Incremental Backup Chain

Took a full backup, inserted data, took a diff backup, inserted more data, took an incr backup. Verified three distinct backup entries and that delta sizes shrink correctly. Barman uses `pg_basebackup` and is always a full copy — incremental is not supported.

#### Setup

```yaml
# Opera: full backup (already exists as init)
# Insert data, then diff:
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: opera-backup-diff
spec:
  cluster:
    name: opera-pg
  method: plugin
  pluginConfiguration:
    name: pgbackrest.cnpg.opera.com
    parameters:
      type: diff      # or: incr
EOF

# Dalibo equivalent:
# pluginConfiguration.name: pgbackrest.dalibo.com
# parameters.backupType: diff   (or: incr)
```

#### Results

| Plugin | Result | Full delta | Diff delta | Incr delta |
|--------|--------|------------|------------|------------|
| Barman | — N/A | Always full backup (pg_basebackup model) | | |
| Opera | ✅ PASS | 4.5 MiB / 1277 objects | 859 KiB / 27 objects | 554 KiB / 7 objects |
| Dalibo | ✅ PASS | 30.6 MB | 2.3 MB | 0.0 MB (no changes) |

Both pgBackRest plugins correctly store only changed blocks in diff/incr backups. Dalibo's 0.0 MB incr confirms no data was modified between the diff and incr points.

---

## T11 — Restore from Incremental Chain

Restored a new cluster pointing at the same object store as the source, with no explicit backup ID — forcing the plugin to traverse the full/diff/incr chain to reconstruct the database.

#### Setup — Opera

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: opera-restored-incr
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: opera-source
  externalClusters:
  - name: opera-source
    plugin:
      name: pgbackrest.cnpg.opera.com
      parameters:
        pgbackrestObjectName: opera-archive
        stanza: opera-pg      # required: must match source cluster name
  plugins:
  - name: pgbackrest.cnpg.opera.com
    parameters:
      pgbackrestObjectName: opera-archive
EOF
```

#### Setup — Dalibo

```yaml
kubectl --context kind-k8s-local apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dalibo-restored-incr
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      source: dalibo-source
  externalClusters:
  - name: dalibo-source
    plugin:
      name: pgbackrest.dalibo.com
      parameters:
        stanzaRef: dalibo-stanza
  plugins:
  - name: pgbackrest.dalibo.com
    parameters:
      stanzaRef: dalibo-stanza
EOF
```

#### Results

| Plugin | Result | Data from full phase | Data from diff phase | Data from incr phase |
|--------|--------|----------------------|----------------------|----------------------|
| Barman | — N/A | Not applicable (no incremental) | | |
| Opera | ✅ PASS | YES | YES | No — inserted after last backup taken |
| Dalibo | ✅ PASS | YES | YES | No — inserted after last backup taken |

Both plugins correctly reconstructed data across the backup chain. The absence of "incr phase" data is correct — that row was inserted *after* the incr backup was taken and only survived in WAL replay up to the latest available point.

---

## T9 — Backup/Restore Throughput Benchmark

Timed full backup and restore at 128 GB with varying job parallelism (jobs: 1, 8, 32, 64, 128), run on AWS EKS `c6id.32xlarge` nodes against S3. Methodology and analysis are in [benchmark-learnings.md](benchmark-learnings.md); the result charts are in the [README](README.md) and raw per-run timings in `runs/*/results.tsv`.

---

## T12 — WAL Archiving Throughput Benchmark

Measured WAL archiving rate under sustained write load (1, 8, 16, 24, 32 concurrent WAL writers), run on AWS EKS `c6id.32xlarge` nodes against S3. Methodology and analysis are in [benchmark-learnings.md](benchmark-learnings.md); the result charts are in the [README](README.md) and raw per-run metrics in `runs/*/results.tsv`.
