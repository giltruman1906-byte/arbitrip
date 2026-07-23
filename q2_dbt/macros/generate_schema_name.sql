{#
  Standard override so custom +schema values resolve to LITERAL dataset names
  (`raw`, `analytics`) instead of dbt's default `<target_schema>_<custom>` concatenation.
  Keeps seeds in `raw` and models in `analytics`, matching sources.yml and the assignment's
  "raw tables in BigQuery" framing. Falls back to the target schema when none is set.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
