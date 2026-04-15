{# Bronze variant 2: DuckLake (SQLite catalog + Parquet data in MinIO).

   Catalog:  fidemo/ducklake_catalog.sqlite   (see dbt_project.yml vars)
   Data:     s3://informat/bronze-ducklake/   (hive layout managed by DuckLake)

   Compare with bronze_scb_bulkfil_parquet (plain hive Parquet).
#}

{{ config(
    materialized='ducklake',
    lake_alias='lake',
    lake_schema='bronze',
    strategy='replace'
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
    invocation_id
from {{ ref('stg_scb_bulkfil') }}
