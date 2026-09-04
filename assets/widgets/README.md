# GUPPI_LIB widget files (build templates)

Canonical, reference-free build-template widgets (`W-4`..`W-10`), generalized from the
proven imaging `DICOM_BUILD_*` recipes. The repo is the **source of truth**; the live
`@GUPPI_LIB.LIB.WIDGET_FILES` stage is a deployment of these files.

| file | widget | class |
|---|---|---|
| `storage-index.sql`  | W-4  | storage-index (external stage -> parse -> catalog) |
| `semantic-index.sql` | W-5  | semantic-index (semantic view for Analyst) |
| `search-index.sql`   | W-6  | search-index (Cortex Search over free-text) |
| `agent.sql`          | W-7  | agent (Analyst + Search into one entry point) |
| `governance.sql`     | W-8  | governance (masking + row-access + scoped entitlements) |
| `spcs-head.sql`      | W-9  | spcs-head (SPCS scaffolding + human docker handoff) |
| `verify-build.sql`   | W-10 | verify-build (deterministic acceptance gates) |

These are **templates**, not runnable objects: each carries `<PREFIX>/<SV>/<PARSE_FN>/...`
angle-bracket tokens a builder substitutes before `CREATE`-ing a domain recipe. (The
runnable object-widget `W-1` `PARSE_DICOM` ships as a UDF in `seeds/library/01_widget_library.sql`.)

## Install (file-PUT step)

Run **after** `seeds/library/01_widget_library.sql` (which creates the schema + stage +
`GUPPI_LIB_STEWARD`), as a role holding `GUPPI_LIB_STEWARD` (WRITE on the stage):

```bash
# snow CLI
for f in assets/widgets/*.sql; do
  snow stage copy "$f" @GUPPI_LIB.LIB.WIDGET_FILES/ --overwrite
done
```

or with the Python connector (role GUPPI_LIB_STEWARD):

```sql
PUT 'file://.../assets/widgets/<name>.sql' @GUPPI_LIB.LIB.WIDGET_FILES
    AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```

Then `seeds/content/widget_catalog.sql` mints the `W-1`..`W-10` WIDGET artifacts pointing
at these impls (`kind=stage_file` for the templates; object FQN for `PARSE_DICOM`).

Verify: `LIST @GUPPI_LIB.LIB.WIDGET_FILES` shows 7 files; Stewart's `STEWART_AUDIT`
reports `widget_pointer_broken = 0`.
