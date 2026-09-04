-- =============================================================================
-- guppi-platform : seeds/content/widget_catalog.sql
-- Idempotent mint of the W-1..W-10 WIDGET catalog artifacts pointing at the
-- GUPPI_LIB impls (object W-1 = PARSE_DICOM; stage_file W-4..W-10 = build templates).
-- Skips widgets that already exist (matched by TITLE) so re-apply is a no-op and an
-- account that already has them (built live) is untouched.
-- NOTE: on a FRESH install the global W- allocator assigns sequential ids in mint
-- order (W-1 stays PARSE_DICOM; build-templates take the next numbers). Widgets are
-- identified by title + pointer, not by their W-number. Requires seeds/library/
-- 01_widget_library.sql applied + the assets/widgets PUT step done first.
-- =============================================================================
CREATE OR REPLACE PROCEDURE GUPPIWHEEL.PUBLIC.SEED_WIDGET_CATALOG()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
import json
WIDGETS = json.loads(r"""[
 {
  "title": "DICOM metadata parse (pydicom, metadata-only)",
  "tags": [
   "widget",
   "udf",
   "dicom",
   "imaging-dicom",
   "parse",
   "reusable",
   "guppi-lib",
   "guppi-showcase",
   "easter-egg"
  ],
  "class": null,
  "kind": "udf",
  "purpose": "",
  "pointer": {
   "ref": "GUPPI_LIB.LIB.PARSE_DICOM(VARCHAR)",
   "kind": "object"
  }
 },
 {
  "title": "Build template: storage + metadata index (external stage -> parse -> catalog)",
  "tags": [
   "widget",
   "build-template",
   "storage-index",
   "bob",
   "platform"
  ],
  "class": "storage-index",
  "kind": "build-template",
  "purpose": "External-stage a single open-format copy and parse HEADERS ONLY into a metadata catalog (study/series/instance). Metadata only, zero pixel/blob columns.",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/storage-index.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: semantic view over a metadata catalog (Analyst-ready)",
  "tags": [
   "widget",
   "build-template",
   "semantic-index",
   "bob",
   "platform"
  ],
  "class": "semantic-index",
  "kind": "build-template",
  "purpose": "Build a semantic view over the catalog so Cortex Analyst answers natural-language questions (counts/dimensions).",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/semantic-index.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: Cortex Search over catalog free-text",
  "tags": [
   "widget",
   "build-template",
   "search-index",
   "bob",
   "platform"
  ],
  "class": "search-index",
  "kind": "build-template",
  "purpose": "Build a Cortex Search service over the catalog's free-text so lookup complements the semantic view.",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/search-index.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: Cortex Agent tying Analyst + Search into one entry point",
  "tags": [
   "widget",
   "build-template",
   "agent",
   "bob",
   "platform"
  ],
  "class": "agent",
  "kind": "build-template",
  "purpose": "Create an agent wiring the semantic view (analyst/text-to-sql) and the search service into one conversational entry point.",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/agent.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: masking + row-access + scoped entitlements (idempotent, auditor-aware)",
  "tags": [
   "widget",
   "build-template",
   "governance",
   "bob",
   "platform"
  ],
  "class": "governance",
  "kind": "build-template",
  "purpose": "Apply column masking + a row-access policy driven by a SCOPED entitlements table; keep an independent auditor able to READ (rows visible, sensitive column still masked).",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/governance.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: SPCS service scaffolding + human handoff at the docker boundary",
  "tags": [
   "widget",
   "build-template",
   "spcs-head",
   "bob",
   "platform"
  ],
  "class": "spcs-head",
  "kind": "build-template",
  "purpose": "Provision the owner-scoped SPCS scaffolding (image repository) for a service, and RETURN the human handoff for the deferred docker image push + the ready compute-pool + service DDL. Demonstrates the autonomy ceiling.",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/spcs-head.sql",
   "kind": "stage_file"
  }
 },
 {
  "title": "Build template: deterministic acceptance gates (read-only self-check)",
  "tags": [
   "widget",
   "build-template",
   "verify-build",
   "bob",
   "platform"
  ],
  "class": "verify-build",
  "kind": "build-template",
  "purpose": "Run deterministic acceptance gates over a build and return structured pass/fail per gate + overall. This is the builder's SELF-CHECK (feeds an independent audit); it is NOT the audit.",
  "pointer": {
   "ref": "@GUPPI_LIB.LIB.WIDGET_FILES/verify-build.sql",
   "kind": "stage_file"
  }
 }
]""")
def run(session):
    minted=[]; skipped=[]
    for w in WIDGETS:
        ex = session.sql("SELECT COUNT(*) FROM GUPPIWHEEL.PUBLIC.ARTIFACTS_CURRENT_V WHERE TYPE='WIDGET' AND TITLE=?",
                         params=[w["title"]]).collect()[0][0]
        if int(ex) > 0:
            skipped.append(w["title"]); continue
        content = json.dumps({"class": w["class"], "kind": w["kind"], "purpose": w["purpose"],
                              "pointer": w["pointer"],
                              "origin": "packaged: guppi-platform seeds/content/widget_catalog.sql"})
        tags = json.dumps(w["tags"])
        meta = json.dumps({"packaged": True, "source": "guppi-platform"})
        session.sql("CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT('WIDGET', ?, NULL, ?, NULL, 'Published', ?, NULL, ?)",
                    params=[w["title"], content, tags, meta]).collect()
        minted.append(w["title"])
    return {"minted": minted, "skipped": skipped}
$$;
CALL GUPPIWHEEL.PUBLIC.SEED_WIDGET_CATALOG();
