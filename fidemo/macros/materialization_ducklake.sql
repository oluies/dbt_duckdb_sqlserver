{#
    ducklake materialization — writes a DuckDB query result into a DuckLake
    lakehouse (SQLite catalog + Parquet data in S3/MinIO).

    Docs: https://ducklake.select/docs/stable/duckdb/usage/connecting
          https://ducklake.select/docs/stable/duckdb/usage/choosing_a_catalog_database#sqlite

    Model config:
        {{ config(
            materialized='ducklake',
            lake_alias='lake',                              -- optional, default 'lake'
            lake_schema='bronze',                           -- DuckLake schema (default 'main')
            strategy='replace'                              -- 'replace' | 'truncate' | 'append'
        ) }}

    Catalog path + data path are taken from dbt vars:
        bronze_ducklake_catalog_path  (SQLite file, relative to project dir)
        bronze_ducklake_data_path     (S3 URI)
#}

{% materialization ducklake, adapter='duckdb' %}

    {%- set lake_alias = config.get('lake_alias', 'lake') -%}
    {%- set lake_schema = config.get('lake_schema', 'bronze') -%}
    {%- set target_table = model['alias'] or model['name'] -%}
    {%- set strategy = config.get('strategy', 'replace') -%}

    {%- set catalog_path = var('bronze_ducklake_catalog_path') -%}
    {%- set data_path = var('bronze_ducklake_data_path') -%}

    {%- set fqn = lake_alias ~ '.' ~ lake_schema ~ '.' ~ target_table -%}

    {# Make sure both halves of DuckLake are loadable. INSTALL is idempotent. #}
    {% do run_query("INSTALL ducklake") %}
    {% do run_query("INSTALL sqlite") %}
    {% do run_query("LOAD ducklake") %}
    {% do run_query("LOAD sqlite") %}

    {# ATTACH the lake. CREATE_IF_NOT_EXISTS (default true) means the SQLite
       catalog file + bucket prefix get bootstrapped on first run.
       AUTOMATIC_MIGRATION true makes the DuckLake extension upgrade an
       older catalog format on the fly — needed when a catalog written by
       e.g. DuckDB 1.4.x (DuckLake v0.3) is opened by DuckDB 1.5.x
       (DuckLake v0.4). #}
    {% do run_query(
        "ATTACH IF NOT EXISTS 'ducklake:sqlite:" ~ catalog_path ~
        "' AS " ~ lake_alias ~
        " (DATA_PATH '" ~ data_path ~ "', AUTOMATIC_MIGRATION true)"
    ) %}

    {# Ensure the schema exists inside the lake. #}
    {% do run_query("CREATE SCHEMA IF NOT EXISTS " ~ lake_alias ~ "." ~ lake_schema) %}

    {%- if strategy == 'replace' -%}
        {% call statement('main') -%}
            CREATE OR REPLACE TABLE {{ fqn }} AS
            SELECT * FROM (
                {{ sql }}
            ) _q
        {%- endcall %}
    {%- elif strategy == 'truncate' -%}
        {% do run_query("DELETE FROM " ~ fqn) %}
        {% call statement('main') -%}
            INSERT INTO {{ fqn }}
            SELECT * FROM (
                {{ sql }}
            ) _q
        {%- endcall %}
    {%- elif strategy == 'append' -%}
        {% call statement('main') -%}
            INSERT INTO {{ fqn }}
            SELECT * FROM (
                {{ sql }}
            ) _q
        {%- endcall %}
    {%- else -%}
        {% do exceptions.raise_compiler_error(
            "ducklake: unknown strategy '" ~ strategy ~
            "'. Expected 'replace', 'truncate', or 'append'."
        ) %}
    {%- endif %}

    {% set target_relation = api.Relation.create(
        database=lake_alias,
        schema=lake_schema,
        identifier=target_table,
        type='table'
    ) %}

    {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}
