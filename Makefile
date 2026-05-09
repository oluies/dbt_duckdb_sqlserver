.PHONY: setup-mssql-driver setup-mssql-db setup-python setup-certs setup-flyway migrate-db init-db \
        force-update-requirements lint lint-fix generate-docs \
        check-data explore-data \
        upload-minio build-bronze load-scb-bulkfil test-scb-bulkfil \
        snapshot-scb-bulkfil run-scb-scd2 check-scb-scd2 \
        verify verify-summary verify-integrity verify-shell \
        compose-up compose-down compose-ps compose-logs \
        dbt-container-build dbt-container-up dbt-container-down dbt-shell \
        dbt-container-run-scb-scd2 dbt-container-test-scb-bulkfil dbt-container-diff-bronze-paths \
        dbt-container-verify dbt-container-verify-shell \
        run-dbt run-dbt-debug \
        build-decks \
        clean clean-flyway clean-dbt clean-mssql clean-venv clean-certs clean-duckdb \
        clean-pipeline-state nuke

# --- Configuration ---
# Certificate Config
CERT_DIR := cert
COMBINED_CERT := $(CERT_DIR)/combined_bundle.pem
SYSTEM_CERT := /etc/ssl/certs/ca-certificates.crt

# Project Directory Name
PROJECT_DIR := fidemo

# Flyway Config (Använd en version som garanterat finns)
FLYWAY_VERSION := 10.22.0
FLYWAY_DIR := flyway-$(FLYWAY_VERSION)
# Detect OS + arch so the right Flyway archive is picked.
# Supported archive suffixes (per Maven Central):
#   linux-x64, linux-arm64, macosx-x64, macosx-arm64, windows-x64
FLYWAY_OS := $(shell uname -s | tr A-Z a-z | sed 's/darwin/macosx/')
FLYWAY_ARCH := $(shell uname -m | sed -e 's/x86_64/x64/' -e 's/aarch64/arm64/')
FLYWAY_URL := https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/$(FLYWAY_VERSION)/flyway-commandline-$(FLYWAY_VERSION)-$(FLYWAY_OS)-$(FLYWAY_ARCH).tar.gz
MIGRATIONS_DIR := migrations


# Data Config
# Default to all parquet files, but allow override via command line
export FILE_PATTERN ?= *.parquet
export PARQUET_PATH := /mnt/c/Temp/parquet_exampels

# --- Python / UV Configuration  ---
VENV := venv_dbt_duckdb
PYTHON := $(VENV)/bin/python
DBT := ../$(VENV)/bin/dbt
DB_FILE := $(PROJECT_DIR)/my_db.duckdb
# Minimum Python version — requirements.txt pins packages (e.g. black>=25.12.0)
# that need >=3.10. macOS Command Line Tools ships 3.9, so we must pin
# explicitly; uv will auto-download a matching interpreter if missing.
PYTHON_VERSION ?= 3.12

# --- Certificate Bundle Target ---
$(COMBINED_CERT): $(CERT_DIR)/root.cer $(CERT_DIR)/http.cer
	@echo "🚧 Building Super Certificate Bundle..."
	@cat $(SYSTEM_CERT) > $(COMBINED_CERT)
	@echo "" >> $(COMBINED_CERT)
	@cat $(CERT_DIR)/root.cer >> $(COMBINED_CERT)
	@echo "" >> $(COMBINED_CERT)
	@cat $(CERT_DIR)/http.cer >> $(COMBINED_CERT)
	@echo "✅ Created $(COMBINED_CERT)"

setup-certs: $(COMBINED_CERT)

# --- MSSQL Driver Setup (Run once in WSL) ---
setup-mssql-driver:
	@echo "🔧 Installing Microsoft ODBC Driver 18 for SQL Server..."
	curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
	curl https://packages.microsoft.com/config/ubuntu/$$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list
	sudo apt-get update
	sudo ACCEPT_EULA=Y apt-get install -y msodbcsql18 unixodbc-dev
	@echo "✅ ODBC Driver installed."

# --- MSSQL Container Setup ---
# NOTE: Container lifecycle is managed by docker compose (see compose-up / compose-down).
#       The old `setup-mssql-container` target was retired in favor of the compose workflow
#       so that MinIO and SQL Server share one orchestration path.

setup-mssql-db:
	@echo "🏗️ Creating empty database 'fidemo'..."
	@# Runs inside the SQL Server container via docker exec — no host ODBC needed.
	@docker exec -i mssql-dbt-duckdb /opt/mssql-tools18/bin/sqlcmd \
		-S localhost -U sa -P 'MySecretPassword123!' -C -Q "\
		IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'fidemo') \
			CREATE DATABASE fidemo; \
		"
	@echo "✅ Database created."

# --- Flyway ---

setup-flyway:
	@if [ ! -d "$(FLYWAY_DIR)" ]; then \
		echo "🦅 Hämtar Flyway $(FLYWAY_VERSION)..."; \
		curl -L $(FLYWAY_URL) -o flyway.tar.gz; \
		echo "📦 Packar upp..."; \
		tar -xzf flyway.tar.gz; \
		rm flyway.tar.gz; \
		echo "✅ Flyway installerat i $(FLYWAY_DIR)"; \
	else \
		echo "✅ Flyway finns redan."; \
	fi

migrate-db: setup-flyway
	@echo "🚀 Kör Flyway (Skapar Users, Scheman, Tabeller)..."
	@$(FLYWAY_DIR)/flyway \
		-url="jdbc:sqlserver://localhost:1433;databaseName=fidemo;encrypt=true;trustServerCertificate=true" \
		-user="sa" \
		-password="MySecretPassword123!" \
		-locations="filesystem:$(MIGRATIONS_DIR)" \
		-baselineOnMigrate=true \
		migrate
	@echo "✅ Databasstrukturen och rättigheter är uppdaterade!"

# --- Main Init Command ---
# Detta ersätter det gamla långa flödet
init-db: compose-up setup-mssql-db migrate-db
	@echo "🎉 Allt klart! Databasen 'fidemo' är redo med tabeller och användaren 'fidemo_loader'."

# --- MSSQL Verification  ---
# NOTE: the v1 check-mssql target (SELECTed from finance.stg_households_landing)
# was removed when the v1 households pipeline was retired. Use `check-scb-scd2`
# to verify the v2 SCD2 tables, or sqlcmd directly.

setup-python: setup-certs
	@# Rebuild the venv if it doesn't exist OR was created against the wrong Python
	@if [ ! -x "$(PYTHON)" ] || ! "$(PYTHON)" -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then \
		echo "🌱 Creating virtual environment with Python $(PYTHON_VERSION)..."; \
		rm -rf $(VENV); \
		uv venv --python $(PYTHON_VERSION) $(VENV); \
	fi
	@# Always try to install/sync requirements (uv is fast enough to skip if nothing changed)
	SSL_CERT_FILE=$(PWD)/$(COMBINED_CERT) UV_LINK_MODE=copy uv pip install -r requirements.txt --python $(PYTHON)

# --- Force Update Requirements ---
force-update-requirements: setup-certs
	@echo "🔥 Forcing full requirement resolution and sync..."
	@# 1. Compile requirements.in -> requirements.txt (with upgrade)
	SSL_CERT_FILE=$(PWD)/$(COMBINED_CERT) UV_LINK_MODE=copy uv pip compile requirements.in -o requirements.txt --upgrade
	@# 2. Sync venv with the new lockfile
	SSL_CERT_FILE=$(PWD)/$(COMBINED_CERT) UV_LINK_MODE=copy uv pip sync requirements.txt --python $(PYTHON)
	@echo "✅ Forced update complete!"

# --- Data Ingestion / Exploration ---

check-data: setup-python
	@echo "🔍 Peeking at top 10 rows from $(PARQUET_PATH)..."
	@$(PYTHON) -c "import duckdb; \
		duckdb.sql(\"SELECT * FROM '$(PARQUET_PATH)/*.parquet' LIMIT 10\").show()"

deprecated-load-data: setup-python
	@echo "💾 Loading Parquet files into '$(DB_FILE)'..."
	@# Ensure the directory exists first!
	@mkdir -p $(PROJECT_DIR)
	@$(PYTHON) -c "import duckdb; \
		con = duckdb.connect('$(DB_FILE)'); \
		con.execute(\"CREATE OR REPLACE TABLE raw_finance AS SELECT * FROM '$(PARQUET_PATH)/*.parquet'\"); \
		count = con.execute('SELECT COUNT(*) FROM raw_finance').fetchone()[0]; \
		print(f'✅ Successfully loaded {count} rows into table raw_finance'); \
		con.close()"

explore-data: setup-python
	@echo "📊 Exploring table contents in $(DB_FILE)..."
	@$(PYTHON) -c "import duckdb; \
		con = duckdb.connect('$(DB_FILE)'); \
		print('\n--- DISTINCT REPORTS (report_table) ---'); \
		con.sql(\"SELECT report_table, COUNT(*) as rows FROM raw_finance GROUP BY report_table ORDER BY 1\").show(); \
		print('\n--- SAMPLE DATA (Non-Null Values) ---'); \
		con.sql(\"SELECT report_table, row_id, column_id, val_dec, val_str FROM raw_finance WHERE val_dec IS NOT NULL LIMIT 5\").show(); \
		print('\n--- ROW/COL STRUCTURE (For one report) ---'); \
		first_report = con.sql(\"SELECT report_table FROM raw_finance LIMIT 1\").fetchone()[0]; \
		con.sql(f\"SELECT row_id, column_id, val_dec FROM raw_finance WHERE report_table = '{first_report}' ORDER BY row_id, column_id LIMIT 10\").show(); \
		con.close()"
		


# --- dbt Targets ---

run-dbt: setup-python setup-certs migrate-db
	# Export the Service Account Credentials
	export MSSQL_USER='fidemo_loader' && \
	export MSSQL_PWD='StrongPassword456!' && \
	export MSSQL_DB='fidemo' && \
	export REQUESTS_CA_BUNDLE=$(PWD)/$(COMBINED_CERT) && \
	export PARQUET_PATH='/mnt/c/Temp/parquet_exampels' && \
	cd $(PROJECT_DIR) && \
	$(DBT) deps && \
	$(DBT) build --profiles-dir . $(ARGS)


run-dbt-debug: setup-certs
	export MSSQL_PWD='MySecretPassword123!' && \
	export REQUESTS_CA_BUNDLE=$(PWD)/$(COMBINED_CERT) && \
	cd $(PROJECT_DIR) && \
	$(DBT) deps && \
	$(DBT) debug  build --profiles-dir . $(ARGS)

generate-docs: setup-certs
	export MSSQL_PWD='MySecretPassword123!' && \
	export REQUESTS_CA_BUNDLE=$(PWD)/$(COMBINED_CERT) && \
	cd $(PROJECT_DIR) && \
	$(DBT) docs generate && \
	../$(PYTHON) -m dbterd run -t mermaid -s schema:main_public

# --- Linting ---

lint:
	cd $(PROJECT_DIR) && \
	../$(PYTHON) -m sqlfluff lint models --dialect duckdb

lint-fix:
	cd $(PROJECT_DIR) && \
	../$(PYTHON) -m sqlfluff fix models --dialect duckdb

# NOTE: the v1 BCP-via-CSV flow (load-bcp target + BCP_* variables) was
# removed alongside the v1 households models. It exported stg_households
# to a pipe-delimited CSV and imported to finance.stg_households_landing
# via the BCP utility. v2 replaces this with the `mssql` community
# extension's native TDS bulk path — see fidemo/macros/materialization_mssql_native.sql
# and README § "Why the funny pieces".

# ==========================================
# 🐳 DOCKER COMPOSE (MinIO + SQL Server)
# ==========================================

compose-up:
	@echo "🐳 Starting MinIO + SQL Server via docker compose..."
	docker compose up -d
	@echo "⏳ Waiting for SQL Server to accept connections..."
	@for i in $$(seq 1 30); do \
		if docker exec mssql-dbt-duckdb /opt/mssql-tools18/bin/sqlcmd \
			-S localhost -U sa -P 'MySecretPassword123!' -C -Q "SELECT 1" >/dev/null 2>&1; then \
			echo "✅ SQL Server is ready."; \
			break; \
		fi; \
		echo "   ...still waiting ($$i/30)"; \
		sleep 2; \
	done

compose-down:
	@echo "🐳 Stopping docker compose services..."
	docker compose down

compose-ps:
	@docker compose ps

compose-logs:
	@docker compose logs --tail=100 -f

# ==========================================
# 🧑‍💻 DEV CONTAINER (reusable dbt + Python + Flyway image)
# ==========================================
# See ./Dockerfile and .devcontainer/devcontainer.json. Lets you avoid the
# macOS-specific toolchain (brew unixodbc, msodbcsql18, dbt-sqlserver pin,
# DuckDB pin, platform-specific Flyway) by running the pipeline inside a
# pre-baked Linux container that joins the compose network.

dbt-container-build:
	@echo "🐳 Building dbt-fidemo image..."
	docker compose --profile dev build dbt-runner

dbt-container-up:
	@echo "🐳 Bringing up dbt-runner (+ MinIO + SQL Server)..."
	docker compose --profile dev up -d

dbt-container-down:
	@echo "🐳 Stopping dbt-runner..."
	docker compose --profile dev down

# Interactive bash inside the runner. MinIO + SQL Server are reached by
# service name; all env vars are pre-set in the image.
dbt-shell: dbt-container-up
	@echo "🐚 Entering dbt-fidemo-runner shell..."
	docker compose --profile dev exec dbt-runner bash

# Full pipeline inside the container. Equivalent of `make run-scb-scd2` but
# runs against compose-network service names instead of localhost.
# NOTE: `bash -c` (NOT `bash -lc`) — a login shell re-sources /etc/profile
# which clobbers $PATH and drops /opt/venv/bin, so `python` would resolve to
# /usr/local/bin/python (system Python, no project deps).
dbt-container-run-scb-scd2: dbt-container-up
	@echo "🦆 Running full SCB SCD2 pipeline inside dbt-fidemo-runner..."
	docker compose --profile dev exec dbt-runner bash -c '\
		cd /workspace && \
		python create_minio_hive.py && \
		cd fidemo && \
		dbt deps --profiles-dir . && \
		dbt run --target dev --profiles-dir . \
		  --select stg_scb_bulkfil \
		           bronze_scb_bulkfil_parquet bronze_scb_bulkfil_ducklake \
		           scb_bulkfil_landing_from_parquet scb_bulkfil_landing_from_ducklake \
		           scb_bulkfil_dedup_rejects && \
		dbt snapshot --target sqlserver --profiles-dir . \
		  --select snap_scb_bulkfil_scd2 snap_scb_bulkfil_scd2_from_ducklake'

# ==========================================
# 📊 PRESENTATION DECKS (python-pptx generators)
# ==========================================
# Two decks built from the same project, different audiences:
#   docs/fidemo_stakeholder_overview.pptx  — management view, no code/gotchas
#   docs/fidemo_engineer_deepdive.pptx     — engineering deep-dive, with code
# Sources of truth live in scripts/build_*_deck.py — edit there, never the .pptx.

build-decks: setup-python
	@echo "📊 Generating stakeholder + engineer decks..."
	@$(PYTHON) -c "import pptx" 2>/dev/null || \
		uv pip install --python $(PYTHON) python-pptx
	$(PYTHON) scripts/build_stakeholder_deck.py
	$(PYTHON) scripts/build_engineer_deck.py
	@echo "✅ Decks written to docs/"

dbt-container-test-scb-bulkfil: dbt-container-up
	@echo "🧪 Running dbt tests inside dbt-fidemo-runner..."
	docker compose --profile dev exec dbt-runner bash -c '\
		cd /workspace/fidemo && \
		dbt test --target dev --profiles-dir . \
		  --select bronze_scb_bulkfil_parquet dedup_reconciliation'

# Compile + execute the dbt_audit_helper row-level diffs between the two
# silver landings, and between the two SCD2 snapshots. Both should show
# perfect_match=true; any deviation indicates the Parquet- and DuckLake-path
# bronze variants have diverged.
dbt-container-diff-bronze-paths: dbt-container-up
	@echo "🔍 Diffing Parquet-path vs DuckLake-path via dbt_audit_helper..."
	docker compose --profile dev exec dbt-runner bash -c '\
		cd /workspace/fidemo && \
		dbt deps --profiles-dir . && \
		dbt compile --target sqlserver --profiles-dir . \
		  --select compare_silver_landings compare_scd2_snapshots && \
		for a in compare_silver_landings compare_scd2_snapshots; do \
		  echo ""; echo "=== $$a ==="; \
		  cat target/compiled/fidemo/analyses/$$a.sql | \
		  /opt/mssql-tools18/bin/sqlcmd -S mssql-dbt-duckdb \
		    -U fidemo_loader -P StrongPassword456! \
		    -d fidemo -C -h -1 -W; \
		done'

# ==========================================
# 🦆 SCB BULK-FILE SCD2 PIPELINE (medallion: raw → bronze[2] → silver SCD2)
# ==========================================
# Pipeline stages:
#   1. upload-minio         : uploads seedcsv/*.txt to MinIO in hive layout
#   2. build-bronze         : DuckDB reads MinIO, writes both bronze variants
#                             (Parquet + DuckLake) back to MinIO
#   3. load-scb-bulkfil     : DuckDB pushes both bronze → SQL Server landing tables
#                             (via the `mssql` community extension)
#   4. snapshot-scb-bulkfil : dbt snapshot maintains SCD2 history in SQL Server
#                             (one snapshot per bronze path)
#   5. run-scb-scd2         : orchestrates all of the above end-to-end

# MinIO creds — must match create_minio_hive.py defaults
MINIO_ACCESS_KEY ?= minioadmin
MINIO_SECRET_KEY ?= minioadminpassword
MINIO_ENDPOINT_HOSTPORT ?= localhost:9000

# SQL Server connection used by the `mssql` community extension from inside
# DuckDB. ADO.NET-style string (TrustServerCertificate is an alias for Encrypt
# in ADO.NET — docs: https://github.com/hugr-lab/mssql-extension).
MSSQL_DUCKDB_CONN ?= Server=localhost,1433;Database=fidemo;User Id=fidemo_loader;Password=StrongPassword456!;TrustServerCertificate=true

# Shared dbt env-var block for the DuckDB target
define DBT_DUCKDB_ENV
export MSSQL_USER='fidemo_loader' && \
export MSSQL_PWD='StrongPassword456!' && \
export MSSQL_DB='fidemo' && \
export MINIO_ACCESS_KEY='$(MINIO_ACCESS_KEY)' && \
export MINIO_SECRET_KEY='$(MINIO_SECRET_KEY)' && \
export MINIO_ENDPOINT_HOSTPORT='$(MINIO_ENDPOINT_HOSTPORT)' && \
export MSSQL_DUCKDB_CONN='$(MSSQL_DUCKDB_CONN)' && \
export REQUESTS_CA_BUNDLE=$(PWD)/$(COMBINED_CERT)
endef

upload-minio: setup-python
	@echo "📤 Uploading seedcsv/*.txt to MinIO under hive partitions..."
	@$(PYTHON) create_minio_hive.py

# NOTE: staging, both bronze variants, and both landing models must be built in a
# SINGLE `dbt run` so they share one DuckDB session — the DuckLake `ATTACH`
# done by the ducklake materialization must still be live when the downstream
# landing model references `ref('bronze_scb_bulkfil_ducklake')`.
build-bronze: setup-python setup-certs
	@echo "🧱 Building bronze layer only — Parquet + DuckLake variants..."
	$(DBT_DUCKDB_ENV) && \
	cd $(PROJECT_DIR) && \
	$(DBT) deps --profiles-dir . && \
	$(DBT) run --target dev --profiles-dir . \
	  --select stg_scb_bulkfil bronze_scb_bulkfil_parquet bronze_scb_bulkfil_ducklake

load-scb-bulkfil: setup-python setup-certs
	@echo "🦆 Building staging + bronze + SQL Server landing + dedup rejects in one DuckDB session..."
	$(DBT_DUCKDB_ENV) && \
	cd $(PROJECT_DIR) && \
	$(DBT) deps --profiles-dir . && \
	$(DBT) run --target dev --profiles-dir . \
	  --select stg_scb_bulkfil \
	           bronze_scb_bulkfil_parquet bronze_scb_bulkfil_ducklake \
	           scb_bulkfil_landing_from_parquet scb_bulkfil_landing_from_ducklake \
	           scb_bulkfil_dedup_rejects

# Run dbt tests against the v2 SCB pipeline. The bronze unique test is
# severity=warn (dupes are expected) and writes failing keys to
# <schema>_dbt_test__audit. The dedup_reconciliation singular test fails
# loudly if winners + rejects != bronze.
test-scb-bulkfil: setup-python setup-certs
	@echo "🧪 Running dbt tests for the SCB pipeline (DuckDB-side)..."
	$(DBT_DUCKDB_ENV) && \
	cd $(PROJECT_DIR) && \
	$(DBT) test --target dev --profiles-dir . \
	  --select bronze_scb_bulkfil_parquet dedup_reconciliation

snapshot-scb-bulkfil: setup-python setup-certs
	@echo "🧱 Applying SCD2 snapshots (both bronze paths) on SQL Server..."
	export MSSQL_USER='fidemo_loader' && \
	export MSSQL_PWD='StrongPassword456!' && \
	export MSSQL_DB='fidemo' && \
	export REQUESTS_CA_BUNDLE=$(PWD)/$(COMBINED_CERT) && \
	cd $(PROJECT_DIR) && \
	$(DBT) snapshot --target sqlserver --profiles-dir . \
	  --select snap_scb_bulkfil_scd2 snap_scb_bulkfil_scd2_from_ducklake

run-scb-scd2: compose-up setup-mssql-db migrate-db upload-minio load-scb-bulkfil snapshot-scb-bulkfil
	@echo "✅ SCB bulk-file SCD2 pipeline complete (both bronze paths)."

# ==========================================
# 🔍 CROSS-LAYER VERIFICATION (DuckDB reads raw + bronze + SQL Server)
# ==========================================
# One DuckDB session reaches all four storage layers via httpfs + mssql +
# ducklake extensions. Three reports:
#   --summary   : row counts per layer (health check)
#   --peorgnr   : full lineage for one entity across every layer
#   --integrity : problem checks — duplicates, multi-current, recon (exit 1 on fail)
# No flags = all three.

verify: setup-python
	$(DBT_DUCKDB_ENV) && $(PYTHON) scripts/verify_pipeline.py

verify-summary: setup-python
	$(DBT_DUCKDB_ENV) && $(PYTHON) scripts/verify_pipeline.py --summary

verify-integrity: setup-python
	$(DBT_DUCKDB_ENV) && $(PYTHON) scripts/verify_pipeline.py --integrity

# Launch harlequin with the rendered init SQL pre-loaded — interactive
# cross-layer TUI. Installs harlequin + harlequin-mssql if missing.
verify-shell: setup-python
	@$(PYTHON) -c "import harlequin" 2>/dev/null || \
		uv pip install --python $(PYTHON) --quiet harlequin harlequin-mssql
	@$(PYTHON) scripts/verify_pipeline.py --emit-init > /tmp/fidemo_harlequin_init.sql
	@echo "🐠 Launching harlequin with init SQL loaded (exit with Ctrl-C)..."
	@$(VENV)/bin/harlequin -f /tmp/fidemo_harlequin_init.sql

# Container-mode versions (same reports, but run inside dbt-runner so the
# compose service-name hostnames resolve).
dbt-container-verify: dbt-container-up
	docker compose --profile dev exec dbt-runner bash -c \
		'/opt/venv/bin/python /workspace/scripts/verify_pipeline.py'

dbt-container-verify-shell: dbt-container-up
	@docker compose --profile dev exec dbt-runner bash -c '\
		/opt/venv/bin/python -c "import harlequin" 2>/dev/null || \
			uv pip install --python /opt/venv/bin/python --quiet harlequin harlequin-mssql; \
		/opt/venv/bin/python /workspace/scripts/verify_pipeline.py --emit-init \
			> /tmp/fidemo_harlequin_init.sql; \
		/opt/venv/bin/harlequin -f /tmp/fidemo_harlequin_init.sql'

check-scb-scd2:
	@echo "🔎 Inspecting SCD2 tables (both bronze paths)..."
	@docker exec -it mssql-dbt-duckdb /opt/mssql-tools18/bin/sqlcmd \
		-S localhost -U fidemo_loader -P 'StrongPassword456!' \
		-d fidemo -C \
		-Q "SELECT 'parquet' AS src, peorgnr, foretagsnamn, effective_date, dbt_valid_from, dbt_valid_to FROM finance.snap_scb_bulkfil_scd2 UNION ALL SELECT 'ducklake', peorgnr, foretagsnamn, effective_date, dbt_valid_from, dbt_valid_to FROM finance.snap_scb_bulkfil_scd2_from_ducklake ORDER BY peorgnr, src, dbt_valid_from;"

# Safety valve — drop the silver-layer SQL Server tables and wipe the
# bronze prefix in MinIO. Useful when an earlier MERGE crash has left
# the snapshot with multiple `dbt_valid_to IS NULL` rows per peorgnr
# (cardinality-8672 error), or when swapping source data en masse
# (anonymization, new seed file) makes a clean rebuild simpler than
# reasoning about deltas. Does NOT touch the `fidemo` database itself
# or the Flyway migration history — only the pipeline output tables.
clean-pipeline-state:
	@echo "🧨 Dropping SQL Server silver tables..."
	@docker exec mssql-dbt-duckdb /opt/mssql-tools18/bin/sqlcmd \
		-S localhost -U fidemo_loader -P 'StrongPassword456!' \
		-d fidemo -C -Q "\
DROP TABLE IF EXISTS finance.snap_scb_bulkfil_scd2;\
DROP TABLE IF EXISTS finance.snap_scb_bulkfil_scd2_from_ducklake;\
DROP TABLE IF EXISTS finance.scb_bulkfil_landing_from_parquet;\
DROP TABLE IF EXISTS finance.scb_bulkfil_landing_from_ducklake;\
DROP TABLE IF EXISTS finance.scb_bulkfil_dedup_rejects;"
	@echo "🧨 Clearing bronze MinIO prefixes..."
	@docker exec minio-dbt-duckdb sh -lc \
		'mc alias set local http://localhost:9000 minioadmin minioadminpassword 2>/dev/null || true; \
		 mc rm --recursive --force local/informat/bronze-parquet/ 2>/dev/null || true; \
		 mc rm --recursive --force local/informat/bronze-ducklake/ 2>/dev/null || true'
	@echo "🧨 Dropping local DuckDB + DuckLake catalog..."
	@rm -f $(DB_FILE) $(PROJECT_DIR)/ducklake_catalog.sqlite
	@echo "✅ Pipeline state reset. Run make run-scb-scd2 or make dbt-container-run-scb-scd2 to rebuild."

# --- Cleanup ---

# ==========================================
# 🧹 CLEANUP & RESET
# ==========================================
# (cleanup targets are already declared in the top-level .PHONY block)

# 1. Flyway Cleanup
clean-flyway:
	@echo "🦅 Tar bort Flyway..."
	@rm -rf $(FLYWAY_DIR)
	@rm -f flyway.tar.gz

# 2. dbt Cleanup
clean-dbt:
	@echo "🧹 Rensar dbt-artefakter..."
	@rm -rf $(PROJECT_DIR)/target
	@rm -rf $(PROJECT_DIR)/dbt_packages
	@rm -rf $(PROJECT_DIR)/logs

# 3. MSSQL + MinIO Container Cleanup (via docker compose)
clean-mssql:
	@echo "🐳 Stoppar och tar bort containers (MSSQL + MinIO) via docker compose..."
	@docker compose down 2>/dev/null || true

# 4. Python/Venv Cleanup
clean-venv:
	@echo "🐍 Tar bort virtual environment..."
	@rm -rf $(VENV)

# 5. Cert Cleanup
clean-certs:
	@echo "📜 Tar bort genererade certifikat..."
	@rm -f $(COMBINED_CERT)

# 6. Database File Cleanup (DuckDB + DuckLake catalog)
clean-duckdb:
	@echo "🦆 Tar bort lokal DuckDB-fil + DuckLake-katalog..."
	@rm -f $(DB_FILE)
	@rm -f $(PROJECT_DIR)/ducklake_catalog.sqlite

# --- SAMLADE KOMMANDON ---

# 'make clean' 
# Tar bort tillfälliga filer och bygg-artefakter (Flyway, dbt), men sparar miljö (venv, container).
clean: clean-dbt clean-flyway
	@echo "✨ Byggfiler städade."

# 'make nuke'
# VARNING: Tar bort ALLT. Container, data, volymer, venv, certifikat. Återställer till noll.
nuke: clean clean-venv clean-certs clean-duckdb
	@echo "🐳 Stoppar och tar bort containers OCH volymer (MSSQL + MinIO)..."
	@docker compose down -v 2>/dev/null || true
	@echo "💥 Total återställning klar. Kör 'make init-db' för att börja om."

