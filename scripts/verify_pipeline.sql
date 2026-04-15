-- verify_pipeline.sql — queries that cross-check data across every layer.
--
-- Assumes the extensions + ATTACHes from scripts/duckdb_init.sql are already
-- loaded. The Python wrapper handles that; for manual use:
--
--   python scripts/verify_pipeline.py --emit-init > /tmp/init.sql
--   duckdb -init /tmp/init.sql < scripts/verify_pipeline.sql
--
-- Three reports, each wrapped in >>>REPORT-n-BEGIN / END markers so the
-- Python wrapper can pluck them out cleanly:
--   1. Per-layer row count summary
--   2. Per-peorgnr version history (replace ${TARGET_PEORGNR} first)
--   3. Integrity checks


-- >>>REPORT-1-BEGIN
SELECT 'raw                                '                      AS layer,
       COUNT(*)                                                    AS rows
FROM read_csv('s3://informat/seedcsv/year=*/month=*/day=*/scb_bulkfil_JE_*.txt',
              delim='\t', header=true, encoding='latin-1',
              hive_partitioning=true, all_varchar=true)
UNION ALL
SELECT 'bronze-parquet (hive)              ',
       COUNT(*) FROM read_parquet(
       's3://informat/bronze-parquet/scb_bulkfil/*/*/*/*.parquet',
       hive_partitioning=true)
UNION ALL
SELECT 'bronze-ducklake                    ',
       COUNT(*) FROM lake.bronze.bronze_scb_bulkfil_ducklake
UNION ALL
SELECT 'silver landing (from Parquet)      ',
       COUNT(*) FROM ms.finance.scb_bulkfil_landing_from_parquet
UNION ALL
SELECT 'silver landing (from DuckLake)     ',
       COUNT(*) FROM ms.finance.scb_bulkfil_landing_from_ducklake
UNION ALL
SELECT 'silver rejects                     ',
       COUNT(*) FROM ms.finance.scb_bulkfil_dedup_rejects
UNION ALL
SELECT 'SCD2 (Parquet path) — total        ',
       COUNT(*) FROM ms.finance.snap_scb_bulkfil_scd2
UNION ALL
SELECT 'SCD2 (Parquet path) — current only ',
       COUNT(*) FROM ms.finance.snap_scb_bulkfil_scd2 WHERE dbt_valid_to IS NULL
UNION ALL
SELECT 'SCD2 (DuckLake path) — total       ',
       COUNT(*) FROM ms.finance.snap_scb_bulkfil_scd2_from_ducklake
UNION ALL
SELECT 'SCD2 (DuckLake path) — current only',
       COUNT(*) FROM ms.finance.snap_scb_bulkfil_scd2_from_ducklake WHERE dbt_valid_to IS NULL
ORDER BY layer
-- >>>REPORT-1-END


-- >>>REPORT-2-BEGIN
WITH target(p) AS (VALUES ('${TARGET_PEORGNR}')),
raw_rows AS (
    SELECT 'raw                   '    AS layer,
           PeOrgNr                      AS peorgnr,
           Namn                         AS namn,
           make_date(cast(year as int), cast(month as int), cast(day as int)) AS effective_date,
           NULL::VARCHAR                AS extra
    FROM read_csv('s3://informat/seedcsv/year=*/month=*/day=*/scb_bulkfil_JE_*.txt',
                  delim='\t', header=true, encoding='latin-1',
                  hive_partitioning=true, all_varchar=true)
),
bronze_pq AS (
    SELECT 'bronze-parquet        ', peorgnr, namn, effective_date, NULL::VARCHAR
    FROM read_parquet('s3://informat/bronze-parquet/scb_bulkfil/*/*/*/*.parquet',
                      hive_partitioning=true)
),
bronze_dl AS (
    SELECT 'bronze-ducklake       ', peorgnr, namn, effective_date, NULL::VARCHAR
    FROM lake.bronze.bronze_scb_bulkfil_ducklake
),
landing_pq AS (
    SELECT 'landing (from Parquet)', peorgnr, namn, effective_date, NULL::VARCHAR
    FROM ms.finance.scb_bulkfil_landing_from_parquet
),
landing_dl AS (
    SELECT 'landing (from DuckLake)', peorgnr, namn, effective_date, NULL::VARCHAR
    FROM ms.finance.scb_bulkfil_landing_from_ducklake
),
rejects AS (
    SELECT 'rejects (rank=' || cast(_dedup_rank as varchar) || ')',
           peorgnr, namn, effective_date, NULL::VARCHAR
    FROM ms.finance.scb_bulkfil_dedup_rejects
),
scd2_pq AS (
    SELECT 'SCD2 Parquet          ', peorgnr, namn, effective_date,
           'valid_from=' || dbt_valid_from::VARCHAR
             || '  valid_to=' || COALESCE(dbt_valid_to::VARCHAR, '(current)')
    FROM ms.finance.snap_scb_bulkfil_scd2
),
scd2_dl AS (
    SELECT 'SCD2 DuckLake         ', peorgnr, namn, effective_date,
           'valid_from=' || dbt_valid_from::VARCHAR
             || '  valid_to=' || COALESCE(dbt_valid_to::VARCHAR, '(current)')
    FROM ms.finance.snap_scb_bulkfil_scd2_from_ducklake
)
SELECT * FROM (
    SELECT * FROM raw_rows
    UNION ALL SELECT * FROM bronze_pq
    UNION ALL SELECT * FROM bronze_dl
    UNION ALL SELECT * FROM landing_pq
    UNION ALL SELECT * FROM landing_dl
    UNION ALL SELECT * FROM rejects
    UNION ALL SELECT * FROM scd2_pq
    UNION ALL SELECT * FROM scd2_dl
) q
WHERE peorgnr = (SELECT p FROM target)
ORDER BY layer, effective_date
-- >>>REPORT-2-END


-- >>>REPORT-3-BEGIN
WITH
landing_dups AS (
    SELECT 'landing-from-parquet has duplicate peorgnr' AS problem,
           peorgnr, COUNT(*) AS n
    FROM ms.finance.scb_bulkfil_landing_from_parquet
    GROUP BY peorgnr HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'landing-from-ducklake has duplicate peorgnr',
           peorgnr, COUNT(*)
    FROM ms.finance.scb_bulkfil_landing_from_ducklake
    GROUP BY peorgnr HAVING COUNT(*) > 1
),
scd2_multi_current AS (
    SELECT 'SCD2 Parquet has >1 current row per peorgnr' AS problem,
           peorgnr, COUNT(*) AS n
    FROM ms.finance.snap_scb_bulkfil_scd2
    WHERE dbt_valid_to IS NULL
    GROUP BY peorgnr HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'SCD2 DuckLake has >1 current row per peorgnr',
           peorgnr, COUNT(*)
    FROM ms.finance.snap_scb_bulkfil_scd2_from_ducklake
    WHERE dbt_valid_to IS NULL
    GROUP BY peorgnr HAVING COUNT(*) > 1
),
recon AS (
    SELECT
        (SELECT COUNT(*) FROM read_parquet(
            's3://informat/bronze-parquet/scb_bulkfil/*/*/*/*.parquet',
            hive_partitioning=true)) AS bronze_n,
        (SELECT COUNT(*) FROM ms.finance.scb_bulkfil_landing_from_parquet) AS winners_n,
        (SELECT COUNT(*) FROM ms.finance.scb_bulkfil_dedup_rejects)        AS rejects_n
)
SELECT problem, peorgnr, n FROM landing_dups
UNION ALL
SELECT problem, peorgnr, n FROM scd2_multi_current
UNION ALL
SELECT
    'bronze != winners + rejects  (bronze_n=' || bronze_n::VARCHAR
      || ' winners_n=' || winners_n::VARCHAR
      || ' rejects_n=' || rejects_n::VARCHAR || ')' AS problem,
    NULL::VARCHAR AS peorgnr,
    bronze_n - (winners_n + rejects_n) AS n
FROM recon WHERE bronze_n != winners_n + rejects_n
-- >>>REPORT-3-END
