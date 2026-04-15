{#
    Sibling SCD2 snapshot — fed by the DuckLake bronze variant.
    Demonstrates that SCD2 mechanics are identical regardless of bronze format;
    the only difference is which lake path the landing table was sourced from.
#}

{% snapshot snap_scb_bulkfil_scd2_from_ducklake %}

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

select * from {{ source('finance_landing', 'scb_bulkfil_landing_from_ducklake') }}

{% endsnapshot %}
