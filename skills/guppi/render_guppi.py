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

    cur.execute("SELECT PRODUCT_ID, NAME, DESCRIPTION, STATUS FROM GUPPI.PLATFORM.PRODUCTS ORDER BY NAME")
    products = [{"id": r[0], "name": r[1], "description": r[2], "status": r[3]} for r in cur.fetchall()]

    cur.execute("SELECT EPIC_ID, PRODUCT_ID, NAME, DESCRIPTION, STATUS FROM GUPPI.PLATFORM.EPICS ORDER BY SORT_ORDER, NAME")
    epics = [{"id": r[0], "product_id": r[1], "name": r[2], "description": r[3], "status": r[4]} for r in cur.fetchall()]

    cur.execute("""
        SELECT s.STORY_ID, s.EPIC_ID, s.TITLE, s.DESCRIPTION, s.PRIORITY, s.STATUS, 
               s.STORY_POINTS, s.ASSIGNEE, s.SPRINT,
               TO_VARCHAR(s.CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(s.UPDATED_AT, 'YYYY-MM-DD'),
               e.PRODUCT_ID
        FROM GUPPI.PLATFORM.STORIES s
        JOIN GUPPI.PLATFORM.EPICS e ON s.EPIC_ID = e.EPIC_ID
        ORDER BY s.PRIORITY, s.STORY_ID
    """)
    stories = []
    for r in cur.fetchall():
        stories.append({
            "id": r[0], "epic_id": r[1], "title": r[2], "description": r[3] or "",
            "priority": r[4], "status": r[5], "type": "STORY",
            "points": r[6], "assignee": r[7], "sprint": r[8],
            "created": r[9], "updated": r[10], "product_id": r[11]
        })

    cur.execute("""
        SELECT d.DEFECT_ID, d.EPIC_ID, d.TITLE, d.DESCRIPTION, d.SEVERITY, d.PRIORITY, d.STATUS,
               d.FOUND_IN_VERSION, d.FIXED_IN_VERSION, d.REPRODUCTION_STEPS, d.REPORTED_BY,
               d.RELATED_STORY_ID, d.RELATED_INCIDENT_ID, d.REOPEN_COUNT,
               TO_VARCHAR(d.CREATED_AT, 'YYYY-MM-DD'), TO_VARCHAR(d.UPDATED_AT, 'YYYY-MM-DD'),
               e.PRODUCT_ID
        FROM GUPPI.PLATFORM.DEFECTS d
        JOIN GUPPI.PLATFORM.EPICS e ON d.EPIC_ID = e.EPIC_ID
        ORDER BY d.SEVERITY, d.PRIORITY
    """)
    defects = []
    for r in cur.fetchall():
        defects.append({
            "id": r[0], "epic_id": r[1], "title": r[2], "description": r[3] or "",
            "severity": r[4], "priority": r[5], "status": r[6],
            "found_in": r[7], "fixed_in": r[8], "repro": r[9],
            "reported_by": r[10], "related_story": r[11], "related_incident": r[12],
            "reopen_count": r[13], "created": r[14], "updated": r[15], "product_id": r[16]
        })

    cur.execute("""
        SELECT INCIDENT_ID, PRODUCT_ID, SEVERITY, STATUS, TITLE, DESCRIPTION,
               TO_VARCHAR(DETECTED_AT, 'YYYY-MM-DD HH24:MI'), 
               TO_VARCHAR(MITIGATED_AT, 'YYYY-MM-DD HH24:MI'),
               TO_VARCHAR(RESOLVED_AT, 'YYYY-MM-DD HH24:MI'),
               TIME_TO_DETECT_MIN, TIME_TO_MITIGATE_MIN, TIME_TO_RESOLVE_MIN,
               ROOT_CAUSE, PREVENTIVE_ACTION, DETECTED_BY
        FROM GUPPI.PLATFORM.INCIDENTS ORDER BY DETECTED_AT DESC
    """)
    incidents = []
    for r in cur.fetchall():
        incidents.append({
            "id": r[0], "product_id": r[1], "severity": r[2], "status": r[3],
            "title": r[4], "description": r[5] or "",
            "detected_at": r[6], "mitigated_at": r[7], "resolved_at": r[8],
            "ttd": r[9], "ttm": r[10], "ttr": r[11],
            "root_cause": r[12], "preventive": r[13], "detected_by": r[14]
        })

    cur.execute("""
        SELECT AUDIT_ID, TARGET_NAME, TARGET_TYPE, 
               TO_VARCHAR(AUDIT_DATE, 'YYYY-MM-DD HH24:MI'),
               TRUST_SCORE, GRADE, C_SIGNALS, D_SIGNALS, TOTAL_CHECKS,
               BUILDER_VOTE, TARS_VOTE, HUMAN_VOTE, STATUS
        FROM GUPPI.PLATFORM.AUDIT_RUNS ORDER BY AUDIT_DATE DESC
    """)
    audits = []
    for r in cur.fetchall():
        audits.append({
            "id": r[0], "target": r[1], "type": r[2], "date": r[3],
            "score": r[4], "grade": r[5], "c": r[6], "d": r[7], "checks": r[8],
            "builder_vote": r[9], "tars_vote": r[10], "human_vote": r[11], "status": r[12]
        })

    cur.execute("""
        SELECT AUDIT_ID, CHECK_NAME, SIGNAL, WEIGHT, DESCRIPTION, EVIDENCE
        FROM GUPPI.PLATFORM.AUDIT_FINDINGS
        ORDER BY AUDIT_ID, SIGNAL DESC, WEIGHT DESC
    """)
    findings_by_audit = {}
    for r in cur.fetchall():
        aid = r[0]
        if aid not in findings_by_audit:
            findings_by_audit[aid] = []
        findings_by_audit[aid].append({
            "check": r[1], "signal": r[2], "weight": r[3],
            "desc": r[4] or "", "evidence": r[5] or ""
        })

    for a in audits:
        a["findings"] = findings_by_audit.get(a["id"], [])

    cur.execute("""
        SELECT * FROM GUPPI.PLATFORM.QA_DASHBOARD
    """)
    qa_row = cur.fetchone()
    qa_dashboard = {}
    if qa_row:
        qa_dashboard = {
            "gate_status": qa_row[0], "golden_total": qa_row[1],
            "golden_passed": qa_row[2], "golden_failed": qa_row[3],
            "golden_last_run": str(qa_row[4]) if qa_row[4] else None,
            "canary_actions_24h": qa_row[5], "canary_passed": qa_row[6],
            "canary_failed": qa_row[7], "regression_from_bond": qa_row[8],
            "runs_7d": qa_row[9], "runs_open": qa_row[10], "runs_blocked": qa_row[11]
        }

    cur.execute("""
        SELECT RUN_ID, RUN_TYPE, AGENT, TOTAL_TESTS, PASSED, FAILED, PASS_RATE, 
               GATE_STATUS, TRIGGER_SOURCE, DURATION_MS, 
               TO_VARCHAR(RUN_AT, 'YYYY-MM-DD HH24:MI')
        FROM GUPPI.PLATFORM.QA_RUNS
        ORDER BY RUN_AT DESC
        LIMIT 25
    """)
    qa_runs = []
    for r in cur.fetchall():
        qa_runs.append({
            "id": r[0], "type": r[1], "agent": r[2], "total": r[3],
            "passed": r[4], "failed": r[5], "rate": float(r[6]) if r[6] else 0,
            "gate": r[7], "trigger": r[8], "duration": r[9], "run_at": r[10]
        })

    cur.execute("""
        SELECT TEST_ID, DESCRIPTION, EDGE_CASE_TYPE, SEVERITY, LAST_RUN_RESULT, RUN_COUNT,
               TO_VARCHAR(LAST_RUN_AT, 'YYYY-MM-DD HH24:MI')
        FROM NCPDP_F6.PUBLIC.GOLDEN_TEST_CASES
        WHERE ACTIVE = TRUE
        ORDER BY SEVERITY DESC, TEST_ID
    """)
    golden_tests = []
    for r in cur.fetchall():
        golden_tests.append({
            "id": r[0], "desc": r[1], "type": r[2], "severity": r[3],
            "result": r[4], "runs": r[5], "last_run": r[6]
        })

    cur.execute("""
        SELECT INITIATIVE_ID, TITLE, HYPOTHESIS, STATUS, PRIORITY,
               MAX_CALLS, CALLS_USED,
               TO_VARCHAR(SUBMITTED_AT, 'YYYY-MM-DD HH24:MI'),
               TO_VARCHAR(COMPLETED_AT, 'YYYY-MM-DD HH24:MI'),
               RESULT
        FROM GUPPI.PLATFORM.INITIATIVES
        ORDER BY SUBMITTED_AT DESC
    """)
    initiatives = []
    for r in cur.fetchall():
        initiatives.append({
            "id": r[0], "title": r[1], "hypothesis": r[2] or "", "status": r[3],
            "priority": r[4], "max_calls": r[5], "calls_used": r[6],
            "submitted": r[7], "completed": r[8], "result": r[9] or ""
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
        SELECT NARRATIVE_ID, TITLE, NARRATIVE_TYPE, DESCRIPTION, PRODUCT_ID, TAGS, VERSION,
               FILE_PATH, TO_VARCHAR(CREATED_AT, 'YYYY-MM-DD')
        FROM NARRATIVE_REGISTRY.PUBLIC.NARRATIVES
        ORDER BY CREATED_AT DESC
    """)
    narratives = []
    for r in cur.fetchall():
        tags = r[5] if r[5] else []
        narratives.append({
            "id": r[0], "title": r[1], "type": r[2], "description": r[3] or "",
            "product_id": r[4] or "", "tags": tags, "version": r[6] or "1.0.0",
            "file_path": r[7] or "", "created": r[8] or ""
        })

    cur.close()
    conn.close()

    done = sum(1 for s in stories if s["status"] == "DONE")
    in_prog = sum(1 for s in stories if s["status"] == "IN_PROGRESS")
    backlog = sum(1 for s in stories if s["status"] in ("BACKLOG", "PLANNED"))
    defects_open = sum(1 for d in defects if d["status"] not in ("CLOSED", "VERIFIED"))

    return {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M"),
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
<title>GUPPI — Platform Command Center</title>
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
</style>
</head>
<body>
<div class="header-row">
<div class="header-left">
<h1>GUPPI — <span>Platform Command Center</span></h1>
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

<script id="guppi-data" type="application/json">__DATA__</script>
<script>
var D=JSON.parse(document.getElementById('guppi-data').textContent);
var currentTab=localStorage.getItem('guppi-tab')||'backlog',currentPage=0,pageSize=50;
var filters={product:'ALL',status:'ALL',search:''};

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
document.querySelectorAll('.tab').forEach(function(b){b.classList.remove('active');if(b.getAttribute('onclick')&&b.getAttribute('onclick').indexOf(currentTab)!==-1)b.classList.add('active');});
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

        port = 8888
        print(f"GUPPI Viewer — Serving on http://localhost:{port}")
        print("  Refresh button in the UI will pull live data from Snowflake.")
        import webbrowser
        webbrowser.open(f"http://localhost:{port}")
        fapp.run(host="0.0.0.0", port=port, debug=False)
    else:
        print("GUPPI Viewer — Rendering...")
        path = render()
        if "--open" in sys.argv:
            import webbrowser
            webbrowser.open(f"file://{path}")
        print("  Done.")
