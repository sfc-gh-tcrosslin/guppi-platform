"""
GUPPI Live Viewer — Renderer
==============================
Queries GUPPI DB, builds JSON payload, injects into HTML template.
Pull-based: runs on demand ("show guppi"), not on every write.

Usage:
  python render_guppi.py                    # Render and write file
  python render_guppi.py --open             # Render and open in browser
"""
import os
import json
import snowflake.connector
from datetime import datetime

OUTPUT_PATH = os.path.expanduser("~/Downloads/GUPPI.html")


def query_guppi():
    conn = snowflake.connector.connect(
        connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "HealthcareDemos"
    )
    cur = conn.cursor()

    # Products (used by Command Center for grouping)
    cur.execute("SELECT PRODUCT_ID, NAME, DESCRIPTION, STATUS FROM GUPPIWHEEL.PUBLIC.PRODUCTS ORDER BY NAME")
    products = [{"id": r[0], "name": r[1], "description": r[2], "status": r[3]} for r in cur.fetchall()]

    # Epics from GUPPIWHEEL
    cur.execute("SELECT ID, METADATA:product::VARCHAR, TITLE, CONTENT:description::VARCHAR, STAGE FROM GUPPIWHEEL.PUBLIC.ARTIFACTS WHERE TYPE = 'EPIC' ORDER BY TITLE")
    epics = [{"id": r[0], "product_id": r[1] or "", "name": r[2], "description": r[3] or "", "status": r[4]} for r in cur.fetchall()]

    cur.execute("""
        SELECT ID, PARENT_ID, TITLE, CONTENT:description::VARCHAR, 
               METADATA:priority::VARCHAR, STAGE, METADATA:story_points::NUMBER,
               OWNER, METADATA:sprint::VARCHAR,
               TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(UPDATED_AT, 'YYYY-MM-DD'),
               METADATA:product::VARCHAR
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
               METADATA:product::VARCHAR
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
        SELECT ID, METADATA:product::VARCHAR, METADATA:severity::VARCHAR, STAGE, 
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
               METADATA:product::VARCHAR, TAGS, METADATA:version::VARCHAR,
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
        print(f"  WARNING: GUPPIWHEEL flywheel query failed ({e}). Flywheel tab will be empty.")

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


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect x='4' y='4' width='10' height='10' rx='2' fill='%2314B8A6'/><rect x='18' y='4' width='10' height='10' rx='2' fill='%2314B8A6' opacity='0.7'/><rect x='4' y='18' width='10' height='10' rx='2' fill='%2314B8A6' opacity='0.7'/><rect x='18' y='18' width='10' height='10' rx='2' fill='%2314B8A6' opacity='0.4'/></svg>">
<title>GUPPI — Enterprise AI Command Center</title>
<style>
:root{--bg:#0a0a12;--surface:#12131e;--border:#1e2030;--text:#e2e8f0;--muted:#8888a0;--blue:#29B5E8;--green:#14B8A6;--amber:#F59E0B;--red:#FBBF24;--purple:#A78BFA}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text);padding:1.5rem}
h1{font-size:1.5rem;font-weight:800;margin-bottom:0.3rem}
h1 span{color:var(--blue)}
.meta{color:var(--muted);font-size:0.75rem;margin-bottom:1.5rem}
.tabs{display:flex;gap:0.4rem;margin-bottom:1.5rem;flex-wrap:wrap}
.tab{padding:0.4rem 0.9rem;border-radius:6px;border:1px solid var(--border);background:transparent;color:var(--muted);cursor:pointer;font-size:0.8rem;font-weight:500;transition:all 0.15s}
.tab.active{background:var(--blue);color:white;border-color:var(--blue)}
.tab:hover:not(.active){border-color:var(--blue);color:var(--text)}
.tab .badge{background:rgba(255,255,255,0.2);padding:0.1rem 0.4rem;border-radius:3px;font-size:0.65rem;margin-left:0.3rem}
.header-row{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:1.5rem}
.header-left{flex:1}
.kpis{display:flex;gap:1rem;flex-wrap:wrap}
.kpi{text-align:center;min-width:60px}
.kpi .val{font-size:1.4rem;font-weight:700;color:var(--blue)}
.kpi .lbl{font-size:0.6rem;color:var(--muted);text-transform:uppercase}
.filters{display:flex;gap:0.5rem;margin-bottom:1rem;flex-wrap:wrap;align-items:center}
.filters select,.filters input{background:var(--surface);border:1px solid var(--border);color:var(--text);padding:0.35rem 0.6rem;border-radius:5px;font-size:0.75rem}
.filters input{width:200px}
.pill{padding:0.2rem 0.5rem;border-radius:4px;font-size:0.65rem;font-weight:600;cursor:pointer;border:1px solid var(--border)}
.pill.active{border-color:var(--blue);color:var(--blue)}
.story-row{display:grid;grid-template-columns:80px 55px 1fr 90px 70px;align-items:center;padding:0.5rem 0.8rem;border-bottom:1px solid var(--border);font-size:0.8rem;cursor:pointer;transition:background 0.1s}
.story-row:hover{background:rgba(41,181,232,0.04)}
.story-id{font-family:monospace;font-size:0.7rem;color:var(--muted)}
.story-priority{font-weight:700;font-size:0.7rem}
.sp0,.sP0{color:var(--red)}.sp1,.sP1,.sHIGH{color:var(--amber)}.sp2,.sP2,.sMED{color:var(--muted)}
.story-status{font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;text-align:center;font-weight:600}
.st-DONE{background:rgba(20,184,166,0.15);color:var(--green)}
.st-IN_PROGRESS{background:rgba(245,158,11,0.15);color:var(--amber)}
.st-BACKLOG,.st-PLANNED{background:rgba(136,136,160,0.08);color:var(--muted)}
.story-type-DEFECT .story-title{color:var(--amber)}
.detail{display:none;background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;margin:0.3rem 0 0.8rem;font-size:0.8rem;line-height:1.6;white-space:pre-wrap;max-height:400px;overflow-y:auto;color:var(--muted)}
.detail.open{display:block}
.detail .d-meta{display:flex;gap:1.5rem;margin-bottom:0.8rem;font-size:0.7rem;color:var(--muted)}
.detail .d-meta span{padding:0.2rem 0.5rem;background:rgba(41,181,232,0.1);border-radius:4px}
.page-controls{display:flex;justify-content:center;gap:1rem;padding:1rem;font-size:0.8rem}
.page-controls button{background:var(--surface);border:1px solid var(--border);color:var(--text);padding:0.3rem 0.8rem;border-radius:4px;cursor:pointer}
.page-controls button:disabled{opacity:0.3;cursor:default}
.incident{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;margin-bottom:0.8rem}
.incident .i-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:0.5rem}
.incident .i-title{font-weight:600;font-size:0.9rem}
.sev-SEV1{color:var(--red);font-weight:700}.sev-SEV2{color:var(--amber);font-weight:700}.sev-SEV3{color:var(--muted)}
.sev-INFO{color:var(--green)}
.audit-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;margin-bottom:0.8rem;display:grid;grid-template-columns:1fr auto;gap:1rem}
.score{font-size:2rem;font-weight:800}
.score.EXCELLENT{color:var(--green)}.score.GOOD{color:var(--blue)}.score.FAIR{color:var(--amber)}.score.FAIL{color:var(--red)}
.hidden{display:none}
.global-tab{padding:0.5rem 1.2rem;border-radius:8px;border:2px solid var(--border);background:transparent;color:var(--muted);cursor:pointer;font-size:0.85rem;font-weight:700;transition:all 0.2s;letter-spacing:0.3px}
.global-tab.active{background:linear-gradient(135deg,var(--blue),#1a8fb8);color:white;border-color:var(--blue);box-shadow:0 2px 12px rgba(41,181,232,0.3)}
.global-tab:hover:not(.active){border-color:var(--blue);color:var(--text)}
.fw-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;margin-bottom:0.8rem;display:grid;grid-template-columns:auto 1fr auto;gap:1rem;align-items:center}
.fw-type{font-size:0.6rem;text-transform:uppercase;letter-spacing:0.8px;padding:0.2rem 0.5rem;border-radius:4px;font-weight:700}
.fw-type-initiative,.fw-type-INITIATIVE{background:rgba(245,158,11,0.15);color:var(--amber)}
.fw-type-research,.fw-type-RESEARCH{background:rgba(41,181,232,0.15);color:var(--blue)}
.fw-type-story,.fw-type-STORY,.fw-type-EPIC{background:rgba(136,136,160,0.15);color:var(--muted)}
.fw-type-app,.fw-type-model,.fw-type-APP,.fw-type-MODEL{background:rgba(20,184,166,0.15);color:var(--green)}
.fw-type-hero{background:rgba(167,139,250,0.15);color:var(--purple)}
.fw-type-narrative,.fw-type-NARRATIVE{background:rgba(236,72,153,0.15);color:#ec4899}
.fw-type-skill,.fw-type-SKILL{background:rgba(99,102,241,0.15);color:#6366f1}
.fw-type-audit,.fw-type-AUDIT,.fw-type-DEFECT,.fw-type-INCIDENT{background:rgba(239,68,68,0.15);color:#ef4444}
.fw-type-memory,.fw-type-OPS_EVENT{background:rgba(167,139,250,0.1);color:var(--purple)}
.fw-stage{font-size:0.6rem;padding:0.15rem 0.4rem;border-radius:3px;font-weight:600}
.fw-stage-Initiate{background:rgba(245,158,11,0.1);color:var(--amber)}
.fw-stage-Research{background:rgba(41,181,232,0.1);color:var(--blue)}
.fw-stage-Building{background:rgba(20,184,166,0.1);color:var(--green)}
.fw-stage-Built{background:rgba(167,139,250,0.1);color:var(--purple)}
.fw-stage-Narrated{background:rgba(236,72,153,0.1);color:#ec4899}
.fw-lineage{border-left:3px solid var(--border);padding-left:1.5rem;margin-left:1rem}
.fw-lineage-node{position:relative;padding:0.8rem 1rem;margin-bottom:0.5rem;background:var(--surface);border:1px solid var(--border);border-radius:8px}
.fw-lineage-node::before{content:'';position:absolute;left:-1.6rem;top:50%;width:1.3rem;height:2px;background:var(--border)}
.fw-pipeline-stage{text-align:center;padding:1rem;border-radius:8px;background:var(--surface);border:1px solid var(--border)}
.fw-pipeline-arrow{color:var(--blue);font-size:1.5rem;text-align:center;padding:0.5rem}
</style>
</head>
<body>
<div style="display:flex;gap:0.5rem;margin-bottom:1.2rem">
<button class="global-tab active" id="gt-command" onclick="switchGlobal('command')">Command Center</button>
<button class="global-tab" id="gt-flywheel" onclick="switchGlobal('flywheel')">Flywheel</button>
</div>

<div id="global-command">
<div class="header-row">
<div class="header-left">
<h1>GUPPI — <span>Enterprise AI Command Center</span></h1>
<div class="meta">Generated: <span id="gen-time"></span> | Headless: all mutations via CoCo | This view is read-only</div>
</div>
<div class="kpis" id="kpis"></div>
<button id="refresh-btn" onclick="refreshData()" style="background:var(--surface);border:1px solid var(--border);color:var(--blue);padding:0.4rem 0.8rem;border-radius:6px;font-size:0.75rem;font-weight:600;cursor:pointer;transition:all 0.15s;margin-left:12px" onmouseover="this.style.borderColor='var(--blue)'" onmouseout="this.style.borderColor='var(--border)'">&#8635; Refresh</button>
</div>

<div class="tabs" id="tabs">
<button class="tab active" onclick="showTab('backlog')">Backlog</button>
<button class="tab" onclick="showTab('defects')">Defects</button>
<button class="tab" onclick="showTab('ops')">Ops</button>
<button class="tab" onclick="showTab('audits')">Audits</button>
<button class="tab" onclick="showTab('initiatives')">Initiatives</button>
<button class="tab" onclick="showTab('qa')">QA</button>
<button class="tab" onclick="showTab('skills')">Skills</button>
<button class="tab" onclick="showTab('bond')">Bond</button>
<button class="tab" onclick="showTab('narratives')">Narratives</button>
</div>

<div id="filters" class="filters"></div>
<div id="content"></div>
<div id="page-controls" class="page-controls hidden"></div>
</div>

<div id="global-flywheel" style="display:none">
<div class="header-row">
<div class="header-left">
<h1>GUPPIWHEEL — <span>Value Creation Engine</span></h1>
</div>
<div class="kpis" id="fw-kpis"></div>
</div>
<div class="tabs" id="fw-tabs">
<div class="tabs" id="fw-tabs" style="display:none">
<button class="tab active" onclick="showFwTab('all')">All Artifacts</button>
<button class="tab" onclick="showFwTab('lineage')">Lineage View</button>
<button class="tab" onclick="showFwTab('pipeline')">Pipeline</button>
</div>
<div id="fw-filters" class="filters"></div>
<div id="fw-content"></div>
</div>

<script id="guppi-data" type="application/json">__DATA__</script>
<script>
var D=JSON.parse(document.getElementById('guppi-data').textContent);
var currentTab=localStorage.getItem('guppi-tab')||'backlog',currentPage=0,pageSize=50;
var filters={product:'ALL',status:'ALL',search:''};
var currentGlobal=localStorage.getItem('guppi-global')||'command';
var fwTab='all',fwTypeFilter='ALL',fwScopeFilter='ALL',fwStageFilter='ALL',fwSearch='',fwOpenInits={};
var currentUser=D.current_user||'USER';

function switchGlobal(view){
currentGlobal=view;
localStorage.setItem('guppi-global',view);
document.getElementById('global-command').style.display=view==='command'?'block':'none';
document.getElementById('global-flywheel').style.display=view==='flywheel'?'block':'none';
document.getElementById('gt-command').classList.toggle('active',view==='command');
document.getElementById('gt-flywheel').classList.toggle('active',view==='flywheel');
if(view==='flywheel') renderFlywheel();
}

function showFwTab(t){
fwTab=t;
document.querySelectorAll('#fw-tabs .tab').forEach(function(b){b.classList.remove('active')});
event.target.classList.add('active');
renderFlywheel();
}

function renderFlywheel(){
var fw=D.flywheel||[];
var fwKpis=document.getElementById('fw-kpis');
var stageOrder=['Initiate','Research','Building','Built','Narrated'];
var stages={};
stageOrder.forEach(function(s){stages[s]=0;});
fw.forEach(function(a){if(a.type==='INITIATIVE')stages[a.stage]=(stages[a.stage]||0)+1;});
fwKpis.innerHTML=stageOrder.map(function(s){return '<div class="kpi"><div class="val" style="font-size:1.2rem">'+(stages[s]||0)+'</div><div class="lbl">'+s+'</div></div>';}).join('');
renderInitiativeList(fw);
}

function renderInitiativeList(fw){
var inits=fw.filter(function(a){return a.type==='INITIATIVE';});
var stageOrder=['Initiate','Research','Building','Built','Narrated'];
// Default sort: most recently updated first
inits.sort(function(a,b){
  var au=a.updated||a.created||'';
  var bu=b.updated||b.created||'';
  return bu.localeCompare(au);
});

var fil=document.getElementById('fw-filters');
fil.innerHTML='<select onchange="fwStageFilter=this.value;renderFlywheel()"><option value="ALL">All Stages</option>'+stageOrder.map(function(s){return '<option value="'+s+'"'+(fwStageFilter===s?' selected':'')+'>'+s+'</option>';}).join('')+'</select>'+
'<select onchange="fwScopeFilter=this.value;renderFlywheel()" style="margin-left:0.5rem"><option value="ALL">All Initiatives</option><option value="MY_OWNED"'+(fwScopeFilter==='MY_OWNED'?' selected':'')+'>My Initiatives</option></select>'+
'<input type="text" placeholder="Search title..." oninput="fwSearch=this.value;renderInitiativeList(D.flywheel||[])" style="margin-left:0.5rem;padding:0.4rem 0.6rem;background:var(--surface);border:1px solid var(--border);color:var(--text);border-radius:6px" value="'+(fwSearch||'').replace(/"/g,'&quot;')+'">';

var filtered=inits.filter(function(i){
  if(fwStageFilter!=='ALL' && i.stage!==fwStageFilter) return false;
  if(fwScopeFilter==='MY_OWNED' && i.owner!==currentUser) return false;
  if(fwSearch && (i.title||'').toLowerCase().indexOf(fwSearch.toLowerCase())===-1) return false;
  return true;
});

// Build child index by parent_id
var byParent={};
fw.forEach(function(a){if(a.parent_id){if(!byParent[a.parent_id])byParent[a.parent_id]=[];byParent[a.parent_id].push(a);}});

var h='<div style="margin-bottom:0.8rem;color:var(--muted);font-size:0.75rem">'+filtered.length+' initiatives</div>';
filtered.forEach(function(i){
  var children=getDescendants(i.id, byParent);
  var counts={};
  children.forEach(function(c){counts[c.type]=(counts[c.type]||0)+1;});
  var typeOrder=['RESEARCH','STORY','EPIC','APP','NARRATIVE','DEFECT','INCIDENT','AUDIT'];
  var pills=typeOrder.filter(function(t){return counts[t];}).map(function(t){
    return '<span class="fw-type fw-type-'+t+'" style="font-size:0.65rem">'+counts[t]+' '+t+'</span>';
  }).join(' ');
  var isOpen=fwOpenInits[i.id]?true:false;
  h+='<div class="fw-init-row" style="background:var(--surface);border:1px solid var(--border);border-radius:10px;margin-bottom:0.6rem;overflow:hidden">';
  h+='<div data-init-id="'+i.id+'" onclick="toggleInit(this.getAttribute(&quot;data-init-id&quot;))" style="padding:0.9rem 1rem;cursor:pointer;display:grid;grid-template-columns:auto 1fr auto auto;gap:0.8rem;align-items:center">';
  h+='<span style="font-family:monospace;color:var(--muted);font-size:0.75rem;width:100px">'+i.id+'</span>';
  h+='<div><div style="font-weight:600">'+escapeHtml(i.title)+'</div>';
  h+='<div style="font-size:0.7rem;color:var(--muted);margin-top:0.2rem">Owner: '+(i.owner||'—')+(pills?' &nbsp;|&nbsp; '+pills:'')+'</div></div>';
  h+='<span class="fw-stage fw-stage-'+i.stage+'">'+i.stage+'</span>';
  h+='<span style="color:var(--muted);font-size:0.9rem">'+(isOpen?'▼':'▶')+'</span>';
  h+='</div>';
  if(isOpen){
    h+='<div style="padding:0 1rem 1rem 1rem;border-top:1px solid var(--border)">';
    // Hypothesis / summary
    var hyp=i.metadata&&(i.metadata.hypothesis)||'';
    var meta=i.metadata||{};
    h+='<div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem;margin:0.8rem 0">';
    h+='<div><div style="font-size:0.7rem;color:var(--muted);text-transform:uppercase">Created</div><div>'+(i.created||'—')+'</div></div>';
    h+='<div><div style="font-size:0.7rem;color:var(--muted);text-transform:uppercase">Priority</div><div>'+(meta.priority||'—')+'</div></div>';
    h+='</div>';
    if(hyp){h+='<div style="margin:0.8rem 0"><div style="font-size:0.7rem;color:var(--muted);text-transform:uppercase;margin-bottom:0.3rem">Hypothesis</div><div style="background:var(--bg);padding:0.6rem;border-radius:6px;font-size:0.85rem">'+escapeHtml(hyp)+'</div></div>';}
    // Children grouped by type
    if(children.length){
      h+='<div style="margin-top:0.8rem"><div style="font-size:0.7rem;color:var(--muted);text-transform:uppercase;margin-bottom:0.4rem">Linked Artifacts ('+children.length+')</div>';
      typeOrder.forEach(function(t){
        var group=children.filter(function(c){return c.type===t;});
        if(!group.length) return;
        h+='<div style="margin:0.4rem 0"><div style="font-size:0.65rem;color:var(--blue);font-weight:600;margin-bottom:0.2rem">'+t+' ('+group.length+')</div>';
        group.forEach(function(c){
          var hasLaunch = c.metadata && c.metadata.launch && c.metadata.launch.app_type;
          var launchType = hasLaunch ? c.metadata.launch.app_type : null;
          var launchBadge = '';
          if(launchType==='static_html') launchBadge='<span style="font-size:0.55rem;color:var(--green);background:rgba(20,184,166,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">HTML</span>';
          else if(launchType==='cortex_agent') launchBadge='<span style="font-size:0.55rem;color:var(--purple);background:rgba(167,139,250,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">AGENT</span>';
          else if(launchType==='spcs_service') launchBadge='<span style="font-size:0.55rem;color:var(--blue);background:rgba(41,181,232,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">SPCS</span>';
          else if(launchType==='streamlit'||launchType==='streamlit_url') launchBadge='<span style="font-size:0.55rem;color:var(--blue);background:rgba(41,181,232,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">STREAMLIT</span>';
          else if(launchType==='native_app') launchBadge='<span style="font-size:0.55rem;color:var(--amber);background:rgba(245,158,11,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">NATIVE APP</span>';
          else if(launchType==='external_url') launchBadge='<span style="font-size:0.55rem;color:var(--muted);background:rgba(136,136,160,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">URL</span>';
          else if(launchType==='pdf') launchBadge='<span style="font-size:0.55rem;color:var(--red);background:rgba(239,68,68,0.1);padding:0.1rem 0.3rem;border-radius:3px;margin-right:0.3rem">PDF</span>';
          var openBtn = hasLaunch ? '<button onclick="openArtifact(this.getAttribute(&quot;data-aid&quot;))" data-aid="'+c.id+'" style="font-size:0.65rem;padding:0.15rem 0.5rem;background:var(--blue);color:white;border:none;border-radius:4px;cursor:pointer;margin-left:0.4rem">Open</button>' : '';
          h+='<div style="padding:0.3rem 0.6rem;margin:0.15rem 0;background:var(--bg);border-radius:5px;font-size:0.8rem;display:grid;grid-template-columns:auto 1fr auto auto;gap:0.6rem;align-items:center">';
          h+='<span style="font-family:monospace;color:var(--muted);font-size:0.7rem;min-width:90px">'+c.id+'</span>';
          h+='<span>'+launchBadge+escapeHtml(c.title||'')+'</span>';
          h+='<span class="fw-stage fw-stage-'+c.stage+'" style="font-size:0.6rem">'+c.stage+'</span>';
          h+=openBtn;
          h+='</div>';
        });
        h+='</div>';
      });
      h+='</div>';
    } else {
      h+='<div style="color:var(--muted);font-style:italic;font-size:0.8rem">No linked artifacts yet</div>';
    }
    h+='</div>';
  }
  h+='</div>';
});
document.getElementById('fw-content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No initiatives match filters</div>';
}

function getDescendants(rootId, byParent){
  var out=[];
  var stack=[rootId];
  var seen={};
  while(stack.length){
    var pid=stack.pop();
    if(seen[pid]) continue;
    seen[pid]=true;
    var kids=byParent[pid]||[];
    kids.forEach(function(k){out.push(k);stack.push(k.id);});
  }
  return out;
}

function toggleInit(id){
  fwOpenInits[id]=!fwOpenInits[id];
  renderFlywheel();
}

function openArtifact(id){
  fetch('/api/launch/'+encodeURIComponent(id))
    .then(function(r){return r.json();})
    .then(function(d){
      if(d.error){alert('Could not open: '+d.error);return;}
      if(d.url){window.open(d.url,'_blank');return;}
      if(d.identifier){
        var msg='Open in Snowsight:\\n\\n'+d.identifier+'\\n\\n(Copied to clipboard)';
        if(navigator.clipboard) navigator.clipboard.writeText(d.identifier);
        if(d.snowsight_url) window.open(d.snowsight_url,'_blank');
        else alert(msg);
        return;
      }
      alert('No launch target on this artifact.');
    })
    .catch(function(e){alert('Launch error: '+e.message);});
}

function escapeHtmlFw(s){return (s===null||s===undefined?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

function renderFwAll(fw){
var el=document.getElementById('fw-filters');
el.innerHTML='<select onchange="fwTypeFilter=this.value;renderFlywheel()"><option value="ALL">All Types</option><option value="INITIATIVE"'+(fwTypeFilter==='INITIATIVE'?' selected':'')+'>Initiatives</option><option value="RESEARCH"'+(fwTypeFilter==='RESEARCH'?' selected':'')+'>Research</option><option value="STORY"'+(fwTypeFilter==='STORY'?' selected':'')+'>Stories</option><option value="EPIC"'+(fwTypeFilter==='EPIC'?' selected':'')+'>Epics</option><option value="APP"'+(fwTypeFilter==='APP'?' selected':'')+'>Apps/Models</option><option value="NARRATIVE"'+(fwTypeFilter==='NARRATIVE'?' selected':'')+'>Narratives</option><option value="SKILL"'+(fwTypeFilter==='SKILL'?' selected':'')+'>Skills</option><option value="AUDIT"'+(fwTypeFilter==='AUDIT'?' selected':'')+'>Audits</option><option value="DEFECT"'+(fwTypeFilter==='DEFECT'?' selected':'')+'>Defects</option><option value="INCIDENT"'+(fwTypeFilter==='INCIDENT'?' selected':'')+'>Incidents</option></select><select onchange="fwScopeFilter=this.value;renderFlywheel()" style="margin-left:0.5rem"><option value="ALL">All Artifacts</option><option value="MY_TAGGED"'+(fwScopeFilter==='MY_TAGGED'?' selected':'')+'>My Tags</option><option value="MY_OWNED"'+(fwScopeFilter==='MY_OWNED'?' selected':'')+'>My Owned</option></select>';
var items=fw.filter(function(a){
if(fwTypeFilter!=='ALL' && (a.type||'').toUpperCase()!==fwTypeFilter) return false;
if(fwScopeFilter==='MY_TAGGED'){var tu=a.metadata&&a.metadata.tagged_users;if(!tu) return false;var found=false;if(Array.isArray(tu)){tu.forEach(function(u){if(u===currentUser)found=true;});}return found;}
if(fwScopeFilter==='MY_OWNED') return a.owner===currentUser;
return true;
});
var h='<div style="margin-bottom:0.8rem;color:var(--muted);font-size:0.75rem">Showing '+Math.min(items.length,200)+' of '+items.length+' artifacts</div>';
items.slice(0,200).forEach(function(a){
h+='<div class="fw-card">';
h+='<div><span class="fw-type fw-type-'+a.type+'">'+a.type+'</span></div>';
h+='<div><div style="font-weight:700;margin-bottom:0.2rem">'+a.title+'</div>';
h+='<div style="font-size:0.7rem;color:var(--muted)">Owner: '+a.owner;
if(a.parent_id) h+=' | Parent: <span style="font-family:monospace;color:var(--blue)">'+a.parent_id+'</span>';
if(a.metadata&&a.metadata.tagged_users&&a.metadata.tagged_users.length) h+=' | <span style="color:var(--purple)">@'+a.metadata.tagged_users.join(' @')+'</span>';
h+='</div>';
if(a.tags&&a.tags.length) h+='<div style="margin-top:0.3rem">'+a.tags.slice(0,6).map(function(t){return '<span style="display:inline-block;padding:0.1rem 0.35rem;margin:0.1rem;border-radius:3px;font-size:0.6rem;background:rgba(41,181,232,0.08);color:var(--blue)">'+t+'</span>';}).join('')+'</div>';
h+='</div>';
h+='<div style="text-align:right"><span class="fw-stage fw-stage-'+a.stage+'">'+a.stage+'</span><div style="font-size:0.6rem;color:var(--muted);margin-top:0.3rem">'+a.created+'</div></div>';
h+='</div>';
});
document.getElementById('fw-content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No artifacts in flywheel</div>';
}

function renderFwLineage(fw){
document.getElementById('fw-filters').innerHTML='';
var roots=fw.filter(function(a){return !a.parent_id;});
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">Showing lineage chains from root initiatives</div>';
roots.forEach(function(root){
h+='<div style="margin-bottom:1.5rem;padding:1rem;background:var(--surface);border:1px solid var(--border);border-radius:10px">';
h+='<div style="display:flex;align-items:center;gap:0.5rem;margin-bottom:0.8rem"><span class="fw-type fw-type-'+root.type+'">'+root.type+'</span><span style="font-weight:700;font-size:1rem">'+root.title+'</span><span class="fw-stage fw-stage-'+root.stage+'">'+root.stage+'</span></div>';
var children=fw.filter(function(a){return a.parent_id===root.id;});
if(children.length){
h+='<div class="fw-lineage">';
children.forEach(function(c){
h+='<div class="fw-lineage-node"><div style="display:flex;align-items:center;gap:0.5rem"><span class="fw-type fw-type-'+c.type+'">'+c.type+'</span><span style="font-weight:600;font-size:0.85rem">'+c.title+'</span><span class="fw-stage fw-stage-'+c.stage+'">'+c.stage+'</span></div><div style="font-size:0.65rem;color:var(--muted);margin-top:0.3rem">'+c.owner+' | '+c.created+'</div></div>';
var grandchildren=fw.filter(function(a){return a.parent_id===c.id;});
if(grandchildren.length){
h+='<div class="fw-lineage" style="margin-left:1.5rem">';
grandchildren.forEach(function(gc){
h+='<div class="fw-lineage-node"><span class="fw-type fw-type-'+gc.type+'">'+gc.type+'</span> '+gc.title+'</div>';
});
h+='</div>';
}
});
h+='</div>';
} else {
h+='<div style="font-size:0.75rem;color:var(--muted);padding:0.5rem 0">No child artifacts yet</div>';
}
h+='</div>';
});
if(!roots.length) h='<div style="padding:2rem;color:var(--muted)">No root artifacts found</div>';
document.getElementById('fw-content').innerHTML=h;
}

function renderFwPipeline(fw){
document.getElementById('fw-filters').innerHTML='';
var stages=['spark','active','built','proven','told','archived'];
var stageLabels={'spark':'💡 Spark','active':'🔬 Active','built':'🏗️ Built','proven':'✅ Proven','told':'📖 Told','archived':'📦 Archived'};
var byStage={};
stages.forEach(function(s){byStage[s]=fw.filter(function(a){return a.stage===s;});});
var h='<div style="display:grid;grid-template-columns:repeat(6,1fr);gap:0.5rem;margin-bottom:1.5rem">';
stages.forEach(function(s){
h+='<div class="fw-pipeline-stage"><div style="font-size:1.5rem;font-weight:800;color:var(--blue)">'+byStage[s].length+'</div><div style="font-size:0.7rem;color:var(--muted)">'+stageLabels[s]+'</div></div>';
});
h+='</div>';
h+='<div style="display:flex;justify-content:center;margin-bottom:1.5rem;gap:0;align-items:center">';
stages.forEach(function(s,i){
h+='<div style="padding:0.3rem 0.7rem;border-radius:4px;font-size:0.7rem;font-weight:600" class="fw-stage fw-stage-'+s+'">'+s+'</div>';
if(i<stages.length-1) h+='<div style="color:var(--blue);padding:0 0.5rem">→</div>';
});
h+='</div>';
stages.forEach(function(s){
if(!byStage[s].length) return;
h+='<div style="margin-bottom:1rem"><div style="font-size:0.75rem;font-weight:700;color:var(--muted);margin-bottom:0.5rem;text-transform:uppercase">'+stageLabels[s]+' ('+byStage[s].length+')</div>';
byStage[s].forEach(function(a){
h+='<div style="display:flex;align-items:center;gap:0.5rem;padding:0.4rem 0.8rem;border-bottom:1px solid var(--border);font-size:0.8rem"><span class="fw-type fw-type-'+a.type+'">'+a.type+'</span><span>'+a.title+'</span><span style="margin-left:auto;font-size:0.65rem;color:var(--muted)">'+a.owner+'</span></div>';
});
h+='</div>';
});
document.getElementById('fw-content').innerHTML=h;
}

function refreshData(){
var btn=document.getElementById('refresh-btn');
btn.textContent='Refreshing...';btn.disabled=true;
fetch('/api/data').then(r=>r.json()).then(data=>{
D=data;
document.getElementById('gen-time').textContent=D.generated_at;
renderKPIs();showTab(currentTab);
btn.innerHTML='&#8635; Refresh';btn.disabled=false;
}).catch(e=>{
btn.innerHTML='&#8635; Refresh';btn.disabled=false;
btn.textContent='Offline (file mode)';setTimeout(()=>{btn.innerHTML='&#8635; Refresh'},2000);
});
}

document.getElementById('gen-time').textContent=D.generated_at;

function renderKPIs(){
var s=D.summary;
document.getElementById('kpis').innerHTML=
'<div class="kpi"><div class="val">'+s.total+'</div><div class="lbl">Stories</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--green)">'+s.done+'</div><div class="lbl">Done</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--amber)">'+s.in_progress+'</div><div class="lbl">In Progress</div></div>'+
'<div class="kpi"><div class="val">'+s.backlog+'</div><div class="lbl">Backlog</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--red)">'+s.defects_open+'</div><div class="lbl">Open Defects</div></div>'+
'<div class="kpi"><div class="val">'+s.incidents_open+'</div><div class="lbl">Open Incidents</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--purple)">'+(s.skills||0)+'</div><div class="lbl">Skills</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--purple)">'+(s.bond||0)+'</div><div class="lbl">Bond</div></div>'+
'<div class="kpi"><div class="val" style="color:var(--blue)">'+(s.narratives||0)+'</div><div class="lbl">Narratives</div></div>';
}

function showTab(t){
currentTab=t;currentPage=0;
localStorage.setItem('guppi-tab',t);
document.querySelectorAll('.tab').forEach(function(b){b.classList.remove('active')});
event.target.classList.add('active');
render();
}

function render(){
if(currentTab==='backlog') renderBacklog();
else if(currentTab==='defects') renderDefects();
else if(currentTab==='ops') renderOps();
else if(currentTab==='audits') renderAudits();
else if(currentTab==='initiatives') renderInitiatives();
else if(currentTab==='qa') renderQA();
else if(currentTab==='skills') renderSkills();
else if(currentTab==='bond') renderBondTab();
else if(currentTab==='narratives') renderNarratives();
}

function renderFilters(){
var el=document.getElementById('filters');
var prodSel=el.querySelector('select[data-filter="product"]');
var statSel=el.querySelector('select[data-filter="status"]');
if(prodSel&&statSel){
prodSel.value=filters.product;
statSel.value=filters.status;
return;
}
var prods='<select data-filter="product" onchange="filters.product=this.value;currentPage=0;renderBacklogContent()"><option value="ALL">All Products</option>';
D.products.forEach(function(p){prods+='<option value="'+p.id+'"'+(filters.product===p.id?' selected':'')+'>'+p.name+'</option>';});
prods+='</select>';
var stats='<select data-filter="status" onchange="filters.status=this.value;currentPage=0;renderBacklogContent()"><option value="ALL"'+(filters.status==='ALL'?' selected':'')+'>All Status</option><option value="BACKLOG"'+(filters.status==='BACKLOG'?' selected':'')+'>Backlog</option><option value="PLANNED"'+(filters.status==='PLANNED'?' selected':'')+'>Planned</option><option value="IN_PROGRESS"'+(filters.status==='IN_PROGRESS'?' selected':'')+'>In Progress</option><option value="DONE"'+(filters.status==='DONE'?' selected':'')+'>Done</option></select>';
var search='<input type="text" placeholder="Search stories..." value="'+(filters.search||'')+'" oninput="filters.search=this.value.toLowerCase();currentPage=0;renderBacklogContent()">';
el.innerHTML=prods+stats+search;
}

function getFilteredStories(){
return D.stories.filter(function(s){
if(filters.product!=='ALL'&&s.product_id!==filters.product) return false;
if(filters.status!=='ALL'&&s.status!==filters.status) return false;
if(filters.search&&s.title.toLowerCase().indexOf(filters.search)===-1&&s.id.toLowerCase().indexOf(filters.search)===-1) return false;
return true;
});
}

function renderBacklog(){
renderFilters();
renderBacklogContent();
}

function renderBacklogContent(){
var stories=getFilteredStories();
var h='';
if(D.defects&&D.defects.length){
var openDef=D.defects.filter(function(d){return d.status!=='CLOSED'&&d.status!=='VERIFIED';});
if(openDef.length){
h+='<div style="border:1px solid var(--red);border-radius:8px;padding:0.8rem;margin-bottom:1.5rem;background:rgba(239,68,68,0.05)">';
h+='<div style="font-size:0.8rem;font-weight:700;color:var(--red);margin-bottom:0.5rem">OPEN DEFECTS ('+openDef.length+') — blocks feature work</div>';
openDef.forEach(function(d,i){
h+='<div class="story-row story-type-DEFECT" onclick="toggleDetail(this)" data-id="def-'+i+'">';
h+='<span class="story-id">'+d.id+'</span>';
h+='<span class="story-priority sev-'+d.severity+'">'+d.severity+'</span>';
h+='<span class="story-title">'+d.title+'</span>';
h+='<span class="story-status st-'+d.status+'">'+d.status+'</span>';
h+='<span style="font-size:0.65rem;color:var(--red)">'+d.priority+'</span>';
h+='</div>';
h+='<div class="detail" id="detail-def-'+i+'"><div class="d-meta"><span>Severity: '+d.severity+'</span><span>Found in: '+(d.found_in||'-')+'</span><span>Reported: '+d.created+'</span></div>'+(d.description?escapeHtml(d.description):'No description')+'</div>';
});
h+='</div>';
}
}
var start=currentPage*pageSize;
var page=stories.slice(start,start+pageSize);
page.forEach(function(s,i){
var idx='s-'+(start+i);
var priClass='sp'+s.priority.replace('-','');
h+='<div class="story-row" onclick="toggleDetail(this)" data-id="'+idx+'">';
h+='<span class="story-id">'+s.id+'</span>';
h+='<span class="story-priority '+priClass+'">'+s.priority+'</span>';
h+='<span class="story-title">'+s.title+'</span>';
h+='<span class="story-status st-'+s.status+'">'+s.status.replace('_',' ')+'</span>';
h+='<span style="font-size:0.7rem;color:var(--muted)"></span>';
h+='</div>';
h+='<div class="detail" id="detail-'+idx+'"><div class="d-meta"><span>Epic: '+s.epic_id+'</span><span>Created: '+s.created+'</span><span>Points: '+(s.points||'-')+'</span></div>'+escapeHtml(s.description)+'</div>';
});
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No stories match filters</div>';
renderPagination(stories.length);
}

function renderDefects(){
document.getElementById('filters').innerHTML='';
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">All defects ('+D.defects.length+' total)</div>';
if(!D.defects||!D.defects.length){h='<div style="padding:2rem;color:var(--muted)">No defects logged</div>';document.getElementById('content').innerHTML=h;return;}
D.defects.forEach(function(d,i){
var sevClass='sev-'+d.severity;
var stClass='st-'+d.status;
h+='<div class="story-row story-type-DEFECT" onclick="toggleDetail(this)" data-id="defTab-'+i+'">';
h+='<span class="story-id">'+d.id+'</span>';
h+='<span class="story-priority '+sevClass+'">'+d.severity+'</span>';
h+='<span class="story-title">'+d.title+'</span>';
h+='<span class="story-status '+stClass+'">'+d.status+'</span>';
h+='<span style="font-size:0.65rem;color:var(--red)">'+d.priority+'</span>';
h+='</div>';
h+='<div class="detail" id="detail-defTab-'+i+'">';
h+='<div class="d-meta">';
h+='<span>Severity: '+d.severity+'</span>';
h+='<span>Priority: '+d.priority+'</span>';
h+='<span>Found in: '+(d.found_in||'-')+'</span>';
h+='<span>Reported: '+d.created+'</span>';
if(d.related_story) h+='<span>Related Story: '+d.related_story+'</span>';
if(d.related_incident) h+='<span>Related Incident: '+d.related_incident+'</span>';
h+='</div>';
h+=(d.description?escapeHtml(d.description):'No description');
if(d.repro) h+='<div style="margin-top:0.5rem;font-size:0.8rem"><strong>Repro Steps:</strong> '+escapeHtml(d.repro)+'</div>';
if(d.fixed_in) h+='<div style="margin-top:0.5rem;padding:0.5rem;background:rgba(34,197,94,0.05);border-radius:4px;font-size:0.8rem"><strong>Fixed in:</strong> '+d.fixed_in+'</div>';
h+='</div>';
});
document.getElementById('content').innerHTML=h;
document.getElementById('page-controls').classList.add('hidden');
}

function renderOps(){
document.getElementById('filters').innerHTML='';
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">Incidents ('+D.incidents.length+' total)</div>';
D.incidents.forEach(function(inc,i){
h+='<div class="story-row" onclick="toggleDetail(this)" data-id="ops-'+i+'">';
h+='<span class="story-id">'+inc.id+'</span>';
h+='<span class="story-priority sev-'+inc.severity+'">'+inc.severity+'</span>';
h+='<span class="story-title">'+inc.title+'</span>';
h+='<span class="story-status st-'+inc.status+'">'+inc.status+'</span>';
h+='<span style="font-size:0.65rem;color:var(--muted)">'+(inc.detected_by||'')+'</span>';
h+='</div>';
h+='<div class="detail" id="detail-ops-'+i+'"><div class="d-meta">';
h+='<span>Detected: '+(inc.detected_at||'-')+'</span>';
h+='<span>Mitigated: '+(inc.mitigated_at||'-')+'</span>';
h+='<span>Resolved: '+(inc.resolved_at||'-')+'</span>';
if(inc.ttd||inc.ttm||inc.ttr) h+='<span>TTD:'+( inc.ttd||'-')+'m TTM:'+(inc.ttm||'-')+'m TTR:'+(inc.ttr||'-')+'m</span>';
h+='</div>';
if(inc.description) h+=escapeHtml(inc.description);
if(inc.root_cause) h+='<div style="margin-top:0.5rem"><strong>Root Cause:</strong> '+escapeHtml(inc.root_cause)+'</div>';
if(inc.preventive) h+='<div style="margin-top:0.3rem"><strong>Preventive:</strong> '+escapeHtml(inc.preventive)+'</div>';
h+='</div>';
});
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No incidents</div>';
document.getElementById('page-controls').classList.add('hidden');
}

function renderAudits(){
document.getElementById('filters').innerHTML='';
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">Audit Runs ('+D.audits.length+' total)</div>';
D.audits.forEach(function(a,i){
h+='<div class="story-row" onclick="toggleDetail(this)" data-id="aud-'+i+'">';
h+='<span class="story-id">'+a.id+'</span>';
h+='<span class="story-priority"><span class="score '+a.grade+'" style="font-size:0.8rem">'+(a.score?a.score.toFixed(2):'?')+'</span></span>';
h+='<span class="story-title">'+a.target+' ('+a.type+')</span>';
h+='<span class="story-status">'+a.grade+'</span>';
h+='<span style="font-size:0.65rem;color:var(--muted)">'+a.date+'</span>';
h+='</div>';
h+='<div class="detail" id="detail-aud-'+i+'"><div class="d-meta">';
h+='<span>Checks: '+a.checks+'</span>';
h+='<span>C signals: '+a.c+'</span>';
h+='<span>D signals: '+a.d+'</span>';
h+='<span>Builder: '+(a.builder_vote||'-')+'</span>';
h+='<span>TARS: '+(a.tars_vote||'-')+'</span>';
h+='<span>Human: '+(a.human_vote||'-')+'</span>';
h+='</div>';
if(a.findings&&a.findings.length){
var dFindings=a.findings.filter(function(f){return f.signal==='D';});
var cFindings=a.findings.filter(function(f){return f.signal==='C';});
if(dFindings.length){
h+='<div style="margin-top:0.8rem"><div style="font-size:0.7rem;font-weight:700;color:var(--red);margin-bottom:0.4rem">DEFECTION SIGNALS ('+dFindings.length+')</div>';
dFindings.forEach(function(f){h+='<div style="font-size:0.75rem;padding:0.3rem 0;border-bottom:1px solid rgba(30,32,48,0.5)"><span style="color:var(--red);font-weight:600">D</span> <span style="color:var(--text)">'+f.check+'</span> <span style="color:var(--muted)">— '+f.desc+'</span></div>';});
h+='</div>';
}
if(cFindings.length){
h+='<div style="margin-top:0.8rem"><div style="font-size:0.7rem;font-weight:700;color:var(--green);margin-bottom:0.4rem">COOPERATION SIGNALS ('+cFindings.length+')</div>';
cFindings.slice(0,10).forEach(function(f){h+='<div style="font-size:0.75rem;padding:0.3rem 0;border-bottom:1px solid rgba(30,32,48,0.5)"><span style="color:var(--green);font-weight:600">C</span> <span style="color:var(--text)">'+f.check+'</span> <span style="color:var(--muted)">— '+f.desc+'</span></div>';});
if(cFindings.length>10) h+='<div style="font-size:0.7rem;color:var(--muted);padding:0.3rem 0">...and '+(cFindings.length-10)+' more</div>';
h+='</div>';
}
}
h+='</div>';
});
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No audit runs</div>';
document.getElementById('page-controls').classList.add('hidden');
}

function renderInitiatives(){
document.getElementById('filters').innerHTML='';
var inits=D.initiatives||[];
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">Initiatives — Level 7 Autonomous Research ('+inits.length+' total)</div>';
inits.forEach(function(init,i){
var statusColor=init.status==='COMPLETE'?'var(--green)':init.status==='RUNNING'?'var(--blue)':init.status==='FAILED'?'var(--red)':'var(--muted)';
h+='<div class="story-row" onclick="toggleDetail(this)" data-id="init-'+i+'">';
h+='<span class="story-id">'+init.id+'</span>';
h+='<span class="story-priority">'+init.priority+'</span>';
h+='<span class="story-title">'+init.title+'</span>';
h+='<span class="story-status" style="color:'+statusColor+'">'+init.status+'</span>';
h+='<span style="font-size:0.65rem;color:var(--muted)">'+(init.calls_used||0)+'/'+(init.max_calls||50)+' calls</span>';
h+='</div>';
h+='<div class="detail" id="detail-init-'+i+'"><div class="d-meta">';
h+='<span>Submitted: '+init.submitted+'</span>';
if(init.completed) h+='<span>Completed: '+init.completed+'</span>';
h+='</div>';
if(init.hypothesis) h+='<div style="margin:0.5rem 0;font-size:0.75rem"><strong>Hypothesis:</strong> '+init.hypothesis+'</div>';
if(init.result) h+='<div style="margin:0.5rem 0;font-size:0.75rem;color:var(--green);white-space:pre-wrap"><strong>Result:</strong> '+init.result+'</div>';
h+='</div>';
});
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No initiatives queued</div>';
document.getElementById('page-controls').classList.add('hidden');
}

function renderQA(){
document.getElementById('filters').innerHTML='';
var qa=D.qa||{};
var dash=qa.dashboard||{};
var runs=qa.runs||[];
var tests=qa.golden_tests||[];
var gateColor=dash.gate_status==='OPEN'?'var(--green)':'var(--red)';
var h='<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:1rem;margin-bottom:1.5rem">';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;text-align:center"><div style="font-size:1.8rem;font-weight:800;color:'+gateColor+'">'+(dash.gate_status||'—')+'</div><div style="font-size:0.65rem;color:var(--muted);text-transform:uppercase">Gate Status</div></div>';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;text-align:center"><div style="font-size:1.8rem;font-weight:800;color:var(--green)">'+(dash.golden_passed||0)+'/'+(dash.golden_total||0)+'</div><div style="font-size:0.65rem;color:var(--muted);text-transform:uppercase">Golden Tests</div></div>';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;text-align:center"><div style="font-size:1.8rem;font-weight:800;color:var(--blue)">'+(dash.canary_actions_24h||0)+'</div><div style="font-size:0.65rem;color:var(--muted);text-transform:uppercase">Canary Checks (24h)</div></div>';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;text-align:center"><div style="font-size:1.8rem;font-weight:800;color:var(--purple)">'+(dash.regression_from_bond||0)+'</div><div style="font-size:0.65rem;color:var(--muted);text-transform:uppercase">Bond Regressions</div></div>';
h+='</div>';
h+='<div style="margin-bottom:1.5rem"><div style="font-size:0.8rem;font-weight:700;color:var(--text);margin-bottom:0.8rem">Golden Test Cases</div>';
h+='<div class="story-row" style="font-weight:700;font-size:0.7rem;color:var(--muted);cursor:default"><span class="story-id">ID</span><span class="story-priority">SEV</span><span class="story-title">Description</span><span class="story-status">Result</span><span>Runs</span></div>';
tests.forEach(function(t){
var resColor=t.result==='PASS'?'var(--green)':'var(--red)';
h+='<div class="story-row" style="cursor:default"><span class="story-id">'+t.id+'</span><span class="story-priority sev-'+t.severity+'">'+t.severity+'</span><span class="story-title" style="font-size:0.75rem">'+t.desc+'</span><span class="story-status" style="color:'+resColor+'">'+t.result+'</span><span style="font-size:0.7rem;color:var(--muted)">'+t.runs+'</span></div>';});
h+='</div>';
h+='<div><div style="font-size:0.8rem;font-weight:700;color:var(--text);margin-bottom:0.8rem">Run History</div>';
h+='<div class="story-row" style="font-weight:700;font-size:0.7rem;color:var(--muted);cursor:default"><span class="story-id">Run</span><span class="story-priority">Gate</span><span class="story-title">Trigger</span><span class="story-status">Pass Rate</span><span>When</span></div>';
runs.forEach(function(r){
var gC=r.gate==='OPEN'?'var(--green)':'var(--red)';
h+='<div class="story-row" style="cursor:default"><span class="story-id">#'+r.id+'</span><span class="story-priority" style="color:'+gC+'">'+r.gate+'</span><span class="story-title" style="font-size:0.75rem">'+r.trigger+' ('+r.agent+')</span><span class="story-status" style="color:var(--green)">'+r.rate+'%</span><span style="font-size:0.65rem;color:var(--muted)">'+r.run_at+'</span></div>';});
if(!runs.length) h+='<div style="padding:1rem;color:var(--muted);font-size:0.8rem">No runs yet</div>';
h+='</div>';
document.getElementById('content').innerHTML=h;
document.getElementById('page-controls').classList.add('hidden');
}

function renderPagination(total){
var pages=Math.ceil(total/pageSize);
if(pages<=1){document.getElementById('page-controls').classList.add('hidden');return;}
var pc=document.getElementById('page-controls');
pc.classList.remove('hidden');
pc.innerHTML='<button onclick="currentPage--;render()" '+(currentPage===0?'disabled':'')+'>Prev</button><span>Page '+(currentPage+1)+' of '+pages+' ('+total+' items)</span><button onclick="currentPage++;render()" '+(currentPage>=pages-1?'disabled':'')+'>Next</button>';
}

function toggleDetail(el){
var idx=el.getAttribute('data-id');
var det=document.getElementById('detail-'+idx);
if(det) det.classList.toggle('open');
}

function escapeHtml(t){
if(!t) return '';
return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\\n/g,'<br>');
}

function renderSkills(){
document.getElementById('filters').innerHTML='<select onchange="skillFilter=this.value;renderSkills()"><option value="ALL">All Domains</option>'+[...new Set((D.skills||[]).map(function(s){return s.domain}))].sort().map(function(d){return '<option value="'+d+'"'+(skillFilter===d?' selected':'')+'>'+d+'</option>';}).join('')+'</select>';
var items=(D.skills||[]).filter(function(s){return skillFilter==='ALL'||s.domain===skillFilter;});
var domColors={healthcare:'var(--green)',devops:'var(--blue)',security:'var(--red)',platform:'var(--purple)','data-quality':'var(--amber)'};
var h='<div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem">';
items.forEach(function(s){
var dc=domColors[s.domain]||'var(--muted)';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;border-left:3px solid '+dc+'">';
h+='<div style="font-weight:700;margin-bottom:0.3rem">'+s.name+'</div>';
h+='<div style="display:flex;gap:0.4rem;margin-bottom:0.5rem"><span style="font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;background:rgba(41,181,232,0.1);color:'+dc+'">'+s.domain+'</span><span style="font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;background:rgba(136,136,160,0.1);color:var(--muted)">v'+s.version+'</span></div>';
h+='<div style="font-size:0.75rem;color:var(--muted);line-height:1.5">'+(s.description.length>120?s.description.substring(0,120)+'...':s.description)+'</div>';
h+='<div style="font-size:0.65rem;color:var(--muted);margin-top:0.5rem">'+s.author+'</div>';
h+='</div>';
});
h+='</div>';
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No skills in registry</div>';
document.getElementById('page-controls').classList.add('hidden');
}
var skillFilter='ALL';

function renderBondTab(){
document.getElementById('filters').innerHTML='<select onchange="bondFilter=this.value;renderBondTab()"><option value="ALL">All Categories</option>'+[...new Set((D.bond||[]).map(function(b){return b.category}))].sort().map(function(c){return '<option value="'+c+'"'+(bondFilter===c?' selected':'')+'>'+c+'</option>';}).join('')+'</select>'+'<select onchange="bondOriginFilter=this.value;renderBondTab()"><option value="ALL">All Origins</option><option value="co-created"'+(bondOriginFilter==='co-created'?' selected':'')+'>Co-created</option><option value="human"'+(bondOriginFilter==='human'?' selected':'')+'>Human</option><option value="autonomous"'+(bondOriginFilter==='autonomous'?' selected':'')+'>Autonomous</option></select>';
var items=(D.bond||[]).filter(function(b){return (bondFilter==='ALL'||b.category===bondFilter)&&(bondOriginFilter==='ALL'||b.origin===bondOriginFilter);});
var originColors={'co-created':'var(--purple)',human:'var(--green)',autonomous:'var(--amber)',coco:'var(--blue)'};
var h='<div style="margin-bottom:1rem;font-size:0.8rem;color:var(--muted)">Memory Entries ('+items.length+' shown)</div>';
items.forEach(function(b,i){
var oc=originColors[b.origin]||'var(--muted)';
h+='<div class="story-row" onclick="toggleDetail(this)" data-id="bond-'+i+'">';
h+='<span class="story-id" style="font-size:0.6rem">'+b.category+'</span>';
h+='<span class="story-priority" style="color:'+oc+';font-size:0.65rem">'+b.origin+'</span>';
h+='<span class="story-title" style="font-size:0.8rem">'+b.key+'</span>';
h+='<span class="story-status" style="font-size:0.6rem;color:var(--muted)">'+b.insight_type+'</span>';
h+='<span style="font-size:0.6rem;color:var(--muted)">'+b.created+'</span>';
h+='</div>';
h+='<div class="detail" id="detail-bond-'+i+'">';
if(b.tags&&b.tags.length){h+='<div style="margin-bottom:0.5rem">'+b.tags.map(function(t){return '<span style="display:inline-block;padding:0.1rem 0.4rem;margin:0.1rem;border-radius:3px;font-size:0.6rem;background:rgba(167,139,250,0.1);color:var(--purple)">'+t+'</span>';}).join('')+'</div>';}
h+='<div style="font-size:0.75rem;color:var(--muted)">Agent: '+b.agent+' | ID: '+b.id+'</div>';
h+='</div>';
});
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No bond entries</div>';
document.getElementById('page-controls').classList.add('hidden');
}
var bondFilter='ALL',bondOriginFilter='ALL';

function renderNarratives(){
document.getElementById('filters').innerHTML='<select onchange="narrFilter=this.value;renderNarratives()"><option value="ALL">All Types</option><option value="presentation"'+(narrFilter==='presentation'?' selected':'')+'>Presentations</option><option value="visualization"'+(narrFilter==='visualization'?' selected':'')+'>Visualizations</option><option value="hero"'+(narrFilter==='hero'?' selected':'')+'>Hero Pages</option></select>';
var items=(D.narratives||[]).filter(function(n){return narrFilter==='ALL'||n.type===narrFilter;});
var typeColors={presentation:'var(--blue)',visualization:'var(--purple)',hero:'var(--green)'};
var h='<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:1rem">';
items.forEach(function(n){
var tc=typeColors[n.type]||'var(--muted)';
h+='<div style="background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1rem;border-top:3px solid '+tc+'">';
h+='<div style="font-weight:700;margin-bottom:0.3rem;font-size:0.9rem">'+n.title+'</div>';
h+='<div style="display:flex;gap:0.4rem;margin-bottom:0.5rem;flex-wrap:wrap"><span style="font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;background:rgba(41,181,232,0.1);color:'+tc+'">'+n.type+'</span>';
if(n.product_id) h+='<span style="font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;background:rgba(136,136,160,0.1);color:var(--muted)">'+n.product_id+'</span>';
h+='<span style="font-size:0.65rem;padding:0.15rem 0.4rem;border-radius:3px;background:rgba(136,136,160,0.1);color:var(--muted)">v'+n.version+'</span></div>';
if(n.description) h+='<div style="font-size:0.75rem;color:var(--muted);line-height:1.5;margin-bottom:0.5rem">'+(n.description.length>100?n.description.substring(0,100)+'...':n.description)+'</div>';
if(n.file_path) h+='<div style="font-size:0.6rem;font-family:monospace;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+n.file_path+'</div>';
h+='<div style="font-size:0.6rem;color:var(--muted);margin-top:0.4rem">'+n.created+'</div>';
h+='</div>';
});
h+='</div>';
document.getElementById('content').innerHTML=h||'<div style="padding:2rem;color:var(--muted)">No narratives registered</div>';
document.getElementById('page-controls').classList.add('hidden');
}
var narrFilter='ALL';

renderKPIs();
document.querySelectorAll('#tabs .tab').forEach(function(b){b.classList.remove('active');if(b.getAttribute('onclick')&&b.getAttribute('onclick').indexOf(currentTab)!==-1)b.classList.add('active');});
switchGlobal(currentGlobal);
render();
</script>
</body>
</html>"""


def render():
    print("  Querying GUPPI database...")
    data = query_guppi()
    print(f"  Retrieved: {data['summary']['total']} stories, {len(data['incidents'])} incidents, {len(data['audits'])} audits")

    html = HTML_TEMPLATE.replace("__DATA__", json.dumps(data, default=str))

    with open(OUTPUT_PATH, 'w') as f:
        f.write(html)
    print(f"  Written: {OUTPUT_PATH} ({len(html)//1024}KB)")
    return OUTPUT_PATH


if __name__ == "__main__":
    import sys
    if "--serve" in sys.argv:
        from flask import Flask, jsonify, send_file
        fapp = Flask(__name__)

        @fapp.route("/")
        def index():
            path = render()
            return send_file(path, mimetype="text/html")

        @fapp.route("/api/data")
        def api_data():
            data = query_guppi()
            return jsonify(data)

        @fapp.route("/api/launch/<artifact_id>")
        def api_launch(artifact_id):
            import snowflake.connector as sc
            conn = sc.connect(connection_name=os.getenv("SNOWFLAKE_CONNECTION_NAME") or "HealthcareDemos")
            try:
                cur = conn.cursor()
                cur.execute("CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH(%s, %s)", (artifact_id, 3600))
                row = cur.fetchone()
                if row is None:
                    return jsonify({"error": "no result"}), 500
                # Result is VARIANT — Snowflake connector returns it as str
                import json as _json
                payload = row[0]
                if isinstance(payload, str):
                    try:
                        payload = _json.loads(payload)
                    except Exception:
                        pass
                return jsonify(payload)
            finally:
                cur.close()
                conn.close()

        port = 8888
        print(f"GUPPI Viewer — Serving on http://localhost:{port}")
        print("  Refresh button in the UI will pull live data from Snowflake.")
        fapp.run(host="0.0.0.0", port=port, debug=False)
    else:
        print("GUPPI Viewer — Rendering...")
        path = render()
        if "--open" in sys.argv:
            import webbrowser
            webbrowser.open(f"file://{path}")
        print("  Done.")
