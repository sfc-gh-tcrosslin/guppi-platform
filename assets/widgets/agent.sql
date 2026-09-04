-- WIDGET W-7  class=agent  home=@GUPPI_LIB.LIB.WIDGET_FILES/agent.sql
-- Purpose: create an agent wiring the semantic view (analyst/text-to-sql) and the search
--          service into one conversational entry point.
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_AGENT recipe.
-- TOKENS: <PREFIX> proc prefix; <AGENT> agent name; <SV> semantic view; <SEARCH_SVC> search service.
--   Instructions/sample_questions below are the reference (DICOM) shape -- adapt to your domain.
--   Warehouse + FQNs resolve from CURRENT_WAREHOUSE()/CURRENT_DATABASE()/CURRENT_SCHEMA().
-- EXIT GATE: agent answers one aggregation question and one free-text lookup.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_AGENT()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Build recipe: idempotently builds an agent tying the Analyst semantic view + Cortex Search into one entry point. Metadata only.'
EXECUTE AS OWNER
AS
$$
DECLARE
  fq STRING;
  wh STRING;
  spec STRING;
  ddl STRING;
BEGIN
  fq := CURRENT_DATABASE() || '.' || CURRENT_SCHEMA();
  wh := CURRENT_WAREHOUSE();
  spec := '{"models": {"orchestration": "auto"}, "instructions": {"response": "You answer questions about a metadata catalog. Metadata only. Give counts and breakdowns with specific numbers.", "orchestration": "Use the Analyst tool for counts and aggregations. Use the Search tool for free-text lookup.", "sample_questions": [{"question": "How many records by category?"}, {"question": "Find records matching a term."}]}, "tools": [{"tool_spec": {"type": "cortex_analyst_text_to_sql", "name": "CATALOG_ANALYST", "description": "Structured queries over the catalog."}}, {"tool_spec": {"type": "cortex_search", "name": "CATALOG_SEARCH_TOOL", "description": "Free-text search over the catalog."}}], "tool_resources": {"CATALOG_ANALYST": {"execution_environment": {"type": "warehouse", "warehouse": "' || :wh || '"}, "semantic_view": "' || :fq || '.<SV>"}, "CATALOG_SEARCH_TOOL": {"name": "' || :fq || '.<SEARCH_SVC>", "id_column": "STUDY_UID", "title_column": "MODALITY", "max_results": 5}}}';
  ddl := 'CREATE OR REPLACE AGENT <AGENT> WITH PROFILE=''{"display_name":"Catalog Agent"}'' COMMENT=''builder-built agent over the metadata catalog (Analyst + Search).'' FROM SPECIFICATION ''' || :spec || '''';
  EXECUTE IMMEDIATE :ddl;
  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'agent', :fq || '.<AGENT>', 'built_by', CURRENT_ROLE());
END
$$;
