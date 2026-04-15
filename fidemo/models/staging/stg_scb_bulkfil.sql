{{ config(materialized='view', schema='staging') }}

-- Reads the hive-partitioned SCB bulk file from MinIO, casts to lowercase
-- columns, and exposes the file's delivery date (from the hive partition)
-- as effective_date for the SCD2 snapshot.
--
-- Note: every source column is referenced as `src.<MixedCase>` because
-- DuckDB's identifier resolution is case-insensitive, so without the
-- qualifier `cast(PeOrgNr as varchar) as peorgnr` trips the
-- "referenced before defined" binder error.

with src as (
    select * from {{ source('minio', 'raw_scb_bulkfil') }}
)
select
    cast(src.PeOrgNr        as varchar) as peorgnr,
    cast(src.Foretagsnamn   as varchar) as foretagsnamn,
    cast(src.COAdress       as varchar) as coadress,
    cast(src.Gatuadress     as varchar) as gatuadress,
    cast(src.PostNr         as varchar) as postnr,
    cast(src.PostOrt        as varchar) as postort,
    cast(src.JurForm        as varchar) as jurform,
    cast(src.FtgStat        as varchar) as ftgstat,
    cast(src.JEStat         as varchar) as jestat,
    cast(src.Namn           as varchar) as namn,
    cast(src.Ng1            as varchar) as ng1,
    cast(src.Ng2            as varchar) as ng2,
    cast(src.Ng3            as varchar) as ng3,
    cast(src.Ng4            as varchar) as ng4,
    cast(src.Ng5            as varchar) as ng5,
    cast(src.RegDatKtid     as varchar) as regdatktid,
    cast(src.Reklamsparrtyp as varchar) as reklamsparrtyp,
    cast(src.ForAndrTyp     as varchar) as forandrtyp,
    make_date(cast(src.year as int), cast(src.month as int), cast(src.day as int)) as effective_date,
    src.source_file,
    get_current_timestamp() as last_updated_dt,
    '{{ invocation_id }}' as invocation_id
from src
