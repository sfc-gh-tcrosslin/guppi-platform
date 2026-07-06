"""
GUPPI Live Viewer — Renderer + Server (scoped rewrite)
======================================================
Data layer (query_guppi) is unchanged and canonical. Presentation is served from
templates/index.html + static/guppi.{css,js} (no inline monolith).

Two top-level views:
  - Command Center : KPI landing
  - Classic (SDLC) : stories / defects / incidents / audits / skills (the "before" lens)
  - AILC           : initiatives -> recursive children -> full detail of ANY artifact

Writes (Add Artifact) go ONLY through the gated procs (RULE-029): SUBMIT_INITIATIVE
for INITIATIVE, else CREATE_ARTIFACT. No direct DML on ARTIFACTS.

Usage:
  python render_guppi.py --serve            # Flask app on :8888 (full interactive: drill, add, launch)
  python render_guppi.py --render           # write a read-only self-contained snapshot to ~/Downloads/GUPPI.html
  python render_guppi.py --render --open     # ...and open it
"""
import os
import json
import snowflake.connector
from datetime import datetime

OUTPUT_PATH = os.path.expanduser("~/Downloads/GUPPI.html")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _connect():
    _conn_name = os.getenv("SNOWFLAKE_CONNECTION_NAME")
    return (
        snowflake.connector.connect(connection_name=_conn_name)
        if _conn_name else snowflake.connector.connect()
    )


def query_guppi():
    conn = _connect()
    cur = conn.cursor()

    # Products (used by Command Center for grouping)
    cur.execute("SELECT PRODUCT_ID, NAME, DESCRIPTION, STATUS FROM GUPPIWHEEL.PUBLIC.PRODUCTS ORDER BY NAME")
    products = [{"id": r[0], "name": r[1], "description": r[2], "status": r[3]} for r in cur.fetchall()]

    # Epics from GUPPIWHEEL
    cur.execute("SELECT ID, COALESCE(PRODUCT_ID, METADATA:product::VARCHAR), TITLE, CONTENT:description::VARCHAR, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'EPIC' ORDER BY TITLE")
    epics = [{"id": r[0], "product_id": r[1] or "", "name": r[2], "description": r[3] or "", "status": r[4]} for r in cur.fetchall()]

    cur.execute("""
        SELECT ID, PARENT_ID, TITLE, CONTENT:description::VARCHAR, 
               METADATA:priority::VARCHAR, STAGE, METADATA:story_points::NUMBER,
               OWNER, METADATA:sprint::VARCHAR,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(UPDATED_AT, 'YYYY-MM-DD'),
               COALESCE(PRODUCT_ID, METADATA:product::VARCHAR)
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE TYPE = 'STORY'
        ORDER BY METADATA:priority, ID
    """)
    stories = []
    for r in cur.fetchall():
        stage_to_status = {'Building':'DONE','Research':'IN_PROGRESS','Initiate':'BACKLOG','Built':'DONE','Narrated':'DONE'}
        stories.append({
            "id": r[0], "epic_id": r[1] or "", "title": r[2], "description": r[3] or "",
            "priority": r[4] or "P2", "status": stage_to_status.get(r[5], 'BACKLOG'), "type": "STORY",
            "points": r[6], "assignee": r[7] or "", "sprint": r[8] or "",
            "created": r[9] or "", "updated": r[10] or "", "product_id": r[11] or ""
        })

    cur.execute("""
        SELECT ID, PARENT_ID, TITLE, CONTENT:description::VARCHAR, 
               METADATA:severity::VARCHAR, METADATA:priority::VARCHAR, STAGE,
               CONTENT:fixed_in::VARCHAR, NULL, CONTENT:repro::VARCHAR, OWNER,
               NULL, NULL, 0,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(UPDATED_AT, 'YYYY-MM-DD'),
               COALESCE(PRODUCT_ID, METADATA:product::VARCHAR)
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE TYPE = 'DEFECT'
        ORDER BY METADATA:severity, METADATA:priority
    """)
    defects = []
    for r in cur.fetchall():
        stage_to_status = {'Research':'OPEN','Narrated':'CLOSED','Building':'VERIFIED','Built':'VERIFIED','Initiate':'OPEN'}
        defects.append({
            "id": r[0], "epic_id": r[1] or "", "title": r[2], "description": r[3] or "",
            "severity": r[4] or "SEV3", "priority": r[5] or "P2", "status": stage_to_status.get(r[6], 'OPEN'),
            "found_in": None, "fixed_in": r[7], "repro": r[9] or "",
            "reported_by": r[10] or "", "related_story": r[11], "related_incident": r[12],
            "reopen_count": r[13], "created": r[14] or "", "updated": r[15] or "", "product_id": r[16] or ""
        })

    cur.execute("""
        SELECT ID, COALESCE(PRODUCT_ID, METADATA:product::VARCHAR), METADATA:severity::VARCHAR, STAGE, 
               TITLE, CONTENT:description::VARCHAR,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI'), NULL, NULL,
               NULL, NULL, NULL,
               CONTENT:root_cause::VARCHAR, CONTENT:preventive::VARCHAR, OWNER
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'INCIDENT' ORDER BY CREATED_AT DESC
    """)
    incidents = []
    for r in cur.fetchall():
        stage_to_status = {'Research':'OPEN','Narrated':'CLOSED','Building':'RESOLVED','Built':'RESOLVED','Initiate':'OPEN'}
        incidents.append({
            "id": r[0], "product_id": r[1] or "", "severity": r[2] or "SEV3", "status": stage_to_status.get(r[3], 'OPEN'),
            "title": r[4], "description": r[5] or "",
            "detected_at": r[6], "mitigated_at": r[7], "resolved_at": r[8],
            "ttd": r[9], "ttm": r[10], "ttr": r[11],
            "root_cause": r[12] or "", "preventive": r[13] or "", "detected_by": r[14] or ""
        })

    cur.execute("""
        SELECT ID, CONTENT:target::VARCHAR, CONTENT:target_type::VARCHAR, 
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI'),
               CONTENT:score::FLOAT, CONTENT:grade::VARCHAR, 
               CONTENT:c_signals::NUMBER, CONTENT:d_signals::NUMBER, CONTENT:total_checks::NUMBER,
               CONTENT:builder_vote::VARCHAR, CONTENT:tars_vote::VARCHAR, CONTENT:human_vote::VARCHAR, 
               METADATA:status::VARCHAR
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'AUDIT' ORDER BY CREATED_AT DESC
    """)
    audits = []
    for r in cur.fetchall():
        audits.append({
            "id": r[0], "target": r[1] or "", "type": r[2] or "", "date": r[3],
            "score": r[4], "grade": r[5] or "", "c": r[6], "d": r[7], "checks": r[8],
            "builder_vote": r[9] or "", "tars_vote": r[10] or "", "human_vote": r[11] or "", "status": r[12] or ""
        })

    # No separate findings table in GUPPIWHEEL — findings are embedded in CONTENT
    findings_by_audit = {}
    for a in audits:
        a["findings"] = findings_by_audit.get(a["id"], [])

    qa_dashboard = {}
    qa_runs = []
    golden_tests = []

    cur.execute("""
        SELECT ID, TITLE, CONTENT:hypothesis::VARCHAR, STAGE, METADATA:priority::VARCHAR,
               METADATA:max_calls::NUMBER, METADATA:calls_used::NUMBER,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI'),
               TO_VARCHAR(UPDATED_AT, 'YYYY-MM-DD HH24:MI'),
               CONTENT:result::VARCHAR
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE TYPE = 'INITIATIVE'
        ORDER BY CREATED_AT DESC
    """)
    initiatives = []
    for r in cur.fetchall():
        stage_to_status = {'Initiate':'QUEUED','Research':'RUNNING','Building':'COMPLETE','Built':'COMPLETE','Narrated':'COMPLETE'}
        initiatives.append({
            "id": r[0], "title": r[1], "hypothesis": r[2] or "", "status": stage_to_status.get(r[3], 'QUEUED'),
            "priority": r[4] or "P2", "max_calls": r[5] or 10, "calls_used": r[6] or 0,
            "submitted": r[7] or "", "completed": r[8] or "", "result": r[9] or ""
        })

    cur.execute("""
        SELECT SKILL_ID, SKILL_NAME, AUTHOR, DOMAIN, VERSION, DESCRIPTION,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD')
        FROM SKILL_REGISTRY.PUBLIC.SKILLS
        ORDER BY DOMAIN, SKILL_NAME
    """)
    skills = []
    for r in cur.fetchall():
        skills.append({
            "id": r[0], "name": r[1], "author": r[2] or "", "domain": r[3] or "",
            "version": r[4] or "1.0.0", "description": r[5] or "", "created": r[6] or ""
        })

    cur.execute("""
        SELECT MEMORY_ID, AGENT_ID, CATEGORY, KEY, TAGS, ORIGIN, INSIGHT_TYPE,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI')
        FROM THE_BOND.PUBLIC.MEMORY_STORE
        ORDER BY CREATED_AT DESC
    """)
    bond_entries = []
    for r in cur.fetchall():
        tags = r[4] if r[4] else []
        bond_entries.append({
            "id": r[0], "agent": r[1], "category": r[2], "key": r[3],
            "tags": tags, "origin": r[5] or "", "insight_type": r[6] or "",
            "created": r[7] or ""
        })

    cur.execute("""
        SELECT ID, TITLE, CONTENT:narrative_type::VARCHAR, CONTENT:description::VARCHAR, 
               COALESCE(PRODUCT_ID, METADATA:product::VARCHAR), TAGS, METADATA:version::VARCHAR,
               CONTENT:file_path::VARCHAR, TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD')
        FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
        WHERE TYPE = 'NARRATIVE'
        ORDER BY CREATED_AT DESC
    """)
    narratives = []
    for r in cur.fetchall():
        tags = r[5] if r[5] else []
        narratives.append({
            "id": r[0], "title": r[1], "type": r[2] or "", "description": r[3] or "",
            "product_id": r[4] or "", "tags": tags, "version": r[6] or "1.0.0",
            "file_path": r[7] or "", "created": r[8] or ""
        })

    flywheel = []
    try:
        cur.execute("""
            SELECT ID, TYPE, STAGE, PARENT_ID, TITLE, TAGS, OWNER,
                   TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI'),
                   METADATA,
                   TO_VARCHAR(COALESCE(UPDATED_AT, CREATED_AT), 'YYYY-MM-DD HH24:MI')
            FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
            WHERE SUPERSEDED_BY IS NULL
            ORDER BY COALESCE(UPDATED_AT, CREATED_AT) DESC
        """)
        for r in cur.fetchall():
            tags = r[5] if r[5] else []
            meta = r[8] if r[8] else {}
            flywheel.append({
                "id": r[0], "type": r[1], "stage": r[2], "parent_id": r[3] or "",
                "title": r[4] or "", "tags": tags, "owner": r[6] or "",
                "created": r[7] or "", "metadata": meta, "updated": r[9] or ""
            })
    except Exception as e:
        print(f"  WARNING: GUPPIWHEEL flywheel query failed ({e}). AILC tab will be empty.")

    cur.execute("SELECT CURRENT_USER()")
    current_user = cur.fetchone()[0]

    cur.close()
    conn.close()

    done = sum(1 for s in stories if s["status"] == "DONE")
    in_prog = sum(1 for s in stories if s["status"] == "IN_PROGRESS")
    backlog = sum(1 for s in stories if s["status"] in ("BACKLOG", "PLANNED"))
    defects_open = sum(1 for d in defects if d["status"] not in ("CLOSED", "VERIFIED"))

    return {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "current_user": current_user,
        "products": products,
        "epics": epics,
        "stories": stories,
        "defects": defects,
        "incidents": incidents,
        "audits": audits,
        "initiatives": initiatives,
        "skills": skills,
        "bond": bond_entries,
        "narratives": narratives,
        "flywheel": flywheel,
        "qa": {"dashboard": qa_dashboard, "runs": qa_runs, "golden_tests": golden_tests},
        "summary": {
            "total": len(stories), "done": done, "in_progress": in_prog,
            "backlog": backlog, "defects_open": defects_open,
            "products": len(products),
            "incidents_open": sum(1 for i in incidents if i["status"] not in ("CLOSED", "RESOLVED")),
            "audits": len(audits),
            "initiatives": len(initiatives),
            "skills": len(skills),
            "bond": len(bond_entries),
            "narratives": len(narratives)
        }
    }


def get_artifact(artifact_id):
    """Full detail for ANY artifact + its direct children (drill-down). Read-only."""
    conn = _connect()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT ID, TYPE, TITLE, STAGE, OWNER, PARENT_ID,
                   COALESCE(PRODUCT_ID, METADATA:product::VARCHAR),
                   TO_JSON(CONTENT), TO_JSON(METADATA), TO_JSON(TAGS),
                   TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD HH24:MI'),
                   TO_VARCHAR(UPDATED_AT, 'YYYY-MM-DD HH24:MI'),
                   SUPERSEDED_BY
            FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = %s
        """, (artifact_id,))
        row = cur.fetchone()
        if not row:
            return None

        def _loads(s):
            try:
                return json.loads(s) if s else None
            except Exception:
                return s

        art = {
            "id": row[0], "type": row[1], "title": row[2], "stage": row[3], "owner": row[4] or "",
            "parent_id": row[5] or "", "product_id": row[6] or "",
            "content": _loads(row[7]), "metadata": _loads(row[8]), "tags": _loads(row[9]) or [],
            "created": row[10] or "", "updated": row[11] or "", "superseded_by": row[12] or "",
        }
        # Parent (one hop up)
        art["parent"] = None
        if art["parent_id"]:
            cur.execute("SELECT ID, TYPE, TITLE, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = %s", (art["parent_id"],))
            p = cur.fetchone()
            if p:
                art["parent"] = {"id": p[0], "type": p[1], "title": p[2], "stage": p[3]}
        # Children (one hop down)
        cur.execute("""
            SELECT ID, TYPE, TITLE, STAGE
            FROM GUPPIWHEEL.PUBLIC.ARTIFACTS
            WHERE PARENT_ID = %s AND SUPERSEDED_BY IS NULL
            ORDER BY CREATED_AT
        """, (artifact_id,))
        art["children"] = [{"id": c[0], "type": c[1], "title": c[2], "stage": c[3]} for c in cur.fetchall()]
        return art
    finally:
        cur.close()
        conn.close()


def create_artifact_via_proc(payload):
    """Gated write (RULE-029): INITIATIVE -> SUBMIT_INITIATIVE, else CREATE_ARTIFACT.
    NEVER a direct INSERT into ARTIFACTS. Returns the proc's message/result string."""
    a_type = (payload.get("type") or "").strip().upper()
    title = (payload.get("title") or "").strip()
    if not a_type or not title:
        return {"error": "type and title are required"}

    conn = _connect()
    cur = conn.cursor()
    try:
        if a_type == "INITIATIVE":
            hypothesis = payload.get("hypothesis") or payload.get("description") or ""
            instructions = payload.get("instructions") or ""
            cur.execute(
                "CALL GUPPIWHEEL.PUBLIC.SUBMIT_INITIATIVE(%s, %s, %s)",
                (title, hypothesis, instructions),
            )
            return {"result": cur.fetchone()[0], "via": "SUBMIT_INITIATIVE"}
        else:
            # Build CONTENT/TAGS/METADATA as JSON strings for the gated proc.
            desc = payload.get("description") or ""
            content = payload.get("content")
            if content is None:
                content = {"description": desc} if desc else {}
            content_json = json.dumps(content) if not isinstance(content, str) else content
            tags = payload.get("tags") or []
            if isinstance(tags, str):
                tags = [t.strip() for t in tags.split(",") if t.strip()]
            tags_json = json.dumps(tags)
            meta = payload.get("metadata") or {}
            meta_json = json.dumps(meta) if not isinstance(meta, str) else meta
            product = payload.get("product") or None
            parent_id = payload.get("parent_id") or None
            stage = payload.get("stage") or "Initiate"
            cur.execute(
                "CALL GUPPIWHEEL.PUBLIC.CREATE_ARTIFACT(%s, %s, %s, %s, %s, %s, %s, NULL, %s)",
                (a_type, title, product, content_json, parent_id, stage, tags_json, meta_json),
            )
            out = cur.fetchone()[0]
            try:
                out = json.loads(out)
            except Exception:
                pass
            # Bubble the gated proc's own error (e.g. missing ID convention) to the top level
            if isinstance(out, dict) and out.get("error"):
                return {"error": out["error"], "via": "CREATE_ARTIFACT"}
            return {"result": out, "via": "CREATE_ARTIFACT"}
    finally:
        cur.close()
        conn.close()


def get_launch(artifact_id, ttl=86400):
    """SHARE path: mint a presigned URL (or resolve identifier/url) via the gated proc.
    ttl defaults to 24h since sharing externally is now a deliberate action."""
    conn = _connect()
    cur = conn.cursor()
    try:
        cur.execute("CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(%s, %s)", (artifact_id, ttl))
        row = cur.fetchone()
        if row is None:
            return {"error": "no result"}
        payload = row[0]
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception:
                pass
        return payload
    finally:
        cur.close()
        conn.close()


def open_local(artifact_id):
    """DEFAULT open path: download the launchable's staged file to a local dir using the
    viewer's own Snowflake session (NO presigned URL / no external exposure) and open it.
    For non-staged launchables (external_url / streamlit_url / cortex_agent), returns the
    url/identifier so the frontend opens it directly (nothing to download)."""
    import tempfile
    import webbrowser
    conn = _connect()
    cur = conn.cursor()
    try:
        cur.execute("SELECT METADATA FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE ID = %s", (artifact_id,))
        row = cur.fetchone()
        if row is None:
            return {"error": "artifact not found", "id": artifact_id}
        meta = row[0]
        if isinstance(meta, str):
            try:
                meta = json.loads(meta)
            except Exception:
                meta = {}
        launch = (meta or {}).get("launch") or {}
        stage_path = launch.get("stage_path")
        if stage_path:
            local_dir = os.path.join(tempfile.gettempdir(), "guppi-launch")
            os.makedirs(local_dir, exist_ok=True)
            # GET the single staged file to the local dir (source of truth stays on stage).
            cur.execute(f"GET {stage_path} 'file://{local_dir}'")
            fname = stage_path.rstrip("/").split("/")[-1]
            local_path = os.path.join(local_dir, fname)
            if not os.path.exists(local_path):
                return {"error": "download did not produce a local file", "stage_path": stage_path,
                        "expected": local_path}
            webbrowser.open(f"file://{local_path}")
            return {"opened": local_path, "source": stage_path, "mode": "local_download"}
        # Non-staged launchable: hand back the url/identifier for the frontend to open.
        url = launch.get("url") or launch.get("identifier")
        if url:
            return {"url": url, "mode": "direct", "app_type": launch.get("app_type")}
        return {"error": "no launch stage_path or url on artifact", "id": artifact_id, "launch": launch}
    finally:
        cur.close()
        conn.close()


def render_snapshot():
    """Read-only self-contained snapshot: inlines the data payload so client-side drill
    works from file://. Add/launch require --serve. Written to OUTPUT_PATH."""
    data = query_guppi()
    with open(os.path.join(BASE_DIR, "templates", "index.html")) as f:
        shell = f.read()
    with open(os.path.join(BASE_DIR, "static", "guppi.css")) as f:
        css = f.read()
    with open(os.path.join(BASE_DIR, "static", "guppi.js")) as f:
        js = f.read()
    # Inline css/js and the bootstrap data so the file is standalone.
    html = (shell
            .replace('<link rel="stylesheet" href="/static/guppi.css">', "<style>" + css + "</style>")
            .replace('<script src="/static/guppi.js"></script>',
                     "<script>window.__SNAPSHOT__=" + json.dumps(data, default=str) + ";</script><script>" + js + "</script>"))
    with open(OUTPUT_PATH, "w") as f:
        f.write(html)
    print(f"  Snapshot written: {OUTPUT_PATH} ({len(html)//1024}KB, read-only)")
    return OUTPUT_PATH


def _make_app():
    from flask import Flask, jsonify, request, send_from_directory, render_template
    app = Flask(__name__, template_folder=os.path.join(BASE_DIR, "templates"),
                static_folder=os.path.join(BASE_DIR, "static"), static_url_path="/static")

    @app.route("/")
    def index():
        return render_template("index.html")

    @app.route("/api/data")
    def api_data():
        return jsonify(query_guppi())

    @app.route("/api/artifact/<artifact_id>")
    def api_artifact(artifact_id):
        art = get_artifact(artifact_id)
        if art is None:
            return jsonify({"error": "not found", "id": artifact_id}), 404
        return jsonify(art)

    @app.route("/api/artifact", methods=["POST"])
    def api_create():
        payload = request.get_json(force=True, silent=True) or {}
        result = create_artifact_via_proc(payload)
        code = 400 if isinstance(result, dict) and result.get("error") else 200
        return jsonify(result), code

    @app.route("/api/open/<artifact_id>")
    def api_open(artifact_id):
        # DEFAULT: download the staged file locally + open it (no presigned URL).
        return jsonify(open_local(artifact_id))

    @app.route("/api/share/<artifact_id>")
    def api_share(artifact_id):
        # EXPLICIT: mint a presigned URL to share externally (24h TTL).
        return jsonify(get_launch(artifact_id, 86400))

    @app.route("/api/launch/<artifact_id>")
    def api_launch(artifact_id):
        # Back-compat alias -> share (presigned).
        return jsonify(get_launch(artifact_id, 86400))

    return app


if __name__ == "__main__":
    import sys
    if "--serve" in sys.argv:
        app = _make_app()
        port = 8888
        print(f"GUPPI Viewer — Serving on http://localhost:{port}")
        print("  Command Center / Classic (SDLC) / AILC. Add + drill via the gated procs.")
        app.run(host="0.0.0.0", port=port, debug=False)
    else:
        print("GUPPI Viewer — Rendering read-only snapshot...")
        path = render_snapshot()
        if "--open" in sys.argv:
            import webbrowser
            webbrowser.open(f"file://{path}")
        print("  Done.")
