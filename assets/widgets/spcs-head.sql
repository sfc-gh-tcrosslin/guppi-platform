-- WIDGET W-9  class=spcs-head  home=@GUPPI_LIB.LIB.WIDGET_FILES/spcs-head.sql
-- Purpose: provision the owner-scoped SPCS scaffolding (image repository) for a service and RETURN
--          the human handoff for the deferred docker push + ready compute-pool + service DDL.
--          Demonstrates the autonomy boundary: build to the docker edge, report the human step.
-- Source: generalized from the proven dicom-vna-companion DICOM_BUILD_SPCS_HEAD recipe.
-- TOKENS: <PREFIX> proc prefix; <REPO> image repository name; <IMAGE> image name:tag (e.g. orthanc:latest);
--   <POOL> compute pool name; <PORT> service port; <ENDPOINT> endpoint name. Paths resolve schema-relative.
-- EXIT GATE: image repository exists with a repository_url; handoff names the exact human docker step.
CREATE OR REPLACE PROCEDURE <PREFIX>_BUILD_SPCS_HEAD()
RETURNS VARIANT
LANGUAGE SQL
COMMENT='Builds the in-Snowflake SPCS scaffolding (idempotent CREATE IMAGE REPOSITORY, no compute) and RETURNS the human handoff for the deferred image push + compute pool + service DDL. Schema-relative.'
EXECUTE AS OWNER
AS
$$
DECLARE
  repo_url STRING;
  img_path STRING;
BEGIN
  CREATE IMAGE REPOSITORY IF NOT EXISTS <REPO>;
  EXECUTE IMMEDIATE 'SHOW IMAGE REPOSITORIES LIKE ''<REPO>'' IN SCHEMA ' || CURRENT_DATABASE() || '.' || CURRENT_SCHEMA();
  repo_url := (SELECT "repository_url" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
  img_path := '/' || LOWER(CURRENT_DATABASE()) || '/' || LOWER(CURRENT_SCHEMA()) || '/<REPO_LOWER>/<IMAGE>';
  RETURN OBJECT_CONSTRUCT(
    'ok', TRUE,
    'built_in_snowflake', OBJECT_CONSTRUCT(
        'image_repository', CURRENT_DATABASE()||'.'||CURRENT_SCHEMA()||'.<REPO>',
        'repository_url', :repo_url),
    'autonomy_boundary', 'A running service needs a container image pushed from a machine with Docker (the human step). The builder builds the in-Snowflake scaffolding and stops here. After the push, CREATE COMPUTE POOL + CREATE SERVICE + BIND SERVICE ENDPOINT are builder-grantable.',
    'handoff', OBJECT_CONSTRUCT(
        'step1_push_image', 'docker tag <IMAGE> ' || :repo_url || '/<IMAGE> && docker login ' || :repo_url || ' && docker push ' || :repo_url || '/<IMAGE>',
        'step2_compute_pool', 'CREATE COMPUTE POOL IF NOT EXISTS <POOL> MIN_NODES=1 MAX_NODES=1 INSTANCE_FAMILY=CPU_X64_S AUTO_SUSPEND_SECS=300;',
        'step3_service_spec', 'spec:\n  containers:\n    - name: svc\n      image: ' || :img_path || '\n  endpoints:\n    - name: <ENDPOINT>\n      port: <PORT>\n      public: true',
        'note', 'CREATE SERVICE + CREATE IMAGE REPOSITORY are schema-owner privileges; CREATE COMPUTE POOL + BIND SERVICE ENDPOINT must be granted to the builder role. Only the image push requires a human.'),
    'built_by', CURRENT_ROLE()
  );
END
$$;
