{# Silver landing — sourced from the DuckLake bronze variant.

   Target: fidemo.finance.scb_bulkfil_landing_from_ducklake
   Push mechanism: `mssql` community extension (see mssql_native materialization).

   NOTE on the FROM clause:
   dbt's default ref() resolution would point at  my_db.main_bronze.<name>,
   but the ducklake materialization actually writes the table to
   lake.bronze.<name> (an attached DuckLake catalog). The attach only happens
   mid-run inside the upstream materialization, so declaring database='lake'
   in the upstream config triggers dbt's pre-run relation checks against a
   catalog that doesn't exist yet.

   Workaround: hardcode the DuckLake FQN and declare the dbt DAG dependency
   via the `-- depends_on:` comment, which the manifest parser honours.
#}

{{ config(
    materialized='mssql_native',
    target_mssql_schema='finance',
    strategy='replace'
) }}

-- Deduplicate to one row per peorgnr (latest effective_date wins).
-- Same rationale as scb_bulkfil_landing_from_parquet: SCD2's MERGE
-- requires one source row per unique_key. QUALIFY runs in DuckDB.
-- depends_on: {{ ref('bronze_scb_bulkfil_ducklake') }}
SELECT * FROM lake.bronze.bronze_scb_bulkfil_ducklake
QUALIFY row_number() OVER (PARTITION BY peorgnr ORDER BY effective_date DESC) = 1
