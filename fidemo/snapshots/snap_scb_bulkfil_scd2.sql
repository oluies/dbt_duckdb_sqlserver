{#
    Primary SCD2 snapshot — fed by the Parquet bronze variant.
    A sibling snapshot (snap_scb_bulkfil_scd2_from_ducklake) feeds from DuckLake
    so the two paths can be compared apples-to-apples in SQL Server.
#}

{% snapshot snap_scb_bulkfil_scd2 %}

{{ config(
    target_schema='finance',
    unique_key='peorgnr',
    strategy='check',
    check_cols=[
        'foretagsnamn',
        'coadress',
        'gatuadress',
        'postnr',
        'postort',
        'jurform',
        'ftgstat',
        'jestat',
        'namn',
        'ng1',
        'ng2',
        'ng3',
        'ng4',
        'ng5',
        'regdatktid',
        'reklamsparrtyp',
        'forandrtyp'
    ],
    invalidate_hard_deletes=false
) }}

select * from {{ source('finance_landing', 'scb_bulkfil_landing_from_parquet') }}

{% endsnapshot %}
