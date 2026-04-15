{# Row-level diff between the two silver landing tables in SQL Server.

   Both are fed from the same staging view via two different bronze
   substrates (hive Parquet vs DuckLake). They should be bit-identical.

   How to run (from inside the container):

       cd /workspace/fidemo
       dbt deps --profiles-dir .
       dbt compile --target sqlserver --profiles-dir . \
         --select analyses.compare_silver_landings
       cat target/compiled/fidemo/analyses/compare_silver_landings.sql | \
         sqlcmd -S mssql-dbt-duckdb -U fidemo_loader -P 'StrongPassword456!' \
                -d fidemo -C

   Or compile and inspect interactively via `dbt show`:

       dbt show --target sqlserver --profiles-dir . \
         --select analyses.compare_silver_landings

   Expected output: `perfect_match = true` for every column; row counts
   matching; zero rows in a_only / b_only. Any deviation = the two bronze
   paths are producing divergent silver state and something is wrong.
#}

{{ audit_helper.compare_relations(
    a_relation = source('finance_landing', 'scb_bulkfil_landing_from_parquet'),
    b_relation = source('finance_landing', 'scb_bulkfil_landing_from_ducklake'),
    exclude_columns = ['last_updated_dt', 'invocation_id', 'source_file'],
    primary_key = 'peorgnr'
) }}
