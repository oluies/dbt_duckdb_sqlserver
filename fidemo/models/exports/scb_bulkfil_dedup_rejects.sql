{# Dedup-rejects model — sister to the silver landing.

   For each peorgnr, the row with the LATEST effective_date wins and lands
   in `scb_bulkfil_landing_from_parquet`; every OTHER row for that peorgnr
   ends up here. Together (winners + rejects) reconstruct bronze exactly,
   verified by tests/dedup_reconciliation.sql.

   Why a real table (not just a dbt test failure)?
   - Lineage / dbt-docs visibility
   - Queryable in BI tools alongside SCD2
   - Carries `_dedup_rank` so analysts can answer "this peorgnr has been
     in N deliveries; here are the older N-1 versions"

   The dedup choice (latest effective_date wins) is a silver-layer policy
   decision; bronze stays unaltered.
#}

{{ config(
    materialized='mssql_native',
    target_mssql_schema='finance',
    strategy='replace'
) }}

WITH ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY peorgnr
            ORDER BY effective_date DESC
        ) AS _dedup_rank
    FROM {{ ref('bronze_scb_bulkfil_parquet') }}
)
SELECT
    peorgnr,
    foretagsnamn,
    coadress,
    gatuadress,
    postnr,
    postort,
    jurform,
    ftgstat,
    jestat,
    namn,
    ng1,
    ng2,
    ng3,
    ng4,
    ng5,
    regdatktid,
    reklamsparrtyp,
    forandrtyp,
    effective_date,
    source_file,
    last_updated_dt,
    invocation_id,
    _dedup_rank   -- 2 = second-latest delivery, 3 = third-latest, ...
FROM ranked
WHERE _dedup_rank > 1
