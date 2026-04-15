# Fidemo — DuckDB ↔ SQL Server Lakehouse with SCD2

An end-to-end **medallion ELT pipeline** demonstrating:

- **DuckDB + dbt-duckdb** for read/transform against MinIO-hosted files
- **Two bronze variants side-by-side** in object storage: hive-partitioned Parquet *and* DuckLake (ACID + time travel)
- **Native TDS push** from DuckDB into SQL Server via the `mssql` community extension (no pyodbc roundtrip)
- **SCD2 change-data tracking** via `dbt snapshot` run natively against SQL Server
- A **reusable dev container** so the pipeline runs anywhere Docker runs, no host-level brew / apt dance

> ⚠️ This is a learning/demo project, not production. See `CLAUDE.md`'s "Known gotchas" section for the traps discovered building it.

---

## 🗺 Pipeline at a glance

```
seedcsv/*.txt (local tab-delimited files, Swedish text, windows-cp1252-ish)
   │
   │ create_minio_hive.py   ← parses YYYYMMDD from filename
   ▼
s3://informat/seedcsv/year=YYYY/month=MM/day=DD/scb_bulkfil_JE_*.txt   [RAW]
   │
   │ DuckDB + httpfs (read_csv, encoding='latin-1', hive_partitioning=true)
   ▼
stg_scb_bulkfil  (DuckDB view)
   │
   ├──────────────────┬──────────────────┐
   ▼                  ▼                  │
bronze-Parquet     bronze-DuckLake       │    [BRONZE: two lake variants]
(hive Parquet      (SQLite catalog       │
 in MinIO)          + Parquet in MinIO)  │
   │                  │                  │
   │ custom `mssql_native` materialization (INSTALL mssql FROM community; ATTACH; CTAS)
   ▼                  ▼
scb_bulkfil_landing_from_parquet   scb_bulkfil_landing_from_ducklake   [SILVER landing in SQL Server]
   │                  │
   │ dbt snapshot --target sqlserver (strategy=check, unique_key=peorgnr)
   ▼                  ▼
snap_scb_bulkfil_scd2           snap_scb_bulkfil_scd2_from_ducklake   [SILVER SCD2 in SQL Server]
(dbt_valid_from/to, dbt_scd_id, dbt_updated_at)
```

---

## 🚀 Quick start — container mode (recommended)

Works identically on macOS, Linux, and Windows with Docker Desktop. No brew / apt / pip dance on the host.

### TL;DR

```bash
make dbt-container-build         # one-time, ~3-5 min
make dbt-container-up            # start minio + mssql + dbt-runner
make init-db                     # create fidemo DB + run Flyway V1/V2 (host-side)
make dbt-container-run-scb-scd2  # upload + bronze + landing + snapshot (in container)
make check-scb-scd2              # verify SCD2 rows in SQL Server
```

### Step-by-step

#### 1. Build the dev image (one-time)

```bash
make dbt-container-build
```

`python:3.12-slim-bookworm` + MS ODBC 18 + `mssql-tools18` + OpenJDK 17 + Flyway (noarch) + `uv`-managed venv with `requirements.txt` pre-installed. ~3-5 min on a clean cache.

#### 2. Bring up the stack

```bash
make dbt-container-up
```

Starts three containers on the compose network:

- `minio-dbt-duckdb` (ports 9000 API / 9001 console)
- `mssql-dbt-duckdb` (port 1433)
- `dbt-fidemo-runner` (`sleep infinity` — waits for exec/attach)

Verify:

```bash
docker compose --profile dev ps
```

#### 3. Initialise SQL Server (host-side)

```bash
make init-db
```

Creates the `fidemo` database (via `docker exec sqlcmd` into the mssql container) and runs Flyway V1/V2 migrations from the host tarball. Skip if the DB state is already there from an earlier run.

#### 4. Run the pipeline inside the container

```bash
make dbt-container-run-scb-scd2
```

Executes inside `dbt-fidemo-runner`:

1. `python create_minio_hive.py` — uploads `seedcsv/*.txt` into `s3://informat/seedcsv/year=/month=/day=/`.
2. `dbt deps --profiles-dir .`
3. `dbt run --target dev` — builds staging + both bronze variants + both landings in a **single DuckDB session** (required; the DuckLake `ATTACH` only lives within one session).
4. `dbt snapshot --target sqlserver` — SCD2 snapshots for both bronze paths.

Expected tail of log: `PASS=6 WARN=0 ERROR=0 SKIP=0` (dbt run) followed by `PASS=2` (dbt snapshot).

#### 5. Run `dbt test` inside the container

Enter the container:

```bash
make dbt-shell
```

Then inside the container shell:

```bash
cd fidemo
dbt test --target dev --profiles-dir .
```

> v2 tests are declared in `fidemo/models/bronze/_bronze.yml` (`unique` + `not_null` on `peorgnr`, `not_null` on `effective_date`) plus the singular test `fidemo/tests/dedup_reconciliation.sql`. Expect `WARN=1 PASS=2` on first pass — the `unique` test is intentionally `severity: warn` because bronze has cross-delivery duplicates by design.

#### 6. Verify SCD2 landed

From the host (talks to mssql on `localhost:1433`):

```bash
make check-scb-scd2
```

For a deeper probe, from inside the container:

```bash
make dbt-shell

# inside the container:
sqlcmd -S mssql-dbt-duckdb -U fidemo_loader -P 'StrongPassword456!' -d fidemo -C -Q \
  "SELECT 'parquet' src, COUNT(*) n,
          COUNT(CASE WHEN dbt_valid_to IS NULL THEN 1 END) current_n
     FROM finance.snap_scb_bulkfil_scd2
   UNION ALL
   SELECT 'ducklake', COUNT(*),
          COUNT(CASE WHEN dbt_valid_to IS NULL THEN 1 END)
     FROM finance.snap_scb_bulkfil_scd2_from_ducklake;"
```

Expected on first pass: both rows show `n = 198`, `current_n = 198`.

#### 7. Stop the stack

```bash
make dbt-container-down   # stops runner + minio + mssql
```

Volumes (`mssql_data`, `minio_data`, and the host `fidemo/my_db.duckdb` + `fidemo/ducklake_catalog.sqlite` files) are preserved — re-running `make dbt-container-up` picks up where you left off. Use `make nuke` for a full reset.

### Or in VS Code

Command Palette → **Dev Containers: Reopen in Container**. The `.devcontainer/devcontainer.json` brings up the same `dbt-runner` service and mounts the repo at `/workspace`. Extensions (dbt Power User, SQLFluff, Python, Docker, YAML) get pre-installed. Interpreter path is set to `/opt/venv/bin/python`.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Step 4 fails downloading `mssql.duckdb_extension.gz` | Outbound HTTPS blocked, or DuckDB version drift | `docker compose --profile dev exec dbt-runner curl -sI https://community-extensions.duckdb.org/v1.5.1/linux_amd64/mssql.duckdb_extension.gz` → should return `HTTP/2 200` |
| Step 4 fails with `could not resolve host: minio-dbt-duckdb` | Runner not on the compose network | `docker compose --profile dev exec dbt-runner getent hosts minio-dbt-duckdb` → should return an internal IP |
| Step 4 fails with `Login failed for user 'fidemo_loader'` | `init-db` skipped or Flyway didn't run | `make init-db` and retry |
| Step 6 returns `Invalid object name 'finance.snap_scb_bulkfil_scd2'` | Snapshot step skipped or failed | Re-run step 4 (the snapshot phase), then retry |
| Step 4 fails with `ModuleNotFoundError: No module named 'boto3'` (or `dbt`) | Custom shell script invoking `bash -lc '...'` — the `-l` triggers `/etc/profile`, which strips `/opt/venv/bin` from PATH | Use `bash -c` (no `-l`), or activate the venv: `source /opt/venv/bin/activate && ...`, or use absolute paths `/opt/venv/bin/python` |
| Step 4 sub-step 1 fails: `Could not connect to the endpoint URL: "http://localhost:9000/..."` | `create_minio_hive.py` not honouring `MINIO_ENDPOINT_HOSTPORT` (was hardcoded) | Already fixed — script reads env var with `localhost:9000` default, container sets it to `minio-dbt-duckdb:9000` |
| Step 4 sub-step 2 fails: `Env var required but not provided: 'PARQUET_PATH'` | v1 source `raw_finance` requires env vars the container doesn't set | Already fixed — defaults `/tmp` and `*.parquet` added to `_sources.yml` so v2-only runs parse cleanly |
| Step 4 fails: `DuckLake catalog version mismatch: catalog version is 0.3, but the extension requires version 0.4` | Catalog file was written by an older DuckDB (e.g. host 1.4.x) and opened by a newer one (e.g. container 1.5.x). DuckLake schema versions differ. | Already fixed — `AUTOMATIC_MIGRATION true` is now set on `ATTACH` in `materialization_ducklake.sql`. Migration is one-way (no rollback to older DuckDB after). For a clean slate: `make clean-duckdb` |
| Snapshot fails: `MERGE attempted to UPDATE/DELETE the same row more than once` | Source landing table has multiple rows per `peorgnr` (overlapping deliveries). SCD2 requires one source row per unique_key. | Already fixed — both landing models now `qualify row_number() over (partition by peorgnr order by effective_date desc) = 1` to keep only the latest delivery per key |

---

## 🏎 Quick start — host mode (macOS/Linux, more setup)

For the times you want to run the pipeline directly on the host (fewer container layers, faster iteration):

```bash
# One-time system prereqs on macOS
brew install unixodbc
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
HOMEBREW_ACCEPT_EULA=Y brew install msodbcsql18 mssql-tools18

# Python 3.12 venv + project deps (uv downloads Python if missing)
make setup-python

# Full flow
make run-scb-scd2          # compose-up → create DB → migrate → upload → build → snapshot
make check-scb-scd2        # compare Parquet-path and DuckLake-path SCD2 tables
```

Env vars expected (defaulted in the Makefile — override as needed):

| Var | Default | Purpose |
|---|---|---|
| `MSSQL_HOST` | `localhost` | Container-mode sets to `mssql-dbt-duckdb` |
| `MSSQL_DB` | `fidemo` | Created by `setup-mssql-db` + Flyway V1 |
| `MSSQL_USER` / `MSSQL_PWD` | `fidemo_loader` / `StrongPassword456!` | Created by Flyway V1 |
| `MINIO_ENDPOINT_HOSTPORT` | `localhost:9000` | Container-mode sets to `minio-dbt-duckdb:9000` |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | `minioadmin` / `minioadminpassword` | Matches `create_minio_hive.py` defaults |
| `MSSQL_DUCKDB_CONN` | ADO.NET string → SQL Server | Used by the `mssql_native` dbt materialization |

---

## 🧱 Repository layout

```
.
├── Dockerfile                      # dev image (python:3.12 + MS ODBC + Flyway + uv venv)
├── docker-compose.yml              # minio + mssql + dbt-runner (profile: dev)
├── .devcontainer/devcontainer.json # VS Code dev-container wrapper
├── Makefile                        # orchestration for everything below
├── create_minio_hive.py            # uploads seedcsv/*.txt to s3://informat/seedcsv/year=/month=/day=/
├── seedcsv/                        # sample tab-delimited SCB bulk files
├── migrations/                     # Flyway: V1 login + schema, V2 landing table
├── cert/                           # corporate / self-signed certs (bundled for requests)
├── fidemo/                         # dbt project
│   ├── dbt_project.yml
│   ├── profiles.yml                # DuckDB (dev) + SQL Server (sqlserver) targets
│   ├── packages.yml                # dbt_utils, codegen, dbt_artifacts
│   ├── macros/
│   │   ├── materialization_mssql_native.sql    # DuckDB → SQL Server via community mssql ext.
│   │   ├── materialization_ducklake.sql        # DuckDB → DuckLake (SQLite catalog + S3)
│   │   └── common_columns.sql
│   ├── models/
│   │   ├── staging/stg_scb_bulkfil.sql         # reads MinIO via httpfs
│   │   ├── bronze/bronze_scb_bulkfil_parquet.sql   # hive-partitioned Parquet
│   │   ├── bronze/bronze_scb_bulkfil_ducklake.sql  # DuckLake
│   │   └── exports/scb_bulkfil_landing_from_*.sql  # mssql_native → SQL Server
│   └── snapshots/snap_scb_bulkfil_scd2*.sql    # SCD2 on SQL Server, both bronze paths
├── CLAUDE.md                       # Claude Code project instructions + gotchas list
├── ARCHITECTURE.md                 # design deep-dive (v1 households + v2 medallion)
└── README.md                       # you are here
```

---

## 🔑 Why the funny pieces

| Piece | Why it's there |
|---|---|
| Two bronze variants (Parquet + DuckLake) | Demo / A-B comparison. Not for production. |
| Custom `mssql_native` dbt materialization | First-class DuckDB → SQL Server push via the `mssql` community extension; native TDS, no pandas/SQLAlchemy roundtrip. |
| `disable_transactions: true` in dev profile | Required — dbt-duckdb's default `BEGIN…COMMIT` doesn't propagate to DuckLake's SQLite catalog, so writes silently don't persist. |
| `-- depends_on: {{ ref(...) }}` + hardcoded FQN in the DuckLake landing | `database='lake'` in config trips dbt's pre-run relation checks (lake not attached yet). Comment-based dependency is dbt's documented escape hatch. |
| `duckdb==1.5.1` pin | Newest DuckDB where the `mssql` community extension is published for osx_arm64 + linux_amd64 + linux_arm64 (1.5.2+ returns 404). |
| `dbt-sqlserver==1.9.0` pin | 1.3.1 imports `dbt.clients.agate_helper` which was removed in dbt-core 1.10+. |
| `encoding='latin-1'` (not `ISO8859_15`) | DuckDB's CSV reader advertises 300+ ICU encodings but most apply Unicode compatibility normalization that mangles ASCII `F` → fullwidth `Ｆ`. Only `utf-8`/`utf-16`/`latin-1` are reliable. |

Full gotcha catalogue with reasons in [`CLAUDE.md`](./CLAUDE.md#️-known-gotchas-all-discovered-the-hard-way--do-not-relearn).

---

## 🛠 Makefile cheat-sheet

### Infrastructure (docker compose)
| Command | What it does |
|---|---|
| `make compose-up` | Start MinIO + SQL Server; waits for SQL Server readiness |
| `make compose-down` | Stop both (volumes preserved) |
| `make compose-ps` / `compose-logs` | Status / tail logs |
| `make init-db` | `compose-up` → create `fidemo` DB → Flyway V1/V2 migrations |

### SCB SCD2 pipeline (host mode)
| Command | What it does |
|---|---|
| `make upload-minio` | `python create_minio_hive.py` — hive-partitioned upload |
| `make build-bronze` | staging + both bronze variants (one `dbt run` session) |
| `make load-scb-bulkfil` | staging + bronze + landing in a single session |
| `make snapshot-scb-bulkfil` | both SCD2 snapshots via `--target sqlserver` |
| `make run-scb-scd2` | full pipeline, idempotent, end-to-end |
| `make check-scb-scd2` | side-by-side union of both SCD2 tables |

### Dev container (recommended)
| Command | What it does |
|---|---|
| `make dbt-container-build` | Build the `dbt-fidemo:latest` image |
| `make dbt-container-up` | Bring up runner + minio + mssql via compose |
| `make dbt-shell` | Interactive bash inside the runner |
| `make dbt-container-run-scb-scd2` | Full pipeline inside the container |

### Python / deps
| Command | What it does |
|---|---|
| `make setup-python` | Creates the venv (Python 3.12 via uv), installs `requirements.txt`. Self-heals if an older venv is detected. |
| `make force-update-requirements` | Recompiles `requirements.in` → `requirements.txt` |

### Cleanup
| Command | What it does |
|---|---|
| `make clean` | Remove dbt + Flyway build artefacts |
| `make clean-dbt` | `target/`, `dbt_packages/`, `logs/` |
| `make clean-duckdb` | Remove local DuckDB file + DuckLake SQLite catalog |
| `make clean-mssql` | `docker compose down` (volumes preserved) |
| `make nuke` | Total reset — containers, volumes, venv, certs, DuckDB file |

---

## 🔗 Cross-layer verification

A single DuckDB session can reach **all four** storage layers — raw CSV in MinIO, bronze Parquet in MinIO, DuckLake (SQLite catalog + S3), and SQL Server (silver landings + SCD2 snapshots) — via the `httpfs`, `mssql`, and `ducklake` extensions. `scripts/verify_pipeline.py` uses this to produce three cross-layer reports for smoke-testing, diffing, and CI gating.

### What you get

| Report | What it answers |
|---|---|
| **1. Row counts per layer** | *Are the layer sizes consistent? Does `current SCD2 ≈ distinct landings ≈ (bronze winners)`?* |
| **2. Per-peorgnr drill-down** | *Follow one entity end-to-end.* Shows raw rows, both bronze copies, both landings, all rejects (with `_dedup_rank`), and all SCD2 versions (with `dbt_valid_from/to`). |
| **3. Integrity checks** | Duplicate peorgnrs in either landing + `>1 current row per peorgnr` in either snapshot + reconciliation `bronze = winners + rejects`. Exit 1 if any problem row. |

### Commands

```bash
# Host mode (localhost:1433/:9000)
make verify              # run all three reports
make verify-summary      # just the row-count table
make verify-integrity    # just the problem checks — exit 1 on fail (CI-friendly)
make verify-shell        # launch harlequin with the init SQL pre-loaded

# Container mode (reaches services via compose network names)
make dbt-container-verify
make dbt-container-verify-shell
```

Drill into a specific entity:

```bash
venv_dbt_duckdb/bin/python scripts/verify_pipeline.py --peorgnr 161020159248
```

If you skip `--peorgnr`, the tool auto-picks an entity with >1 SCD2 version (i.e. an interesting one to demo).

### Files

| File | Role |
|---|---|
| `scripts/duckdb_init.sql.template` | `INSTALL`/`LOAD`/`ATTACH` scaffolding with `${…}` env-var placeholders |
| `scripts/verify_pipeline.sql` | The three report queries, wrapped in `-- >>>REPORT-N-BEGIN/END` markers |
| `scripts/verify_pipeline.py` | Renders the template (host vs container auto-detected), extracts each report, prints Markdown tables, exits non-zero when integrity fails |

### Using the init SQL standalone (without the Python wrapper)

```bash
venv_dbt_duckdb/bin/python scripts/verify_pipeline.py --emit-init > /tmp/init.sql
duckdb -init /tmp/init.sql
# or:
harlequin -f /tmp/init.sql
```

After that, all four layers are reachable by ordinary SQL (`read_csv(…)`, `read_parquet(…)`, `lake.bronze.…`, `ms.finance.…`). Handy for free-form exploration.

---

## 🧹 Duplicate-row audit pattern

Bronze legitimately holds duplicates (one row per delivery × `peorgnr`); silver picks one winner per key. Both the **discarded duplicates** and the **fact that they were discarded** are audited rather than silently lost:

| Where | What | How to query |
|---|---|---|
| `dbt_test__audit.unique_bronze_scb_bulkfil_parquet_peorgnr` (DuckDB, refreshed each run) | Just the **duplicate `peorgnr` values** that triggered the warn-level `unique` test on bronze. Lightweight signal: "are there dupes? how many keys?" | `duckdb fidemo/my_db.duckdb -c "SELECT * FROM main_dbt_test__audit.unique_bronze_scb_bulkfil_parquet_peorgnr"` |
| `finance.scb_bulkfil_dedup_rejects` (SQL Server) | The **full rejected rows** (every column + `_dedup_rank` showing which version: 2 = second-newest delivery for that key, 3 = third-newest, …). Queryable from BI alongside the SCD2 tables. | `SELECT TOP 20 peorgnr, foretagsnamn, effective_date, _dedup_rank FROM finance.scb_bulkfil_dedup_rejects ORDER BY peorgnr, _dedup_rank;` |
| `tests/dedup_reconciliation.sql` (singular dbt test) | Asserts `bronze_count = winners_count + rejects_count` so the dedup math is verifiable. Returns 0 rows on success. | `make test-scb-bulkfil` (host) or `make dbt-container-test-scb-bulkfil` (container) |

Run the full audit pass:

```bash
make test-scb-bulkfil          # host
make dbt-container-test-scb-bulkfil   # container
```

The `unique` test runs at `severity: warn` so the pipeline doesn't break when dupes appear (they're expected). The `dedup_reconciliation` test runs at `severity: error` — if it ever fails, the dedup logic in either landing or rejects has drifted from the bronze input.

### Two distinct duplicate flavors

The audit pattern catches both, and the rejects table's `_dedup_rank` + `effective_date` columns let you tell them apart:

```sql
-- Cross-delivery dupes (NORMAL — same peorgnr in multiple delivery files).
-- These are the SCD2 input pattern; older versions rightfully reject.
SELECT peorgnr, COUNT(DISTINCT effective_date) AS deliveries_seen
FROM finance.scb_bulkfil_dedup_rejects
GROUP BY peorgnr
HAVING COUNT(DISTINCT effective_date) >= 1
ORDER BY deliveries_seen DESC;

-- Intra-delivery dupes (SUSPICIOUS — same peorgnr multiple times within ONE file).
-- Signature: a peorgnr in the rejects table with the SAME effective_date as
-- the winner (i.e. rejected even though "latest delivery" tie-broke it).
-- Indicates upstream data corruption — start an analyst conversation.
--
-- If bronze has N rows for a peorgnr in one file, rejects holds N-1 copies.
SELECT r.peorgnr, r.effective_date, r.source_file, COUNT(*) AS losing_copies_same_day
FROM finance.scb_bulkfil_dedup_rejects r
GROUP BY r.peorgnr, r.effective_date, r.source_file
ORDER BY losing_copies_same_day DESC;
```

The repo ships `seedcsv/scb_bulkfil_JE_20260301T120000_99_demo_dupes.txt` — a synthetic delivery engineered to exercise **both** flavors. Delete it if you swap in real SCB deliveries.

## 🔍 Investigate — display & diff tools

Ordered from "zero install" to "worth adding". All are compatible with both the DuckDB (`target=dev`) and SQL Server (`target=sqlserver`) sides of this project.

> **Convention**: use `uv` instead of `pip` everywhere in this project. `uv pip install --python /opt/venv/bin/python <pkg>` inside the container targets the project venv explicitly. For anything that pulls conflicting adapter deps (e.g. `recce`), use `uv venv` for an isolated interpreter instead of touching `/opt/venv`.

### 1. `dbt show` — built-in, no setup

Quickest terminal preview of any model, source, or ad-hoc SQL. Respects `ref()` / `source()`.

```bash
make dbt-shell
cd /workspace/fidemo

# DuckDB side — preview a bronze model or silver model's source query
dbt show --target dev --profiles-dir . --select bronze_scb_bulkfil_parquet --limit 10
dbt show --target dev --profiles-dir . --select scb_bulkfil_dedup_rejects  --limit 20

# SQL Server side — query the actual silver/SCD2 tables via source()
dbt show --target sqlserver --profiles-dir . --inline \
  "select peorgnr, foretagsnamn, effective_date, _dedup_rank
   from {{ source('finance_landing','scb_bulkfil_dedup_rejects') }}
   order by _dedup_rank desc" --limit 20

dbt show --target sqlserver --profiles-dir . --inline \
  "select 'parquet' src, count(*) n
     from {{ source('finance_landing','snap_scb_bulkfil_scd2') }}
   union all
   select 'ducklake',  count(*)
     from {{ source('finance_landing','snap_scb_bulkfil_scd2_from_ducklake') }}"
```

#### ⚠️ `dbt show --target sqlserver --select <model>` doesn't work — use `source()` instead

Our v2 silver models use the custom `mssql_native` materialization, which is **DuckDB-only** (it INSTALLs the `mssql` extension, ATTACHes SQL Server, and runs `CREATE OR REPLACE TABLE` over the attached catalog). Running `dbt show --target sqlserver --select scb_bulkfil_dedup_rejects` causes dbt to hand the model's SELECT — which reads `{{ ref('bronze_scb_bulkfil_parquet') }}`, a Parquet location in MinIO — to the sqlserver adapter, which then looks for a non-existent table `fidemo.finance_bronze.bronze_scb_bulkfil_parquet` and errors out.

Workable patterns:

| Intent | Command |
|---|---|
| *See what the model's query would produce against DuckDB* | `dbt show --target dev --select <model>` |
| *See what's actually in the SQL Server table (current rows)* | `dbt show --target sqlserver --inline "select … from {{ source('finance_landing','<table>') }}"` |
| *Browse the SQL Server table interactively* | `harlequin` with the mssql adapter (§3) or `sqlcmd -S mssql-dbt-duckdb …` |

All v2 silver tables are declared as sources in `fidemo/models/staging/_sources.yml` under `finance_landing` (landings + rejects + both SCD2 snapshots) so they're reachable via `source()` from either target.

### 2. VS Code **dbt Power User** — already baked into `.devcontainer/devcontainer.json`

Open the project in a dev container (Command Palette → *Dev Containers: Reopen in Container*). Extension ID `innoverio.vscode-dbt-power-user`. The devcontainer's `settings.json` pre-wires:

- `dbt.dbtPythonPathOverride = /opt/venv/bin/python` so the ext discovers the right dbt binary
- `dbt.profilesDirOverride = /workspace/fidemo` so it finds `profiles.yml`
- `dbt.queryLimit = 500` for model previews
- `sqlfluff.executablePath = /opt/venv/bin/sqlfluff` + `dialect = duckdb` for on-save linting
- `files.associations["*.sql"] = jinja-sql` so the editor highlights `{{ ref() }}` correctly

Day-to-day workflow:

| Action | How |
|---|---|
| Preview a model's rows | Right-click model in sidebar → **Preview Results** → sortable grid, export CSV/Excel |
| See the compiled SQL (`ref` resolved) | Right-click model → **Show Compiled SQL** or open `target/compiled/...` |
| See lineage | Right-click → **Show Lineage** (interactive DAG) |
| Run one model | Right-click → **Run Model** |
| Test one model | Right-click → **Test Model** |
| Run query at cursor | `Ctrl/Cmd+Enter` on any `SELECT ... FROM {{ ref('...') }}` in a scratch file |
| Definition-go-to on `ref('x')` | `F12` jumps to the model SQL |

Keybinds: open Command Palette (`Cmd+Shift+P`) → "dbt" to see everything the extension exposes.

> The dbt Power User ext offers an "Altimate AI" integration that asks for an API key. We've set `"dbt.altimateAiKey": ""` in the devcontainer so you won't be nagged — the ext still works fully without it.

### 3. `harlequin` — terminal TUI for DuckDB + SQL Server

A polished text UI with vim-style navigation, schema tree, autocomplete, and result grid. Install (add to `Dockerfile` if you want it in the image, or `uv pip install` ad-hoc in the running container — this project uses `uv` everywhere):

```bash
# Inside the container:
uv pip install --python /opt/venv/bin/python harlequin harlequin-mssql

# Browse DuckDB
harlequin /workspace/fidemo/my_db.duckdb

# Browse SQL Server
harlequin --adapter mssql --conn-str \
  "DRIVER={ODBC Driver 18 for SQL Server};SERVER=mssql-dbt-duckdb;DATABASE=fidemo;UID=fidemo_loader;PWD=StrongPassword456!;TrustServerCertificate=yes"
```

### 4. `dbt_audit_helper` — Jinja macro, row-level compare between two `ref`s

Already wired into this repo. `fidemo/packages.yml` pulls `dbt-labs/audit_helper==0.12.0`, and two analyses ship under `fidemo/analyses/`:

| Analysis | Compares |
|---|---|
| `compare_silver_landings.sql` | `finance.scb_bulkfil_landing_from_parquet` vs `_from_ducklake` — should be bit-identical row-for-row. |
| `compare_scd2_snapshots.sql` | `finance.snap_scb_bulkfil_scd2` vs `_scd2_from_ducklake` — should be identical in business columns (dbt-internal columns like `dbt_scd_id`, `dbt_valid_from/to` are excluded; they differ by microseconds per run). |

One command runs both:

```bash
make dbt-container-diff-bronze-paths
```

This compiles the analyses with `--target sqlserver` and pipes the resulting SQL into `sqlcmd`. Output:

```
=== compare_silver_landings ===
 in_a  | in_b  | count | percent_of_total
-------+-------+-------+------------------
  true |  true |  201  |  100.00
 false |  true |    0  |    0.00
  true | false |    0  |    0.00

=== compare_scd2_snapshots ===
...same shape...
```

Non-zero `in_a / in_b` asymmetry = the two bronze paths diverged.

To write your own diff (e.g., "does today's rejects table match yesterday's?"):

```sql
-- fidemo/analyses/diff_rejects_over_time.sql
{{ audit_helper.compare_relations(
    a_relation = source('finance_landing', 'scb_bulkfil_dedup_rejects'),
    b_relation = api.Relation.create(
        database='fidemo', schema='finance', identifier='scb_bulkfil_dedup_rejects_yesterday'),
    primary_key = "peorgnr"
) }}
```

### 5. `data-diff` — cross-database row-level diff CLI

Stand-alone; great for verifying that two tables *should* be identical really are. Useful here for *"is the Parquet-path SCD2 bit-identical to the DuckLake-path SCD2?"*:

```bash
uv pip install --python /opt/venv/bin/python "data-diff[mssql]"

data-diff \
  'mssql://fidemo_loader:StrongPassword456!@mssql-dbt-duckdb/fidemo' finance.snap_scb_bulkfil_scd2 \
  'mssql://fidemo_loader:StrongPassword456!@mssql-dbt-duckdb/fidemo' finance.snap_scb_bulkfil_scd2_from_ducklake \
  -k peorgnr -c foretagsnamn -c postort -c effective_date
```

Output: rows only in A, rows only in B, rows where the tracked columns differ. Can also diff **across engines** (e.g. DuckDB bronze ↔ SQL Server landing) via connection strings for each.

### 6. `recce` — PR-review UI for dbt model diffs

Spins up a local web UI that visually compares model results between two environments (typically your feature branch vs `main`). Overkill for poking at the rejects table; right fit once you start opening PRs that touch models.

**Install** (recce pulls its own dbt-adapter deps — install it as an **isolated `uv` tool** so it can't downgrade the project's dbt-core / dbt-duckdb / dbt-sqlserver pins):

```bash
# Inside the container:
uv tool install recce
# ~/.local/bin/recce now on PATH (add ~/.local/bin if your shell hasn't picked it up)
recce version
```

**Workflow** (recce's CLI as of v1.43, per [docs.reccehq.com](https://docs.reccehq.com/setup-guides/environment-setup/)): recce diffs **two dbt targets**, each producing its own artifact directory. `recce run` writes a state file; `recce server` takes that state file as a **positional** argument.

```bash
# 1. Build the base environment (e.g. against `main`) into target-base/
cd /workspace/fidemo
dbt build --target dev --profiles-dir . --target-path target-base/

# 2. Build the current environment (your changes) into target/
dbt build --target dev --profiles-dir .

# 3. Produce the recce state file (compares target/ vs target-base/)
recce run --state-file recce_state.json

# 4. Open the UI (STATE_FILE is positional on `recce server`)
recce server recce_state.json
#   → http://localhost:8000
```

Key facts (directly from the upstream CLI help):

- `recce run [OPTIONS]` — `--state-file` is a **flag** (default `recce_state.json`).
- `recce server [OPTIONS] [STATE_FILE]` — `STATE_FILE` is a **positional** arg. `--review` loads artifacts from the state file instead of `target/`.
- Recce expects `target/` and `target-base/` pre-populated; it does **not** run dbt internally.

For cloud state, GitHub Actions CI, and column-level lineage caching, see [docs.reccehq.com](https://docs.reccehq.com) or invoke the `recce-quickstart` skill.

### What to reach for, per task

| Task | Best tool |
|---|---|
| *"Show me the rejected rows"* | `dbt show ... --select scb_bulkfil_dedup_rejects` |
| *"Click around interactively"* | VS Code dbt Power User (devcontainer) |
| *"Browse both DuckDB and SQL Server"* | `harlequin` |
| *"Are the Parquet and DuckLake SCD2 identical?"* | `data-diff` |
| *"Did this refactor change any output rows?"* | `dbt_audit_helper` |
| *"Review a model-touching PR"* | `recce` |

## 🔒 Security

- **Least privilege:** the DuckDB→SQL Server push uses `fidemo_loader`, a restricted user scoped to the `finance` schema (see `migrations/V1__setup_permissions_and_schema.sql`). `sa` is only used by the bootstrap step that creates the `fidemo` database.
- **Secrets:** passwords live in Makefile default vars. For anything beyond a demo: use `.env` + `docker compose --env-file`, or a real secrets manager. Do not commit a modified Makefile with real creds.
- **Corporate certs:** `cert/` is bundled into a combined CA bundle at install time; set `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE` so `uv` and `dbt deps` trust internal hosts.

---

## 📚 Further reading

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — design discussion, Kimball key strategy, v1 (households Parquet) vs v2 (SCB medallion), trade-offs.
- [`CLAUDE.md`](./CLAUDE.md) — Claude Code instructions, DuckDB extension quick-reference, **"Known gotchas" list** (build traps discovered the hard way).
- [`hugr-lab/mssql-extension`](https://github.com/hugr-lab/mssql-extension) — upstream docs for the DuckDB `mssql` community extension.
- [DuckLake docs](https://ducklake.select/docs/stable/) — catalog/ACID layer over object storage, used for the second bronze variant.

## 🎯 Presentation decks

Two PowerPoint decks are generated from `scripts/build_*_deck.py` (regenerable; not checked in):

- `docs/fidemo_stakeholder_overview.pptx` — 14 slides, **management audience**: outcomes, value framing, proof points, no code.
- `docs/fidemo_engineer_deepdive.pptx` — 14 slides, **engineer audience**: materialization internals, gotchas, version-pin matrix, code snippets.

Build / rebuild both:

```bash
make build-decks
```

Edit either `scripts/build_stakeholder_deck.py` or `scripts/build_engineer_deck.py` to change wording/structure, then re-run.
