# In-Depth Comparison: cnpg-plugin-pgbackrest-opera vs cnpg-plugin-pgbackrest-dalibo

## 0. Origins — What Each Repo Actually Is

Understanding each project's origin is essential context for interpreting every other metric.

> **Opera** is a **direct fork-and-rename of the official CNPG barman-cloud plugin**. The single commit `fork!: create pgBackRest plugin` (2025-03-24, Szymon Soloch) is a mass search-and-replace: `barmancloudv1` → `pgbackrestv1`, `plugin-barman-cloud` → `cnpg-plugin-pgbackrest`, with the barman backup backend swapped out for pgBackRest. The 132 commits before that point were written by the EDB/CNPG core team (Francesco Canovai, Leonardo Cecchi, Armando Ruocco, Gabriele Bartolini, Jonathan Gonzalez V.) building the barman plugin — **none of that work is Opera's own**. Post-fork, Opera has 49 commits from 6 authors, none of whom are EDB/CNPG maintainers.

> **Dalibo** was **written from scratch**. Julian Vanden Broeck started with an empty repo on 2025-01-13 — two months before Opera's fork — and built iteratively: a stub operator with `TODO` comments, then WAL archiving, then restore, then storage backends. The module path `github.com/dalibo/cnpg-i-pgbackrest` was set on day one. Two specific utility pieces were explicitly borrowed from barman much later (December 2025, nearly a year in): a scheme-registration pattern and an `ExtendedClient` cache, both with attribution. The pgBackRest-specific logic — config model, stanza management, env-var conversion, the exporter — is entirely original.

> **The implication:** comparing raw commit counts or author counts without this context is misleading. Opera's apparent breadth of EDB authorship is pre-fork barman work. Dalibo's lower commit count reflects a genuinely smaller team building from scratch. On an equal footing, Opera has 6 post-origin human contributors vs Dalibo's ~7, and ~49 (Opera) vs ~220 (Dalibo) own commits — though Dalibo's higher count partly reflects a less disciplined commit style (many small refactor and doc commits).

## 1. Git History & Commit Counts (post-origin only)

| Metric | Opera (post-fork, 2025-03-24 onward) | Dalibo (full history, 2025-01-13 onward) |
|--------|--------------------------------------|------------------------------------------|
| Own commits | 49 | 220 |
| Date range | 2025-04-28 → 2026-05-28 | 2025-01-13 → 2026-04-24 |
| First public release | 0.1.1 (2025-05-13) | 0.0.1b (2026-02-27) |
| Latest release | 0.6.0 (2026-05-28) | 0.0.2 (2026-04-17) |
| `fix:` commits (substantive) | 16 | ~15 |
| `feat:` commits | 6 | ~49 (informal style) |
| test/e2e commits | 4 | ~40 |
| Dependency/chore commits | 1 | ~10 |
| Commit style | Conventional commits, enforced by commitlint | Informal, no enforced style |

Dalibo's much higher commit count partly reflects granular, frequent commits (single-file refactors, doc tweaks, test adjustments each get their own commit). Opera's 49 commits are more consolidated. The fix counts are comparable — about 15–16 each — which is the more meaningful signal.

## 2. Authors

| Repo | Post-origin authors | Notes |
|------|---------------------|-------|
| Opera | 6 humans: Szymon Sołoch / @Agalin (34 — same person, two commit identities), ermakov-oleg (10), Piotr Szyma (2), Boris Mironov (1), Douglass Kirkley (1), shajia / Afeedh Shaji (1) | None are EDB/CNPG maintainers. The EDB team's work is entirely pre-fork barman code. |
| Dalibo | 7 humans: Julian Vanden Broeck (~197), Pierrick Chovelon (~22), Alexandre Pereira (2), Robin Portigliatti (1), Kahfi Elhady (1), RedouaneCapture (1), others (1) | Effectively a solo project; Julian wrote ~90% of all commits. |

Both have similar bus-factor risk. Opera is highly concentrated — its top author (Szymon Sołoch / Agalin) wrote ~70% of post-fork commits; Dalibo's top author (Julian Vanden Broeck) wrote ~90%. Neither has CNPG core maintainer involvement in the pgBackRest-specific code.

## 3. Code Volume & Complexity

| Metric | Opera | Dalibo |
|--------|-------|--------|
| Go source lines (non-test, non-generated) | ~10,326 | ~6,030 |
| Unit test lines | ~2,417 | ~2,565 |
| E2E test lines | ~3,314 | ~1,935 |
| Internal packages | 10+ distinct packages | Flatter structure, fewer packages |
| Config-to-command approach | Typed API structs → CLI flags via `commandbuilder.go` (260 lines) | Reflection-based struct→envvar via `StructToEnvVars()` |

Opera is larger because it inherited the barman plugin's operator/instance/restore plumbing fully formed, then built on top. Dalibo built the same plumbing incrementally, resulting in a leaner but functionally equivalent base. Opera's `internal/pgbackrest/` is more decomposed: dedicated packages for `api`, `archiver`, `backup`, `catalog`, `command`, `credentials`, `restorer`, `spool`, `utils`, `walarchive`. Dalibo keeps more logic in fewer files.

Dalibo's `StructToEnvVars()` reflection approach is an original design: struct field tags drive environment variable generation automatically. It reduces boilerplate but is harder to trace than Opera's explicit flag-by-flag construction.

## 4. Language & Technology Choices

| Aspect | Opera | Dalibo |
|--------|-------|--------|
| Go version | 1.25 | 1.26 (more current) |
| CNPG API version | 1.27 | 1.29 (more current) |
| Test framework | Ginkgo/Gomega (BDD-style, inherited from barman) | Standard `testing` package (written from scratch) |
| CI system | Dagger pipelines via Taskfile (inherited from barman) | Traditional Makefile + GitHub Actions (original) |
| Commit convention | Conventional commits enforced (inherited from barman) | None |
| CRD model | Single `Archive` CRD | Separate `Stanza` + `PluginConfig` CRDs |
| CRD domain | `pgbackrest.cnpg.opera.com` | `pgbackrest.dalibo.com` |
| Documentation | Plain Markdown | Docusaurus website |

Several of Opera's engineering-practice advantages — Dagger CI, Ginkgo tests, conventional commits, release-please automation — were inherited from the barman plugin template, not independently chosen. Dalibo's simpler toolchain is a deliberate from-scratch choice.

Dalibo's split CRD model (a `Stanza` object separate from the cluster, plus a `PluginConfig` for operator-level settings) is a meaningful architectural departure. It allows a stanza to be shared across clusters and monitored independently via status conditions and Prometheus metrics.

## 5. Testing Depth & Coverage

### Opera

E2E tests use Ginkgo (inherited framework) and cover three suites:

- **`backup/`** — backup + restore with data verification, PITR with row-level correctness checks, backup from a restored cluster
- **`parallelarchive/`** — inspects container log JSON to verify WAL files are genuinely batched in parallel, not just configured to be
- **`replicacluster/`** — full replica cluster switchover: backup, create replica, demote primary, promote replica, verify WAL continuity and data

Unit tests cover: `api/config`, `archiver/command`, `backup`, `catalog` (360 lines), `command/commandbuilder`, `restorer`, `spool`.

### Dalibo

E2E tests use the standard `testing` package in a single file (~400 lines), covering:

- **`TestInstall`** — plugin deployment and service labels
- **`TestDeployInstance`** — PVC creation, CPU/memory limit enforcement from `PluginConfig` CRD, spool PVC binding
- **`TestCreateAndRestoreInstance`** — multi-backup sequence, PITR with row count verification, recovery window status checks
- **`TestAzure`** — Azure Blob Storage via Azurite (not covered by Opera)

Dalibo's E2E tests cover infrastructure concerns (resource limits, PVC provisioning) that Opera doesn't test. Opera's E2E tests cover more complex cluster topologies (replica switchover, parallel archiving internals). Neither is strictly a superset of the other.

## 6. Bug Fixes & Corner Cases Found

Both repos have ~15–16 substantive fix commits post-origin. The *nature* of the fixes differs:

### Opera's fixes — deeper operational/concurrency bugs

- `fix: wal archive - early return if WAL was already archived` — idempotency bug in WAL archiving
- `fix: always use absolute paths for WAL upload` — path resolution failure under certain working directories
- `fix: deduplicate Archive object references to prevent duplicate volume projections` — Kubernetes volume projection bug
- `fix: disable end-of-wal flag management during backup restoration` — race condition during restore
- `fix: set LeaderElectionReleaseOnCancel to true to enable RollingUpdates` — rolling update deadlock
- `fix: improve reliability of object cache management` — cache coherency issue
- `fix: add clusters/finalizers RBAC permission for OwnerReferencesPermissionEnforcement` — RBAC gap blocking garbage collection
- `fix: replica source object store on replica clusters being promoted` — wrong object store after switchover
- `fix: correct restore_command on CNPG 1.29` — breaking API change
- `fix: parsing PgbackrestRetention.History` — config parsing regression
- `fix: conflicting leaderElectionId between backup plugins` — multi-plugin coexistence bug

### Dalibo's fixes — earlier-stage correctness and setup bugs

- `Fix non-working restore function` — fundamental restore correctness fix (early in development)
- `Fix wrong error retrieve / usage on backupinfo` — error handling bug
- `Fix secret name used for exporter sidecar image` — misconfiguration
- `fix: change LeaderElectionID to avoid conflict with barman cloud plugin` — same class as an Opera fix, found independently
- `Fix small typo on resource stanza type on test`, `Fix typo into CRD` — schema/test errors
- Various documentation and example fixes

Opera's fixes read like production operational discoveries — concurrency, RBAC, path bugs, cluster topology edge cases. Dalibo's read like the expected corrections of a project still reaching initial correctness. This gap is plausibly explained by Opera having been deployed in real clusters for longer; Dalibo is still pre-1.0.

## 7. Unique Features

*Researched with AI tools - not everything here is fully verified.*

| Feature | Opera | Dalibo |
|---------|-------|--------|
| Parallel WAL upload (batch archiving) | Yes (dedicated feature + e2e test) | No |
| Replica cluster / switchover support | Yes (e2e tested) | No |
| Point-in-time recovery (PITR) | Yes (e2e tested) | Yes (e2e tested) |
| Azure Blob Storage | Not e2e tested | Yes (e2e tested with Azurite) |
| GCS (Google Cloud Storage) | Yes (e2e tested pre-fork in barman lineage) | No |
| pgBackRest metrics exporter sidecar | No | Yes (custom Prometheus sidecar) |
| Backup count / recovery window in CRD status | No | Yes (`StanzaStatus`) |
| Resource limits via `PluginConfig` CRD | No | Yes |
| Async WAL spool via dedicated PVC | No (spool exists but no dedicated PVC) | Yes |
| Stanza maintenance / retention policy loop | No | Yes |
| Full/diff/incr backup type selection | No | Yes |
| Custom env vars for pgbackrest | No | Yes |
| Separate Stanza CRD (shared across clusters) | No | Yes |

## 8. Summary

**Opera** started as a renamed copy of the CNPG barman-cloud plugin — the CI tooling, test framework, release automation, and operator/instance/restore plumbing all came pre-built from the EDB team. Opera's own contribution (49 post-fork commits, 6 authors over ~13 months) is the pgBackRest backend, the `Archive` CRD, parallel WAL archiving, and replica cluster support. Its fix history suggests real production exposure: the bugs found are the kind that only appear when clusters are actually running under load and in complex topologies.

**Dalibo** built independently from scratch, starting two months before Opera forked. With 220 commits and a richer feature set — Azure support, Prometheus metrics, a separate `Stanza` CRD, resource limit controls, retention management — it is more ambitious in scope. But at version 0.0.2 it is still pre-production by its own versioning, and its fix history reflects early-stage correctness work rather than operational hardening. The reflection-based config approach and the separate `Stanza` CRD are original architectural ideas; the code quality is high but the project is effectively carried by one person.

**Bottom line:** Opera is more battle-tested and operationally mature, but arrived there partly by standing on existing shoulders. Dalibo is more feature-rich and architecturally original, but earlier in its maturity curve. For production use today, Opera's track record of finding and fixing real operational bugs gives it an edge. For feature completeness (Azure, metrics, fine-grained operator control), Dalibo is ahead — and likely to close the maturity gap as it approaches 1.0.			
