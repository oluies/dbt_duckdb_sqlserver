# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🛠 Common Commands

### Pipeline & dbt
- **Run full pipeline:** `make run-dbt` (Runs `deps` and `build`)
- **Debug dbt connection:** `make run-dbt-debug`
- **Clean dbt artifacts:** `make clean-dbt` (Removes `target/`, `logs/`, and `dbt_packages/`)
- **Generate documentation:** `make generate-docs`
- **Lint SQL:** `make lint` (Uses SQLFluff) or `make lint-fix` (Auto-fix)

### Infrastructure (docker compose: MinIO + SQL Server)
- **Start services:** `make compose-up` (waits for SQL Server readiness)
- **Stop services:** `make compose-down` (keeps named volumes)
- **Service status:** `make compose-ps`
- **Tail logs:** `make compose-logs`
- **Full init (compose + DB + Flyway migrate):** `make init-db`
- **Verify data in SQL Server:** `make check-mssql`
- **Inspect SCD2 table:** `make check-scb-scd2`
- **Nuke everything (containers + volumes + venv + certs):** `make nuke`

### SCB bulk-file SCD2 pipeline (new)
- **Upload seedcsv/ to MinIO (hive-partitioned):** `make upload-minio`
- **DuckDB staging + SQL Server landing:** `make load-scb-bulkfil`
- **SCD2 snapshot (sqlserver target):** `make snapshot-scb-bulkfil`
- **End-to-end:** `make run-scb-scd2`

### Duplicate-row audit pattern
- **Run pipeline tests:** `make test-scb-bulkfil` (or `make dbt-container-test-scb-bulkfil`)
- Where dupes go:
  - `unique` test on `bronze_scb_bulkfil_parquet.peorgnr` is `severity: warn`, `store_failures: true`. Failing rows persist to `main_dbt_test__audit.unique_bronze_scb_bulkfil_parquet_peorgnr` in the local DuckDB (`fidemo/my_db.duckdb`). Refreshed every run.
  - Full-context rejected rows live in `fidemo.finance.scb_bulkfil_dedup_rejects` in SQL Server, with a `_dedup_rank` column showing which "version" each row was (2 = second-newest, etc.).
  - `tests/dedup_reconciliation.sql` asserts `bronze = winners + rejects` on every test run.

### Dev container (recommended for reproducibility)
Skips all the macOS-specific system setup (brew, Python 3.12 pin, ODBC, Flyway arch). Everything runs inside a Linux container that joins the compose network.
- **Build image:** `make dbt-container-build`
- **Start (brings up mssql + minio + runner):** `make dbt-container-up`
- **Enter shell:** `make dbt-shell`
- **Run full pipeline inside the container:** `make dbt-container-run-scb-scd2`
- **VS Code:** "Reopen in Container" with the provided `.devcontainer/devcontainer.json`.

### Python & Environment
- **Setup Python environment:** `make setup-python` (Uses `uv` to create venv and install dependencies)
- **Update dependencies:** `make force-update-requirements` (Re-compiles `requirements.in` to `requirements.txt`)

### Convention — use `uv`, not `pip`
- The project venv is `uv`-managed (host and container). Any ad-hoc install goes through `uv pip install --python /opt/venv/bin/python <pkg>` inside the container, or `uv pip install --python venv_dbt_duckdb/bin/python <pkg>` on the host.
- For tools with conflicting adapter pins (e.g. `recce` pulls its own dbt versions), create an **isolated** interpreter: `uv venv /tmp/<toolname>-env --python 3.12` + `uv pip install --python /tmp/<toolname>-env/bin/python <pkg>`. Never let them rewrite `/opt/venv` or `venv_dbt_duckdb/`.
- `pip install` in raw form should not appear anywhere I write — it bypasses the lockfile discipline and makes drift hard to reproduce.

## 🏗 Architecture & Data Flow

This project implements a hybrid **ELT pipeline** (DuckDB $\rightarrow$ SQL Server).

### Data Flow
1. **Extract (Zero-copy):** dbt reads raw **Parquet files** directly from an external location using DuckDB's `external_location` capability.
2. **Transform (DuckDB/dbt):** 
    - Data is processed in an EAV (Entity-Attribute-Value) format.
    - **Parsing:** Regex extracts business keys (e.g., `household_id`) from unstructured `row_id` strings.
    - **Pivoting:** The `PIVOT` operator transforms EAV rows into wide, columnar tables (e.g., `stg_households`).
    - **Surrogate Keys:** Deterministic `MD5` hashes are used for `_sk` columns (e.g., `household_sk`) to ensure idempotency.
3. **Load (BCP):** 
    - Transformed data is exported from DuckDB to a temporary CSV.
    - The **BCP (Bulk Copy Program)** utility is used to bulk-insert the CSV into a **Microsoft SQL Server** container.
4. **Schema Management:** **Flyway** manages the SQL Server schema and migrations (found in `/migrations`).

### Project Structure
- `fidemo/models/staging/`: dbt models performing the core parsing and pivoting logic (`stg_scb_bulkfil` reads the MinIO source).
- `fidemo/models/bronze/`: typed bronze models — Parquet (`bronze_scb_bulkfil_parquet`) + DuckLake (`bronze_scb_bulkfil_ducklake`) variants in MinIO.
- `fidemo/models/exports/`: models that push into SQL Server (via `mssql` community extension; `scb_bulkfil_landing_from_parquet` and `scb_bulkfil_landing_from_ducklake`).
- `fidemo/snapshots/`: dbt SCD2 snapshots (run with `--target sqlserver`).
- `fidemo/macros/`: `common_columns.sql`, plus the custom materializations `materialization_mssql_native.sql` and `materialization_ducklake.sql`.
- `migrations/`: SQL Server schema migrations managed by Flyway.
- `cert/`: Custom/corporate certificates for secure connections.
- `Makefile`: The primary orchestrator for all pipeline and infra tasks.

## ⚠️ Known gotchas (all discovered the hard way — do not relearn)

1. **CSV encoding must be `'latin-1'`**, not any ICU name. The DuckDB CSV reader lists 300+ ICU encodings but most of them (including `ISO8859_15`, `windows-1252`, `8859_15`) apply Unicode compatibility normalization that mangles ASCII `F` (U+0046) → fullwidth `Ｆ` (U+FF26). DuckDB's three known-good CSV encodings are `utf-8`, `utf-16`, `latin-1`. For Swedish data, `latin-1` is semantically equivalent to ISO-8859-15 (divergence is only on €, Š, œ, Ÿ — none appear in names/addresses).
2. **DuckDB is pinned `==1.5.1`** in `requirements.txt`. That's the newest version where the `mssql` community extension is published for `osx_arm64`, `linux_amd64`, and `linux_arm64` on community-extensions.duckdb.org. 1.5.2+ returns 404 across all three platforms (verified via HEAD probe 2026-04-14). Before bumping, re-run the probe: `for v in 1.5.2 1.6.0 1.7.0; do for p in osx_arm64 linux_amd64 linux_arm64; do curl -sI "https://community-extensions.duckdb.org/v${v}/${p}/mssql.duckdb_extension.gz" | head -1; done; done`
3. **Python must be ≥3.10** (`PYTHON_VERSION ?= 3.12` in Makefile). The system Python on macOS Command Line Tools is 3.9.6, which can't satisfy `black>=25.12` in requirements. `setup-python` auto-heals by detecting an existing venv with the wrong Python version and rebuilding.
4. **Flyway archive is platform-specific.** The Makefile auto-detects OS+arch via `uname` and picks `macosx-arm64`, `linux-x64`, etc. A Linux tarball on a macOS host produces `cannot execute binary file: Exec format error`.
5. **The DuckLake-fed landing model uses `-- depends_on:` + hardcoded FQN**, not `ref()`. The DuckLake table lives at `lake.bronze.<name>` but `lake` is only ATTACHed mid-run inside the upstream ducklake materialization, so declaring `database='lake'` in config trips dbt's pre-run relation checks. The Parquet-fed landing uses normal `ref()`.
6. **Staging → bronze → landing must run in a single `dbt run` invocation.** The `lake` attach established by the ducklake materialization only lives within one DuckDB session; splitting into two `dbt run` calls drops it and breaks the DuckLake-path landing.
7. **`external` materialization's `partition_by` option is a comma-separated string**, not a Python list (`'year, month, day'`, not `['year','month','day']`). A list Jinja-renders to `['year','month','day']` which dbt-duckdb wraps into invalid SQL.
8. **`external` materialization's `plugin=` is only for third-party plugins** (sqlalchemy, excel, iceberg). For plain Parquet writes through DuckDB's own `COPY TO`, omit `plugin` entirely — specifying `plugin='native'` raises "Plugin native not found".
9. **Column-reference case collision**: DuckDB resolves identifiers case-insensitively. `cast(PeOrgNr as varchar) as peorgnr` errors with "referenced before defined" because the source column and the alias collide. Fix: qualify with the CTE alias — `cast(src.PeOrgNr as varchar) as peorgnr`.
10. **`setup-mssql-db` has no `setup-mssql-driver` dep.** The original dep did `apt-get install msodbcsql18` which only works on Ubuntu; `setup-mssql-db` itself only needs docker exec + sqlcmd inside the container, so no host ODBC is required.
10a. **SCD2 source must be one-row-per-key.** When multiple hive partitions cover overlapping `peorgnr` values (different delivery dates of the same companies), `stg_scb_bulkfil` and the bronze layer carry both rows. The SCD2 snapshot's MERGE on SQL Server then errors: "MERGE attempted to UPDATE/DELETE the same row more than once". Fix: **deduplicate at the silver landing** with `qualify row_number() over (partition by peorgnr order by effective_date desc) = 1`. Bronze keeps full history; silver is "latest current state per key".
11a. **DuckLake catalog version drift across DuckDB versions.** The DuckLake extension is bundled with DuckDB; bumping DuckDB (e.g. 1.4.x → 1.5.x) bumps the DuckLake schema (v0.3 → v0.4). A catalog file written by the older version errors with "DuckLake catalog version mismatch" when opened by the newer one. Fix is the `AUTOMATIC_MIGRATION true` parameter on `ATTACH`, which `materialization_ducklake.sql` now sets unconditionally — once migrated, the catalog stays at the new version (one-way, irreversible).
11. **`disable_transactions: true` is required in `profiles.yml` for DuckLake writes.** dbt-duckdb's default `BEGIN…COMMIT` wrapping does not propagate to attached catalogs — the CTAS against `lake.bronze.<table>` reports "OK created" but `ducklake_snapshot_changes` never records it, so the table silently doesn't persist. Empirically verified by inspecting the SQLite catalog between runs. With transactions disabled, DuckLake manages its own commits. Our materializations are single-statement CTAS so the loss of dbt-managed atomicity is irrelevant.
12. **macOS needs Homebrew-installed ODBC for `dbt-sqlserver`.** `pyodbc` in the venv is linked against `/opt/homebrew/opt/unixodbc/lib/libodbc.2.dylib` which Apple doesn't ship. Prerequisites for `make snapshot-scb-bulkfil` and anything touching `--target sqlserver`:
    ```bash
    brew install unixodbc
    brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
    HOMEBREW_ACCEPT_EULA=Y brew install msodbcsql18 mssql-tools18
    ```
    The DuckDB-side pipeline (`load-scb-bulkfil`) doesn't need either — the `mssql` community extension uses native TDS, no ODBC layer.
11b. **SCD2 MERGE failure after an earlier crashed run.** A snapshot whose previous MERGE crashed mid-flight can leave `dbt_valid_to IS NULL` for multiple rows with the same `peorgnr`. Every subsequent snapshot invocation then matches one source row to N target rows and errors with SQL Server 42000/8672 — even though current landing tables are clean. Diagnose with `SELECT peorgnr, COUNT(*) FROM finance.snap_scb_bulkfil_scd2 WHERE dbt_valid_to IS NULL GROUP BY peorgnr HAVING COUNT(*)>1`; recover with `make clean-pipeline-state` (drops all pipeline output tables + bronze MinIO prefixes + local DuckDB+DuckLake; does NOT touch the `fidemo` database or Flyway history) then re-run the pipeline.
12a. **`dbt show --target sqlserver --select <mssql_native model>` fails.** The `mssql_native` materialization is DuckDB-only (INSTALL + ATTACH + CTAS). Running `dbt show` against sqlserver asks that adapter to re-execute the model's SELECT, which reads from `ref('bronze_…')` (Parquet in MinIO) — the sqlserver adapter can't find that. Workaround: use `--target dev` to preview the source query, or `--target sqlserver --inline "select … from {{ source('finance_landing','…') }}"` to query what was actually written. All v2 silver tables are declared as sources in `_sources.yml` for exactly this purpose.
13. **`dbt-sqlserver` must be pinned `==1.9.0`.** Without a pin, uv resolves `dbt-sqlserver==1.3.1`, which still imports the removed `dbt.clients.agate_helper.empty_table` and crashes at module-load under dbt-core 1.10+ (current locked dbt-core is 1.11.8). `dbt-sqlserver==1.9.0` is the highest published on PyPI and is compatible with dbt-core 1.11. Also pulls in `dbt-fabric==1.9.3` + `pyodbc==5.1.0` as transitive deps — reflected in the lockfile.

## 🦆 DuckDB Extension Quick Reference

Authoritative references kept inline so Claude can build materializations without re-fetching docs.

### `mssql` community extension (DuckDB → SQL Server, native TDS)

Source: <https://duckdb.org/community_extensions/extensions/mssql> · <https://github.com/hugr-lab/mssql-extension>

- **Install / load (requires DuckDB ≥ 1.4.1):**
  ```sql
  INSTALL mssql FROM community;
  LOAD mssql;
  ```
- **Attach (preferred — via secret):**
  ```sql
  CREATE SECRET ms (TYPE mssql, host 'localhost', port 1433,
                    database 'fidemo', user 'sa', password 'MySecretPassword123!');
  ATTACH '' AS ms (TYPE mssql, SECRET ms);
  ```
  Alternate forms: ADO.NET string (`'Server=host,port;Database=...;User Id=...;Password=...'`) or URI (`'mssql://user:pass@host:port/db?encrypt=true'`).
- **Identifier syntax:** three-part — `attached_catalog.schema.table` (e.g., `ms.finance.scb_bulkfil_landing`).
- **Supported DDL/DML:**
  - `CREATE TABLE`, `CREATE TABLE AS SELECT` (CTAS uses BCP by default — setting `mssql_ctas_use_bcp = true`).
  - **`CREATE OR REPLACE TABLE` — yes**, non-atomic (DROP then CREATE).
  - `DROP TABLE` — yes. `DROP TABLE IF EXISTS` via DuckDB syntax is **not** supported; use `SELECT mssql_exec('ms', 'DROP TABLE IF EXISTS ...')`.
  - `INSERT INTO ms.schema.table SELECT ...` — yes, auto-batched (1000 rows default).
  - `UPDATE` / `DELETE` — require PK on the target; no `RETURNING`.
- **Fastest bulk path:**
  ```sql
  COPY duckdb_view TO 'ms.finance.scb_bulkfil_landing' (FORMAT 'bcp', REPLACE true);
  ```
  ~300K rows/s for simple rows (per docs).
- **Type mapping (CTAS):** `VARCHAR→NVARCHAR(MAX)`, `BOOLEAN→BIT`, `DOUBLE→FLOAT`, `TIMESTAMP→DATETIME2(7)`, `UUID→UNIQUEIDENTIFIER`. **Unsupported:** `HUGEINT`, `INTERVAL`, `LIST`, `STRUCT`, `MAP`, `ARRAY`.
- **Column mapping on existing tables:** by **name, case-insensitive** (not position). Missing target cols get NULL (must be nullable); extra source cols ignored.
- **Identity columns:** auto-excluded from INSERT. Indexes/constraints/IDENTITY must be created via `mssql_exec()`.
- **Auth:** SQL auth + Azure Entra ID. **Not supported:** Windows auth, named instances. TLS on by default; `TrustServerCertificate` is an **alias for `Encrypt`** in ADO.NET strings (not ODBC-style independent flag).

### DuckLake with SQLite catalog + S3 data path

Source: <https://ducklake.select/docs/stable/duckdb/usage/choosing_a_catalog_database#sqlite>

- **Install / load:**
  ```sql
  INSTALL ducklake;
  INSTALL sqlite;
  LOAD ducklake;
  ```
- **Attach (SQLite catalog + S3 data):**
  ```sql
  ATTACH 'ducklake:sqlite:fidemo/ducklake_catalog.sqlite' AS lake
      (DATA_PATH 's3://informat/bronze-ducklake/');
  USE lake;
  ```
- **Key ATTACH parameters:** `DATA_PATH` (required for non-DuckDB catalogs), `CREATE_IF_NOT_EXISTS` (default `true`), `METADATA_SCHEMA`, `ENCRYPTED`, `SNAPSHOT_TIME` / `SNAPSHOT_VERSION` (time-travel), `OVERRIDE_DATA_PATH`.
- **Operations:** standard `CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`, `MERGE` against `lake.schema.table`.
- **Concurrency note (SQLite):** DuckLake compensates for SQLite's single-writer model by attach/detach-per-query + retry timeouts — usable for single-host demo/dev; swap catalog to PostgreSQL for multi-writer prod.
- **S3 credentials for the data layer** are configured separately (DuckDB `s3_access_key_id` settings or a `TYPE s3` secret) — DuckLake does not manage them.
