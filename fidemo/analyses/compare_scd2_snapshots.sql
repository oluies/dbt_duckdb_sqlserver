{# Row-level diff between the two SCD2 snapshot tables.

   If the upstream silver landings are identical (see
   compare_silver_landings.sql), these two snapshots must also be identical.
   Compares only the business-meaningful columns; dbt-internal columns
   (dbt_scd_id differs because it's a per-snapshot hash, dbt_updated_at
   and the _dbt_valid_* can differ by microseconds between the two
   snapshot runs) are excluded.

   Same run/inspection pattern as compare_silver_landings.sql.
#}

{{ audit_helper.compare_relations(
    a_relation = api.Relation.create(
        database='fidemo', schema='finance',
        identifier='snap_scb_bulkfil_scd2'),
    b_relation = api.Relation.create(
        database='fidemo', schema='finance',
        identifier='snap_scb_bulkfil_scd2_from_ducklake'),
    exclude_columns = [
        'dbt_scd_id',
        'dbt_updated_at',
        'dbt_valid_from',
        'dbt_valid_to',
        'last_updated_dt',
        'invocation_id',
        'source_file'
    ],
    primary_key = 'peorgnr'
) }}
