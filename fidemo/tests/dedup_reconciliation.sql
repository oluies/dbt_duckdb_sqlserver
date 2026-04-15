{# Singular test — bronze rows must equal winners + rejects.

   Computes both counts from bronze itself (so the test is self-contained
   and doesn't have to cross from DuckDB into the SQL-Server-side rejects
   table). Catches breakage if anyone changes the dedup column or the
   row_number() ordering in the landing model without updating the rejects
   model in lockstep.

   Singular tests fail when they return any rows; on success returns 0 rows.
#}

with ranked as (
    select
        peorgnr,
        row_number() over (
            partition by peorgnr
            order by effective_date desc
        ) as rn
    from {{ ref('bronze_scb_bulkfil_parquet') }}
),
counts as (
    select
        count(*)                                  as bronze_n,
        sum(case when rn = 1 then 1 else 0 end)   as winners_n,
        sum(case when rn > 1 then 1 else 0 end)   as rejects_n
    from ranked
)
select
    bronze_n,
    winners_n,
    rejects_n,
    bronze_n - (winners_n + rejects_n) as missing_rows
from counts
where bronze_n != winners_n + rejects_n
