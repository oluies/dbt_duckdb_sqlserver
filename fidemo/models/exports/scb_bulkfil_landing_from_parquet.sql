{# Silver landing — sourced from the hive-Parquet bronze variant.

   Target: fidemo.finance.scb_bulkfil_landing_from_parquet
   Push mechanism: `mssql` community extension (see mssql_native materialization).
#}

{{ config(
    materialized='mssql_native',
    target_mssql_schema='finance',
    strategy='replace'
) }}

-- Deduplicate to one row per peorgnr (latest effective_date wins).
-- Required by the downstream SCD2 snapshot — its MERGE statement on
-- SQL Server demands at most one source row per unique_key, otherwise it
-- errors with "MERGE attempted to UPDATE/DELETE the same row more than once".
-- QUALIFY is DuckDB syntax; this SELECT is compiled and executed by DuckDB
-- before the result is pushed to SQL Server via the mssql_native materialization.
select * from {{ ref('bronze_scb_bulkfil_parquet') }}
qualify row_number() over (partition by peorgnr order by effective_date desc) = 1
