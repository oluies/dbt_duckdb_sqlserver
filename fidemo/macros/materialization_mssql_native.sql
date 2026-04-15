{#
    mssql_native materialization — pushes a DuckDB query result into SQL Server
    using the `mssql` community DuckDB extension (native TDS, no pyodbc/SQLAlchemy).

    Docs: https://duckdb.org/community_extensions/extensions/mssql
          https://github.com/hugr-lab/mssql-extension

    Model config:
        {{ config(
            materialized='mssql_native',
            target_mssql_schema='finance',   -- default from dbt_project.yml
            strategy='replace',              -- 'replace' | 'truncate' | 'append'
            mssql_attach_alias='ms'          -- optional, default 'ms'
        ) }}

    Requires env var MSSQL_DUCKDB_CONN to be set to an ADO.NET connection string,
    e.g. "Server=localhost,1433;Database=fidemo;User Id=sa;Password=...;Encrypt=true;TrustServerCertificate=true"
#}

{% materialization mssql_native, adapter='duckdb' %}

    {%- set attach_alias = config.get('mssql_attach_alias', 'ms') -%}
    {%- set target_schema = config.get('target_mssql_schema', 'finance') -%}
    {%- set target_table = model['alias'] or model['name'] -%}
    {%- set strategy = config.get('strategy', 'replace') -%}
    {%- set conn = env_var('MSSQL_DUCKDB_CONN') -%}

    {%- set fqn = attach_alias ~ '.' ~ target_schema ~ '.' ~ target_table -%}

    {# Ensure the community extension is present and loaded. #}
    {% do run_query("INSTALL mssql FROM community") %}
    {% do run_query("LOAD mssql") %}

    {# ATTACH the SQL Server database. `ATTACH IF NOT EXISTS` is idempotent
       across runs within the same DuckDB session; across sessions DuckDB
       detaches automatically. #}
    {% do run_query(
        "ATTACH IF NOT EXISTS '" ~ conn ~ "' AS " ~ attach_alias ~ " (TYPE mssql)"
    ) %}

    {# Execute the push. Use `main` so dbt treats it as the result statement. #}
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
            "mssql_native: unknown strategy '" ~ strategy ~
            "'. Expected 'replace', 'truncate', or 'append'."
        ) %}
    {%- endif %}

    {# Return a virtual relation so dbt's graph accounting stays happy.
       The database/schema here are the DuckDB-side ATTACH alias and
       the SQL Server schema, not DuckDB's own. #}
    {% set target_relation = api.Relation.create(
        database=attach_alias,
        schema=target_schema,
        identifier=target_table,
        type='table'
    ) %}

    {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}
