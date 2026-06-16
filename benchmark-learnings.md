# CNPG Backup Plugin Benchmark — Learnings & Reference

## Plugins Under Test

| Plugin | Version | Vendor | Backup backend |
|---|---|---|---|
| Barman Cloud | v0.12.0 | EDB / CloudNativePG | barman-cloud (pg_basebackup) |
| Opera pgBackRest | v0.6.0 | Opera Norway | pgBackRest |
| Dalibo pgBackRest | v0.0.2 | Dalibo | pgBackRest |

---

## Architecture

### Cluster Setup (AWS)

Provisioned with `aws-setup.sh`; torn down with `aws-teardown.sh`.

- **EKS 1.35**, single node: `c6id.32xlarge` (128 vCPU, 256 GiB RAM, 2×1.9 TB local NVMe, x86_64)
- **Local NVMe storage** for PostgreSQL data via Rancher `local-path-provisioner` v0.0.34
  - NVMe formatted/mounted by a privileged DaemonSet at node startup using `nvme list | grep "Instance Storage"` to identify the device (device names are not stable across reboots)
  - Multiple PVCs share the NVMe disk via subdirectory provisioning
  - No quotas or size enforcement — space is shared freely
  - `WaitForFirstConsumer` StorageClass binding ensures correct node placement
- **Backup target**: AWS S3, separate buckets per plugin
- **S3 encryption**: AES-256 SSE-S3 enforced at bucket level (transparent to all plugins)
- **Compression**: snappy on Barman data backups; lz4 on Opera/Dalibo data backups; lz4 on all WAL

### Benchmark cluster lifecycle — rotating single cluster

The benchmark uses a **single rotating cluster** (`src-pg`) rather than three persistent clusters. For each database size:

1. Create `src-pg` and run `pgbench` init **once** — the same dataset is reused by all three plugins at that size.
2. For each plugin (barman → opera → dalibo): clear S3, reset the plugin's stanza state, attach the plugin, take a seed backup, then run the timed backups followed by the timed restores. `src-pg` **stays alive** throughout; each restore recovers from S3 into a separate cluster that is deleted after its measurement. (Per-plugin job-parallelism levels are listed under *Benchmark Job Parallelism* below.)
3. After all three plugins finish at that size, delete `src-pg` and wait for NVMe space to be reclaimed before moving to the next size.

The rotating design reuses one source dataset per size and clears S3/stanza state between plugins to avoid cross-plugin interference on the local NVMe.

### Why local-path-provisioner instead of AWS LIS CSI driver

The AWS EC2 Instance Store CSI driver (`lis.csi.aws.com`) maps one entire physical NVMe device to exactly one PVC — one cluster per node maximum. `rancher/local-path-provisioner` creates subdirectories per PVC, allowing multiple clusters (source + restore) to share the disk simultaneously.

### Why c6id.32xlarge instead of m7gd.xlarge (Graviton4)

`m7gd.xlarge` (Graviton4, arm64) was abandoned because **Dalibo v0.0.2 only publishes amd64 images**. Crashes with `exec format error` on arm64. Switched to `c6id.32xlarge` (x86_64, 128 vCPU, 256 GiB RAM, 2×1.9 TB NVMe) to get sufficient throughput headroom and avoid the arm64 incompatibility.

---

## Installation Conflicts — Running All Three Plugins Together

Opera and Dalibo conflict when installed in the same `cnpg-system` namespace:

1. **`leader-election-role`** (Role) — last applied wins, breaks the other's RBAC
2. **`metrics-auth-rolebinding`** (ClusterRoleBinding) — same collision
3. **`pgbackrest`** (Service) — last applied overwrites TLS routing annotations, breaking the other plugin's gRPC connection

**Fix**: Patch the Dalibo manifest before applying:
- Rename `leader-election-role` → `dalibo-leader-election-role`
- Rename `leader-election-rolebinding` → `dalibo-leader-election-rolebinding`
- Rename service `pgbackrest` → `pgbackrest-dalibo`
- Update server Certificate `dnsNames` to `pgbackrest-dalibo` and `pgbackrest-dalibo.cnpg-system.svc`

The benchmark script applies this patch automatically using embedded Python.

---

## Plugin-Specific Findings

### Barman Cloud

- **No incremental backups** — always full copy via `pg_basebackup`.
- **No parallel restore** — `barman-cloud-restore` has no `--jobs` flag.
- **Parallel backup** (`data.jobs`) configurable per ObjectStore.
- **Parallel WAL archiving** (`wal.maxParallel`) uses a lookahead prefetch model.
- **Multi-instance backup**: Works with any backup `target` — succeeds whether CNPG dispatches the backup to a replica (default `prefer-standby`) or the primary.
- **S3 encryption**: `AES256`/`aws:kms` are S3 server-side encryption (SSE), not client-side. No-op on Azure (Azure encrypts all Blob data by default).
- **Compression**: `gzip`, `bzip2`, `lz4`, `snappy`.
- **No application-level locking** — relies on S3 object consistency.

### Opera pgBackRest

- **Incremental backups** supported: `full`, `diff`, `incr` via `type` parameter.
- **Parallel backup** (`data.jobs`) and **parallel restore** (`restore.jobs`) both functional.
- **Parallel WAL archiving** (`wal.maxParallel`) batches multiple WALs per `archive-push`.
- **Multi-instance backup needs `target: primary`**: Under CNPG's default `prefer-standby` target the backup is dispatched to a replica and fails with `unable to find primary cluster` (exit 56) — explicit TODO in Opera's source. Set `target: primary` to pin backups to the primary (not tested here; all runs used `instances: 1`).
- **Stanza bootstrapping deadlock**: Opera does NOT auto-create the stanza on WAL archive. A backup must be triggered first. After any S3 wipe, `ContinuousArchiving` stays `False` until the first backup. Fix: restart the pod (clears stale lock state), then trigger a backup — the backup internally calls `stanza-create`.
- **S3 endpoint required**: pgBackRest v0.6.0 requires `--repo1-s3-endpoint` even for native AWS S3. Set `endpointURL: https://s3.<region>.amazonaws.com` in the Archive CRD. Without it, all commands fail with exit 37.
- **Lock behaviour**: `archive-push` and `stanza-create`/`backup` share `backup.lock` inside the sidecar pod. Patching the Archive CRD mid-archiving can trigger a stanza-create that races with archive-push (exit 37). Fix: patch CRD configs before any backup, with a 15s settle.
- **Stanza name = source cluster name**: The pgBackRest stanza is named after the CNPG cluster (`src-pg` in the benchmark). Restore clusters must specify `stanza: src-pg` in `externalClusters` parameters. Without it, pgBackRest looks for a stanza named after the new cluster and fails with `no target backup found`.
- **No Azure support**.

### Dalibo pgBackRest

- **Incremental backups** supported: `full`, `diff`, `incr` via `backupType` parameter.
- **No parallel backup or restore** exposed in the Stanza CRD.
- **No parallel WAL archiving**.
- **Auto stanza-create**: Automatically calls `stanza-create` on first WAL archive. More user-friendly than Opera.
- **Multi-instance backup needs `target: primary`**: Same as Opera — fails (exit 56) when the default `prefer-standby` target dispatches the backup to a replica; set `target: primary` to avoid it (not tested here; all runs used `instances: 1`).
- **Stanza state is in-memory**: `StanzaCreated` flag is not persisted. After any S3 wipe, pod must be restarted to clear the flag, then wait for `ContinuousArchiving=True` before triggering a backup.
- **S3 endpoint required**: `endpoint` is required in `s3Repositories` even for native AWS S3.
- **arm64 not supported**: Only publishes `linux/amd64`. Crashes with `exec format error` on Graviton.
- **Azure support**: Only plugin tested with Azure Blob Storage (Azurite e2e tests).
- **Richer CRD model**: Separate `Stanza` CRD (shareable across clusters) + optional `PluginConfig` CRD for resource limits.
- **Prometheus metrics exporter** sidecar included.
- **Pre-1.0**: v0.0.2 is explicitly pre-production.

---

## Restoring to the Backup's Consistent Point (`targetImmediate` + `backupID`)

**Symptom (when restoring to "latest")**: A restore that replays to the end of the archived WAL can fail with `FATAL: could not locate required checkpoint record at X/XXXXXXXX`. PostgreSQL finds the backup data but a checkpoint WAL segment generated *after* the backup completed was never archived — pgBackRest's `backup` records the end-of-backup LSN, while WAL archiving continues asynchronously after the backup returns.

**How the benchmark avoids it**: every restore recovers a *specific* backup with `targetImmediate: true` + `backupID` (the script reads the last timed backup's `.status.backupId` / `.status.backupName`). Recovery stops at the first consistent state contained in that backup, so no post-backup WAL is required and `src-pg` never has to be flushed or deleted before the restore. CNPG v1.28+ requires `backupID` whenever `targetImmediate` is used with plugin-based restores, which is why the script captures the ID explicitly rather than relying on an implicit "latest".

**Alternative (not used here)** — restore to *latest* while deleting the source: first force a `CHECKPOINT` + `pg_switch_wal()` and wait for `ContinuousArchiving` to confirm the WAL uploaded, then delete the cluster:

```bash
psql -U postgres -tAc "CHECKPOINT; SELECT pg_switch_wal();"
# wait for lastSuccessfulArchiveTime to update
sleep 15
# then delete the cluster
```

---

## PITR Timeline Conflict

When a stanza is shared and a restore cluster is promoted, pgBackRest archives WAL on multiple timelines. A subsequent restore fails:

```
target timeline 2 forked from backup timeline 1 at 0/5000000 which is before backup lsn
```

Fix: add `targetTLI: "1"` to `recoveryTarget`. Neither plugin documents this.

---

## NVMe Disk Management on local-path-provisioner

### PVC deletion is asynchronous

`local-path-provisioner` creates a helper pod to `rm -rf` the directory after PVC deletion. It logs "Volume has been deleted" when the helper pod **starts**, not when `rm -rf` finishes. For a 128 GB database with millions of pgbench files, the actual deletion takes several minutes after the Kubernetes PVC object disappears.

**Consequence**: Starting a new cluster immediately after PVC deletion risks `No space left on device` errors if the previous directory hasn't been fully removed yet.

**Fix**: After deleting a cluster, poll a pod with `/mnt/nvme` mounted (the benchmark uses a temporary `nvme-df-check` pod with a `hostPath` volume) and wait until `SIZE_GB + 20 GB` is free before creating the next cluster.

### local-path-provisioner vs LIS CSI

LIS CSI (`lis.csi.aws.com`) maps one entire physical NVMe device to exactly one PVC — one cluster per node maximum. `local-path-provisioner` shares the disk freely across PVCs via subdirectories, which is required to run multiple clusters (source + restore) on the same node.

---

## Benchmark Compression Configuration

| Plugin | Backup data | WAL |
|---|---|---|
| Barman | snappy | lz4 |
| Opera | lz4 | lz4 |
| Dalibo | lz4 | lz4 |

In this benchmark Barman used `snappy` for data and `lz4` for WAL; Opera and Dalibo (pgBackRest, which support `gz`, `bz2`, `lz4`, and `zst`) used `lz4` for both. `lz4` was chosen for WAL on all three plugins for cross-plugin consistency, and `snappy` for Barman data as the fastest option at a comparable compression ratio.

---

## Benchmark Job Parallelism

| Plugin | Backup jobs | Restore jobs |
|---|---|---|
| Barman | `data.jobs` (tested: 1, 8, 32, 64, 128) | not supported |
| Opera | `data.jobs` (tested: 1, 8, 32, 64, 128) | `restore.jobs` (tested: 1, 8, 32, 64, 128) |
| Dalibo | not exposed | not exposed |

---

## pgBackRest Lock Behaviour

`archive-push` (WAL archiving), `stanza-create`, and `backup` all acquire `backup.lock` at the same path (`/controller/tmp/pgbackrest`) inside the sidecar pod. They hold it for the **full duration** of the operation.

Key implications:
- Two backups cannot run concurrently on the same cluster (expected).
- Patching the Archive/Stanza CRD while archiving is active can trigger a config-reload stanza-create that conflicts with a concurrent archive-push (exit 37 = lock timeout).
- Jobs config changes (`data.jobs`) must be patched **before** any backup starts, with a settle period. The benchmark patches once per round outside `do_backup()`.
- Restore clusters run in separate pods with separate emptyDir volumes — their lock paths are physically isolated from the source cluster's lock. Concurrent restores from different stanzas do not conflict.

---

## Known Issues Not Yet Fixed in Any Plugin

- **Backup from a standby (Opera + Dalibo)**: the pgBackRest plugins fail when a backup runs on a replica (exit 56), so they can't use CNPG's default `prefer-standby` target — backups must be pinned to the primary with `target: primary`. Explicit TODO in Opera's source; not fixed in v0.6.0 or v0.0.2.
- **CNPG Issue #7566**: Node termination with local NVMe causes CrashLoopBackOff — operator doesn't auto-recover from empty PGDATA. Manual fix: `kubectl cnpg destroy <instance>`. PR #8763 in progress.

---

## Benchmark Script Notes

- Each run writes to `runs/<timestamp>-<mode>/` containing `results.tsv`, `run-info.txt`, `stats/`.
- Stats are captured by a dedicated privileged `stats-collector` pod (`nicolaka/netshoot`, `hostPID`+`hostNetwork`) running `vmstat`, `iostat`, `sar -n DEV`, and `pidstat` at 1 s intervals into `stats/<label>/`. (The separate T12 WAL benchmark instead samples `/proc/diskstats` and `/proc/net/dev` from inside the postgres container.)
- `--sanity [plugin]` runs 1 GB (SF=67) for one or all plugins to confirm end-to-end functionality.
- `--sanity barman`, `--sanity opera`, `--sanity dalibo` each take ~11 minutes.
- Full benchmark: 128 GB, plugins: barman/opera/dalibo, jobs: 1/8/32/64/128.
- Jobs config patched once per round before backups start (not inside `do_backup`) to avoid lock conflicts.
- Clusters deleted after each phase (backups, each restore) with disk reclaim wait before proceeding.
