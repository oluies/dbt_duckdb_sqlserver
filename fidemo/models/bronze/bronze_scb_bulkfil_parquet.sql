{# Bronze variant 1: hive-partitioned Parquet in MinIO.

   Output layout:
     s3://informat/bronze-parquet/scb_bulkfil/
       year=YYYY/month=MM/day=DD/data_*.parquet

   This is the simplest, catalog-less bronze. Compare with
   bronze_scb_bulkfil_ducklake for the DuckLake variant.
#}

{# `overwrite: true` is semantically cleaner than `overwrite_or_ignore: true`
   — it explicitly replaces partition contents each run, instead of "write
   alongside existing files; don't error". In single-writer practice the
   two are equivalent (DuckDB picks deterministic filename `data_<tid>.parquet`),
   but OVERWRITE correctly signals intent and survives multi-thread writes.
#}

{{ config(
    materialized='external',
    location=(var('bronze_parquet_path') ~ '/scb_bulkfil'),
    format='parquet',
    options={
        'partition_by': 'year, month, day',
        'overwrite': true
    }
) }}

select
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
    -- partition keys at the end so COPY ... PARTITION_BY can pick them up
    cast(date_part('year',  effective_date) as int) as year,
    cast(date_part('month', effective_date) as int) as month,
    cast(date_part('day',   effective_date) as int) as day
from {{ ref('stg_scb_bulkfil') }}
