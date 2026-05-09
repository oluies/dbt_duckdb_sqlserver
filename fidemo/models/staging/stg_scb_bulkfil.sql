{{ config(materialized='view', schema='staging') }}

-- Reads the hive-partitioned SCB bulk file from MinIO, casts to lowercase
-- columns, and exposes the file's delivery date (from the hive partition)
-- as effective_date for the SCD2 snapshot.
--
-- Note: every source column is referenced as `src.<MixedCase>` because
-- DuckDB's identifier resolution is case-insensitive, so without the
-- qualifier `cast(PeOrgNr as varchar) as peorgnr` trips the
-- "referenced before defined" binder error.

WITH src AS (
    SELECT * FROM {{ source('minio', 'raw_scb_bulkfil') }}
)
SELECT
    cast(src.peorgnr AS varchar) AS peorgnr,
    cast(src.foretagsnamn AS varchar) AS foretagsnamn,
    cast(src.coadress AS varchar) AS coadress,
    cast(src.gatuadress AS varchar) AS gatuadress,
    cast(src.postnr AS varchar) AS postnr,
    cast(src.postort AS varchar) AS postort,
    cast(src.jurform AS varchar) AS jurform,
    cast(src.ftgstat AS varchar) AS ftgstat,
    cast(src.jestat AS varchar) AS jestat,
    cast(src.namn AS varchar) AS namn,
    cast(src.ng1 AS varchar) AS ng1,
    cast(src.ng2 AS varchar) AS ng2,
    cast(src.ng3 AS varchar) AS ng3,
    cast(src.ng4 AS varchar) AS ng4,
    cast(src.ng5 AS varchar) AS ng5,
    cast(src.regdatktid AS varchar) AS regdatktid,
    cast(src.reklamsparrtyp AS varchar) AS reklamsparrtyp,
    cast(src.forandrtyp AS varchar) AS forandrtyp,
    make_date(cast(src.year AS int), cast(src.month AS int), cast(src.day AS int)) AS effective_date,
    src.source_file,
    get_current_timestamp() AS last_updated_dt,
    '{{ invocation_id }}' AS invocation_id
FROM src
