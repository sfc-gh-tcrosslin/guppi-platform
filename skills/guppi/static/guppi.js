/* GUPPI Viewer — client. Vanilla JS, no deps.
   Data: window.__SNAPSHOT__ (read-only file) or GET /api/data (serve mode). */
(function () {
  "use strict";
  var DATA = null;
  var LIVE = !window.__SNAPSHOT__; // serve mode has live endpoints
  var byId = {};                    // flywheel artifact index
  var childrenOf = {};              // parent_id -> [artifact,...]

  function $(sel, root) { return (root || document).querySelector(sel); }
  function el(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
  function esc(s) { return (s == null ? "" : String(s)).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  var LAUNCHABLE = { NARRATIVE: 1, APP: 1, MODEL: 1, DASHBOARD: 1 };

  function index() {
    byId = {}; childrenOf = {};
    (DATA.flywheel || []).forEach(function (a) {
      byId[a.id] = a;
      var p = a.parent_id || "";
      (childrenOf[p] = childrenOf[p] || []).push(a);
    });
  }

  /* ---------- bootstrap ---------- */
  function boot(data) {
    DATA = data; index();
    $("#gen-time").textContent = DATA.generated_at || "—";
    $("#cur-user").textContent = DATA.current_user || "—";
    populateProducts();
    renderKPIs(); renderCommandProducts(); renderClassic("stories"); renderAILC();
  }
  function populateProducts() {
    var sel = $("#f-product"); if (!sel) return;
    var cur = sel.value;
    sel.innerHTML = '<option value="">— none —</option>' + (DATA.products || []).map(function (p) {
      return '<option value="' + esc(p.id) + '">' + esc(p.name || p.id) + " (" + esc(p.id) + ")</option>";
    }).join("");
    if (cur) sel.value = cur;
  }
  function load() {
    if (window.__SNAPSHOT__) { boot(window.__SNAPSHOT__); return; }
    fetch("/api/data").then(function (r) { return r.json(); }).then(boot)
      .catch(function (e) { document.body.insertBefore(el("div", "section-note", "Failed to load data: " + esc(e)), document.body.firstChild); });
  }

  /* ---------- Command Center ---------- */
  function kpi(val, lbl) { return '<div class="kpi"><div class="val">' + esc(val) + '</div><div class="lbl">' + esc(lbl) + '</div></div>'; }
  function renderKPIs() {
    var s = DATA.summary || {};
    $("#kpis").innerHTML = [
      kpi(s.initiatives || 0, "Initiatives"), kpi((DATA.flywheel || []).length, "Artifacts"),
      kpi(s.narratives || 0, "Narratives"), kpi(s.audits || 0, "Audits"),
      kpi(s.total || 0, "Stories"), kpi(s.defects_open || 0, "Defects Open"),
      kpi(s.incidents_open || 0, "Incidents"), kpi(s.products || 0, "Products"),
      kpi(s.skills || 0, "Skills"), kpi(s.bond || 0, "Bond")
    ].join("");
  }
  function renderCommandProducts() {
    var host = $("#command-products"); host.innerHTML = "";
    var counts = {};
    (DATA.flywheel || []).forEach(function (a) { counts[a.type] = (counts[a.type] || 0) + 1; });
    var wrap = el("div", "card");
    wrap.appendChild(el("div", "d-sec", "Wheel by type"));
    var kv = el("div", "d-kv");
    Object.keys(counts).sort().forEach(function (t) {
      kv.appendChild(el("span", "k", '<span class="chip t-' + esc(t) + '">' + esc(t) + "</span>"));
      kv.appendChild(el("span", null, String(counts[t])));
    });
    wrap.appendChild(kv); host.appendChild(wrap);
  }

  /* ---------- Classic (SDLC) ---------- */
  function statusCell(st) { return '<span class="status st-' + esc(st) + '">' + esc(st) + "</span>"; }
  function rowsTable(items, cols) {
    if (!items.length) return '<div class="empty">Nothing here.</div>';
    return items.map(function (it) {
      return '<div class="row" data-id="' + esc(it.id) + '">' + cols(it) + "</div>";
    }).join("");
  }
  function renderClassic(sub) {
    var host = $("#classic-body");
    if (sub === "stories") {
      host.innerHTML = rowsTable(DATA.stories || [], function (s) {
        return '<span class="mono">' + esc(s.id) + '</span><span class="pri pri-' + esc(s.priority) + '">' + esc(s.priority) +
          '</span><span>' + esc(s.title) + '</span>' + statusCell(s.status) + '<span class="mono">' + esc(s.points || "") + "</span>";
      });
    } else if (sub === "defects") {
      host.innerHTML = rowsTable(DATA.defects || [], function (d) {
        return '<span class="mono">' + esc(d.id) + '</span><span class="pri pri-' + esc(d.severity) + '">' + esc(d.severity) +
          '</span><span>' + esc(d.title) + '</span>' + statusCell(d.status) + '<span class="mono">' + esc(d.fixed_in || "") + "</span>";
      });
    } else if (sub === "incidents") {
      host.innerHTML = (DATA.incidents || []).map(function (i) {
        return '<div class="card" data-id="' + esc(i.id) + '"><div class="c-head"><span class="c-title">' + esc(i.title) +
          '</span><span class="sev-' + esc(i.severity) + '">' + esc(i.severity) + " · " + esc(i.status) + '</span></div><div class="meta">' +
          esc(i.detected_at || "") + '</div><div style="font-size:.8rem;margin-top:.4rem">' + esc(i.description) + "</div></div>";
      }).join("") || '<div class="empty">No incidents.</div>';
    } else if (sub === "audits") {
      host.innerHTML = (DATA.audits || []).map(function (a) {
        return '<div class="row" data-id="' + esc(a.id) + '"><span class="mono">' + esc(a.id) + '</span><span class="pri">' +
          esc(a.grade || "") + '</span><span>' + esc(a.target) + '</span>' + statusCell((a.status || "").toUpperCase() || "OPEN") +
          '<span class="mono">' + (a.score != null ? esc(a.score) : "") + "</span></div>";
      }).join("") || '<div class="empty">No audits.</div>';
    } else if (sub === "skills") {
      host.innerHTML = (DATA.skills || []).map(function (k) {
        return '<div class="row"><span class="mono">' + esc(k.domain) + '</span><span></span><span>' + esc(k.name) +
          '</span><span class="mono">v' + esc(k.version) + '</span><span class="mono">' + esc(k.author) + "</span></div>";
      }).join("") || '<div class="empty">No skills.</div>';
    }
  }

  /* ---------- AILC (initiatives -> tree -> detail) ---------- */
  function renderAILC() {
    var host = $("#ailc-body"); host.innerHTML = "";
    var inits = (DATA.flywheel || []).filter(function (a) { return a.type === "INITIATIVE"; });
    if (!inits.length) { host.innerHTML = '<div class="empty">No initiatives.</div>'; return; }
    var UNASSIGNED = "\u2014 unassigned / discovery";
    var byProd = {};
    inits.forEach(function (it) { var p = it.product_id || UNASSIGNED; (byProd[p] = byProd[p] || []).push(it); });
    var prodName = {}; (DATA.products || []).forEach(function (p) { prodName[p.id] = p.name || p.id; });
    var keys = Object.keys(byProd).sort(function (a, b) {
      if (a === UNASSIGNED) return 1; if (b === UNASSIGNED) return -1;
      return byProd[b].length - byProd[a].length || (a < b ? -1 : 1);
    });
    keys.forEach(function (pid) {
      var label = (pid === UNASSIGNED) ? pid : (prodName[pid] || pid);
      var pbox = el("div", "prod");
      var phead = el("div", "prod-head");
      phead.innerHTML = '<span class="twisty">&#9656;</span><span class="prod-title">' + esc(label) +
        '</span><span class="mono kidcount">' + byProd[pid].length + " init</span>";
      var pbody = el("div", "prod-body");
      phead.addEventListener("click", function () { pbox.classList.toggle("open"); });
      byProd[pid].forEach(function (it) { pbody.appendChild(initBox(it)); });
      pbox.appendChild(phead); pbox.appendChild(pbody); host.appendChild(pbox);
    });
  }
  function initBox(it) {
    var box = el("div", "init"); box.dataset.id = it.id;
    var head = el("div", "init-head");
    var kidCount = (childrenOf[it.id] || []).length;
    head.innerHTML = '<span class="twisty">&#9656;</span><span class="chip stage-' + esc(it.stage) + ' stage">' + esc(it.stage) +
      '</span><span class="init-title">' + esc(it.title) + '</span>' +
      (kidCount ? '<span class="mono kidcount">' + kidCount + ' \u25be</span>' : '') +
      '<span class="mono">' + esc(it.id) + "</span>";
    var tree = el("div", "tree");
    head.addEventListener("click", function (ev) {
      if (ev.target.classList.contains("mono") && ev.altKey) { openDetail(it.id); return; }
      box.classList.toggle("open");
      if (box.classList.contains("open") && !tree.dataset.built) { buildTree(tree, it.id); tree.dataset.built = "1"; }
    });
    box.appendChild(head); box.appendChild(tree); return box;
  }
  function buildTree(container, parentId, depth) {
    depth = depth || 0;
    var kids = (childrenOf[parentId] || []).slice().sort(function (a, b) { return (a.type > b.type) ? 1 : -1; });
    // Also show the initiative's own detail entry at top
    if (depth === 0) {
      container.appendChild(nodeEl(byId[parentId], "self"));
    }
    if (!kids.length && depth === 0) { container.appendChild(el("div", "empty", "No children yet — Rocky may still be researching.")); return; }
    kids.forEach(function (k) {
      container.appendChild(nodeEl(k));
      var grand = childrenOf[k.id] || [];
      if (grand.length) {
        var sub = el("div"); sub.style.marginLeft = "1.1rem";
        buildTree(sub, k.id, depth + 1); container.appendChild(sub);
      }
    });
  }
  function nodeEl(a, kind) {
    if (!a) return el("div", "empty", "(missing)");
    var n = el("div", "node"); n.dataset.id = a.id;
    n.innerHTML = '<span class="chip t-' + esc(a.type) + '">' + esc(a.type) + '</span><span class="node-title">' +
      (kind === "self" ? "<b>" + esc(a.title) + "</b>" : esc(a.title)) + '</span><span class="mono">' + esc(a.id) + "</span>";
    n.addEventListener("click", function (ev) { ev.stopPropagation(); openDetail(a.id); });
    return n;
  }

  /* ---------- Detail drawer ---------- */
  function openDrawer() { $("#drawer").classList.add("open"); $("#drawer-scrim").classList.add("open"); }
  function closeDrawer() { $("#drawer").classList.remove("open"); $("#drawer-scrim").classList.remove("open"); }
  function openDetail(id) {
    openDrawer();
    $("#drawer-title").textContent = id;
    $("#drawer-body").innerHTML = '<div class="empty">Loading…</div>';
    if (LIVE) {
      fetch("/api/artifact/" + encodeURIComponent(id)).then(function (r) { return r.json(); })
        .then(function (a) { if (a && !a.error) renderDetail(a); else renderDetailFallback(id); })
        .catch(function () { renderDetailFallback(id); });
    } else { renderDetailFallback(id); }
  }
  function renderDetailFallback(id) {
    // Snapshot mode: build from the flywheel record (no full CONTENT available).
    var a = byId[id];
    if (!a) { $("#drawer-body").innerHTML = '<div class="empty">No detail for ' + esc(id) + " (snapshot mode).</div>"; return; }
    renderDetail({ id: a.id, type: a.type, title: a.title, stage: a.stage, owner: a.owner, parent_id: a.parent_id,
      tags: a.tags, metadata: a.metadata, content: null, created: a.created, updated: a.updated,
      parent: a.parent_id ? { id: a.parent_id, type: (byId[a.parent_id] || {}).type, title: (byId[a.parent_id] || {}).title } : null,
      children: (childrenOf[id] || []).map(function (c) { return { id: c.id, type: c.type, title: c.title, stage: c.stage }; }),
      _snapshot: true });
  }
  function renderDetail(a) {
    $("#drawer-title").innerHTML = '<span class="chip t-' + esc(a.type) + '">' + esc(a.type) + "</span> " + esc(a.title);
    var h = [];
    h.push('<div class="d-row"><span class="chip stage stage-' + esc(a.stage) + '">' + esc(a.stage) + '</span><span class="mono">' + esc(a.id) + "</span>");
    if (a.owner) h.push('<span class="mono">' + esc(a.owner) + "</span>");
    h.push("</div>");
    if (LAUNCHABLE[a.type] || (a.metadata && a.metadata.launch)) {
      h.push('<div class="launch-row"><button class="btn primary" id="open-launch" data-id="' + esc(a.id) + '">Open &#8595;</button>' +
             '<button class="btn ghost" id="share-launch" data-id="' + esc(a.id) + '">Share externally &#8599;</button></div>');
    }
    // lineage
    h.push('<div class="d-sec">Lineage</div>');
    if (a.parent) h.push('<span class="link-chip" data-open="' + esc(a.parent.id) + '">&#8593; ' + esc(a.parent.type || "") + " " + esc(a.parent.id) + "</span>");
    if (a.children && a.children.length) {
      a.children.forEach(function (c) { h.push('<span class="link-chip" data-open="' + esc(c.id) + '">&#8595; ' + esc(c.type) + " " + esc(c.title).slice(0, 40) + "</span>"); });
    }
    if (!a.parent && !(a.children && a.children.length)) h.push('<div class="empty">No linked artifacts.</div>');
    // key fields
    h.push('<div class="d-sec">Fields</div><div class="d-kv">');
    h.push('<span class="k">Created</span><span>' + esc(a.created || "—") + "</span>");
    h.push('<span class="k">Updated</span><span>' + esc(a.updated || "—") + "</span>");
    if (a.product_id) h.push('<span class="k">Product</span><span>' + esc(a.product_id) + "</span>");
    if (a.tags && a.tags.length) h.push('<span class="k">Tags</span><span>' + esc((a.tags || []).join(", ")) + "</span>");
    if (a.superseded_by) h.push('<span class="k">Superseded by</span><span>' + esc(a.superseded_by) + "</span>");
    h.push("</div>");
    // content
    if (a._snapshot) {
      h.push('<div class="d-sec">Content</div><div class="empty">Full CONTENT available in serve mode (this is a read-only snapshot).</div>');
    } else {
      h.push('<div class="d-sec">Content</div><pre class="code">' + esc(pretty(a.content)) + "</pre>");
      h.push('<div class="d-sec">Metadata</div><pre class="code">' + esc(pretty(a.metadata)) + "</pre>");
    }
    $("#drawer-body").innerHTML = h.join("");
    var ob = $("#open-launch"); if (ob) ob.addEventListener("click", function () { openLocal(ob.dataset.id); });
    var sb = $("#share-launch"); if (sb) sb.addEventListener("click", function () { shareExternal(sb.dataset.id); });
    Array.prototype.forEach.call($("#drawer-body").querySelectorAll(".link-chip"), function (c) {
      c.addEventListener("click", function () { openDetail(c.dataset.open); });
    });
  }
  function pretty(v) { if (v == null) return "—"; try { return JSON.stringify(v, null, 2); } catch (e) { return String(v); } }
  function toast(msg, ms) {
    var t = document.getElementById("guppi-toast");
    if (!t) { t = document.createElement("div"); t.id = "guppi-toast"; document.body.appendChild(t); }
    t.textContent = msg; t.classList.add("show");
    clearTimeout(t._timer); t._timer = setTimeout(function () { t.classList.remove("show"); }, ms || 4000);
  }
  // DEFAULT: download the staged file locally and open it (no presigned URL).
  function openLocal(id) {
    if (!LIVE) { alert("Open requires serve mode."); return; }
    toast("Opening locally…");
    fetch("/api/open/" + encodeURIComponent(id)).then(function (r) { return r.json(); }).then(function (p) {
      if (p && p.opened) toast("Opened locally: " + p.opened, 6000);
      else if (p && p.url) { window.open(p.url, "_blank"); toast("Opened."); }
      else toast("Open failed: " + JSON.stringify(p), 7000);
    }).catch(function (e) { toast("Open failed: " + e, 7000); });
  }
  // EXPLICIT: mint a presigned URL and copy it to the clipboard for external sharing.
  function shareExternal(id) {
    if (!LIVE) { alert("Share requires serve mode."); return; }
    toast("Minting share link…");
    fetch("/api/share/" + encodeURIComponent(id)).then(function (r) { return r.json(); }).then(function (p) {
      var url = p && (p.url || p.presigned_url || (p.launch && p.launch.url));
      if (!url) { toast("No shareable URL: " + JSON.stringify(p), 7000); return; }
      var ttl = (p && p.expires_in_seconds) ? Math.round(p.expires_in_seconds / 3600) + "h" : "~24h";
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(url).then(
          function () { toast("Presigned link copied — expires in " + ttl, 6000); },
          function () { window.prompt("Copy this presigned link (expires in " + ttl + "):", url); }
        );
      } else {
        window.prompt("Copy this presigned link (expires in " + ttl + "):", url);
      }
    }).catch(function (e) { toast("Share failed: " + e, 7000); });
  }

  /* ---------- Add Artifact ---------- */
  function openModal() { $("#add-modal").classList.add("open"); $("#modal-scrim").classList.add("open"); syncAddFields(); }
  function closeModal() { $("#add-modal").classList.remove("open"); $("#modal-scrim").classList.remove("open"); $("#add-result").textContent = ""; }
  function syncAddFields() {
    var t = $("#f-type").value;
    var isInit = (t === "INITIATIVE");
    $("#wrap-hypothesis").style.display = isInit ? "" : "none";
    $("#wrap-instructions").style.display = isInit ? "" : "none";
    $("#wrap-description").style.display = isInit ? "none" : "";
    $("#wrap-parent").style.display = isInit ? "none" : "";
    $("#wrap-stage").style.display = isInit ? "none" : "";
  }
  function submitAdd() {
    var t = $("#f-type").value;
    var payload = { type: t, title: $("#f-title").value.trim(), product: $("#f-product").value.trim(),
      tags: $("#f-tags").value.trim() };
    if (t === "INITIATIVE") { payload.hypothesis = $("#f-hypothesis").value.trim(); payload.instructions = $("#f-instructions").value.trim(); }
    else { payload.description = $("#f-description").value.trim(); payload.parent_id = $("#f-parent").value.trim(); payload.stage = $("#f-stage").value; }
    if (!payload.title) { setResult("Title is required.", true); return; }
    if (!LIVE) { setResult("Add requires serve mode (python render_guppi.py --serve).", true); return; }
    setResult("Writing through the wheel…", false);
    fetch("/api/artifact", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) })
      .then(function (r) { return r.json(); }).then(function (res) {
        if (res.error) { setResult("Error: " + res.error, true); return; }
        var msg = typeof res.result === "string" ? res.result : JSON.stringify(res.result);
        var newId = extractId(res.result);
        setResult("Created via " + esc(res.via) + " — " + esc(msg), false);
        refresh().then(function () { if (newId) openDetail(newId); setTimeout(closeModal, 1200); });
      }).catch(function (e) { setResult("Request failed: " + e, true); });
  }
  function extractId(result) {
    if (result && typeof result === "object" && result.artifact_id) return result.artifact_id;
    if (typeof result === "string") { var m = result.match(/\b(INIT|RES|STORY|EPIC|NAR|APP|MODEL|AUD|DEF|INC|OUT)-[A-Z0-9-]+/i); return m ? m[0] : null; }
    return null;
  }
  function setResult(msg, isErr) { var r = $("#add-result"); r.textContent = msg; r.className = "add-result " + (isErr ? "err" : "ok"); }

  /* ---------- Outcomes scorecard ---------- */
  var OUTCOMES = null;
  function fmtVal(v) { return (v === null || v === undefined) ? "\u2014" : String(v); }
  function ocChip(sim) { return sim ? '<span class="chip sim">SIMULATED</span>' : '<span class="chip real">REAL</span>'; }
  function metricTile(m) {
    return '<div class="oc-metric">'
      + '<div class="val">' + esc(fmtVal(m.value)) + '</div>'
      + '<div class="lbl">' + esc(m.name) + (m.unit ? ' <span class="u">(' + esc(m.unit) + ')</span>' : '') + '</div>'
      + '<div class="oc-mchip">' + ocChip(m.is_simulated) + '</div>'
      + (m.status ? '<div class="oc-status">' + esc(m.status) + '</div>' : '')
      + '</div>';
  }
  function weeklyBars(weekly) {
    if (!weekly || !weekly.length) return '';
    var max = Math.max.apply(null, weekly.map(function (w) { return w.n; })) || 1;
    var bars = weekly.map(function (w) {
      var h = Math.round(100 * w.n / max);
      return '<span class="oc-bar" title="' + esc(w.week) + ': ' + w.n + '"><i style="height:' + h + '%"></i><em>' + esc(String(w.week).slice(5)) + '</em></span>';
    }).join("");
    return '<div class="oc-chart"><div class="oc-chart-title">Artifacts created / week (real, last 12w)</div><div class="oc-bars">' + bars + '</div></div>';
  }
  function coverageGauge(m) {
    if (!m || m.value === null || m.value === undefined) return '';
    var base = (m.baseline != null) ? m.baseline : 0, tgt = (m.target != null) ? m.target : 100, cur = m.value;
    function pct(x) { return Math.max(0, Math.min(100, x)); }
    return '<div class="oc-gauge"><div class="oc-chart-title">' + esc(m.name) + '</div>'
      + '<div class="oc-track"><i class="fill" style="width:' + pct(cur) + '%"></i>'
      + (m.baseline != null ? '<b class="tick base" style="left:' + pct(base) + '%"></b>' : '')
      + (m.target != null ? '<b class="tick tgt" style="left:' + pct(tgt) + '%"></b>' : '')
      + '</div>'
      + '<div class="oc-legend">baseline ' + esc(base) + ' &rarr; <b>now ' + esc(cur) + '</b> &rarr; target ' + esc(tgt) + '</div>'
      + '</div>';
  }
  var SPIN_ALL = ['spins_4wk', 'median_spin_hrs', 'cost_per_spin', 'initiatives_built', 'outcomes_resolved'];
  function mByName(metrics, name) { var f = null; (metrics || []).forEach(function (m) { if (m.name === name) f = m; }); return f; }
  function spinCell(role, m, unitLabel) {
    var v = m ? fmtVal(m.value) : "\u2014";
    return '<div class="spin-cell"><span class="role">' + role + '</span><span class="v">' + esc(v) + '</span><span class="u">' + esc(unitLabel) + '</span></div>';
  }
  function spinTrio(metrics) {
    var out = mByName(metrics, 'spins_4wk'), spd = mByName(metrics, 'median_spin_hrs'), cst = mByName(metrics, 'cost_per_spin');
    if (!out && !spd && !cst) return '';
    return '<div class="spin-trio">'
      + '<div class="oc-chart-title">The spin, measured \u2014 output \u00b7 speed \u00b7 cost <span class="chip real">REAL</span></div>'
      + '<div class="spin-cells">'
      + spinCell('Output', out, 'spins / 28d')
      + spinCell('Speed', spd, 'median hrs / spin')
      + spinCell('Cost', cst, 'credits / spin')
      + '</div>'
      + '<div class="spin-note">A <b>spin</b> = one Narrative completed (Initiate \u2192 Research \u2192 Narrative Built). Speed &amp; cost accrue forward \u2014 they populate as newly stage-logged, QUERY_TAG-stamped spins complete (instrumentation live 2026-07-08).</div>'
      + '</div>';
  }
  function gearCell(cls, m, label, win) {
    var v = m ? fmtVal(m.value) : "\u2014";
    return '<div class="gear ' + cls + '"><span class="gv">' + esc(v) + '</span><span class="gl">' + label + '</span><span class="gw">' + win + '</span></div>';
  }
  function gearStrip(metrics) {
    var inner = mByName(metrics, 'spins_4wk'), mid = mByName(metrics, 'initiatives_built'), outer = mByName(metrics, 'outcomes_resolved');
    if (!inner && !mid && !outer) return '';
    return '<div class="gear-strip"><div class="oc-chart-title">Nested gears \u2014 how far the wheel turned</div>'
      + '<div class="gears">'
      + gearCell('inner', inner, 'Narrative spins<br>think', '28d')
      + '<span class="gear-arrow">\u2192</span>'
      + gearCell('mid', mid, 'Initiatives Built<br>deliver', 'all-time')
      + '<span class="gear-arrow">\u2192</span>'
      + gearCell('outer', outer, 'Outcomes Resolved<br>learn', 'all-time')
      + '</div></div>';
  }
  function outcomeCard(o, weekly) {
    var featured = !o.is_simulated;
    var metrics = o.metrics || [];
    var spinBlock = '', tiles;
    if (featured) {
      spinBlock = spinTrio(metrics) + gearStrip(metrics);
      var rest = metrics.filter(function (m) { return SPIN_ALL.indexOf(m.name) < 0; });
      tiles = rest.map(metricTile).join("");
    } else {
      tiles = metrics.map(metricTile).join("") || '<div class="empty">No metrics.</div>';
    }
    var cov = null;
    metrics.forEach(function (m) { if (m.name === 'product_coverage_pct') cov = m; });
    var extra = featured ? (coverageGauge(cov) + weeklyBars(weekly)) : '';
    return '<div class="card oc-card' + (featured ? ' featured' : '') + '">'
      + '<div class="c-head"><div class="c-title">' + esc(o.id) + ' \u2014 ' + esc(o.title) + '</div>' + ocChip(o.is_simulated) + '</div>'
      + (o.objective ? '<div class="oc-obj">' + esc(o.objective) + '</div>' : '')
      + spinBlock
      + (tiles ? '<div class="oc-metrics">' + tiles + '</div>' : '')
      + extra
      + (o.honesty ? '<div class="oc-honesty"><b>Honesty:</b> ' + esc(o.honesty) + '</div>' : '')
      + '</div>';
  }
  function paintOutcomes() {
    var host = $("#outcomes-body"); if (!host) return;
    if (!OUTCOMES) { host.innerHTML = '<div class="empty">Loading\u2026</div>'; return; }
    var ocs = OUTCOMES.outcomes || [];
    if (!ocs.length) { host.innerHTML = '<div class="empty">No outcomes yet.</div>'; return; }
    host.innerHTML = ocs.map(function (o) { return outcomeCard(o, OUTCOMES.weekly_output); }).join("");
  }
  function renderOutcomes() {
    if (OUTCOMES) { paintOutcomes(); return; }
    if (window.__OUTCOMES__) { OUTCOMES = window.__OUTCOMES__; paintOutcomes(); return; }
    paintOutcomes();
    fetch("/api/outcomes").then(function (r) { return r.json(); }).then(function (d) { OUTCOMES = d; paintOutcomes(); })
      .catch(function (e) { var h = $("#outcomes-body"); if (h) h.innerHTML = '<div class="empty">Failed to load outcomes: ' + esc(e) + '</div>'; });
  }

  /* ---------- The Wheel: engine (canvas) + 9-level maturity model ---------- */
  var LEVELS = [
    { n: 1, name: "Ad-Hoc", color: "#8888a0", blurb: "Agent + human building. No reuse, no process; knowledge lives in the conversation and leaves with it." },
    { n: 2, name: "Skills", color: "#29B5E8", blurb: "Repeatable patterns extracted. Your agent can do tomorrow what it learned today." },
    { n: 3, name: "AILC", color: "#F59E0B", blurb: "AI Lifecycle. The agent is inside the build pipeline; automated gates, not just preflight." },
    { n: 4, name: "Trust", color: "#ef4444", blurb: "Independent audit (TARS) on a different model. Three-vote, no self-approval. The guardrail that keeps Level 9 honest." },
    { n: 5, name: "Ecosystem", color: "#06B6D4", blurb: "Shared registry, cross-account collaboration, feedback loops. Skills improve themselves." },
    { n: 6, name: "Shared Cognition", color: "#A78BFA", blurb: "The Bond. Persistent, cross-agent, co-created memory that compounds." },
    { n: 7, name: "Initiative", color: "#F59E0B", blurb: "Agents self-organize and act unprompted. This is autonomy — the floor of RSI, not the top." },
    { n: 8, name: "Representation", color: "#14B8A6", blurb: "The cast represents you where you can't be — Slack, email, meetings. Earned trust + persistent identity. The human scales." },
    { n: 9, name: "Recursion", color: "#29B5E8", blurb: "The system gets better at getting better. The wheel improves the wheel — grounded in Weco's RSI ladder.", apex: true }
  ];
  var RSI_SUB = [
    { k: "9.0", name: "Delegation", note: "runs unattended" },
    { k: "9.1", name: "Net-positive", note: "improves itself faster than we could by hand", here: true },
    { k: "9.2", name: "Ignition", note: "improves its ability to improve" },
    { k: "9.3", name: "Inflection", note: "the curve bends up" }
  ];
  var wheelInit = false;
  function renderWheel() {
    var host = $("#wheel-body"); if (!host) return;
    if (!wheelInit) {
      var levelsHtml = LEVELS.map(function (l) {
        var badge = '<span class="mm-badge" style="background:' + l.color + '">' + l.n + "</span>";
        var body = '<div class="mm-body"><div class="mm-name" style="color:' + l.color + '">' + esc(l.name) + "</div>" +
          '<div class="mm-blurb">' + esc(l.blurb) + "</div>";
        if (l.apex) {
          body += '<div class="mm-sub">' + RSI_SUB.map(function (s) {
            return '<span class="mm-rsi' + (s.here ? " here" : "") + '"><b>' + s.k + "</b> " + esc(s.name) +
              (s.here ? " &mdash; we are here" : "") + "</span>";
          }).join("") + "</div>";
        }
        body += "</div>";
        return '<div class="mm-level' + (l.apex ? " apex" : "") + '">' + badge + body + "</div>";
      }).join("");
      host.innerHTML =
        '<div class="wheel-thesis">GuppiWheel is our testbed for <b>Recursive Self-Improvement</b>.</div>' +
        '<div class="wheel-layout">' +
          '<div class="wheel-col">' +
            '<div class="wheel-canvas-wrap"><canvas id="mmWheelCanvas"></canvas></div>' +
            '<div class="wheel-vocab">One trip around is a <b>spin</b> &mdash; five stages orbiting the <b class="pink">outcome</b> at the hub. The wheel is the <b>engine</b>: how work turns.</div>' +
          "</div>" +
          '<div class="mm-col"><div class="mm-title">The CoCo Maturity Model</div>' + levelsHtml + "</div>" +
        "</div>" +
        '<div class="wheel-caption">The wheel is the engine &mdash; how work turns. The ladder is how far it has taken us. At <b>Level 9, Recursion</b>, they are the same motion: <b>the wheel improving the wheel</b>.</div>';
      setupWheelCanvas(document.getElementById("mmWheelCanvas"));
      wheelInit = true;
    }
    startWheel();
  }
  var _wc = { canvas: null, ctx: null, raf: null, running: false, t: 0, cx: 0, cy: 0, radius: 0, particles: [], ripples: [], stages: null };
  function _wcRespawn(p) { p.rf = 1.28 - Math.random() * 0.16; p.angle = Math.random() * 6.283; p.speed = 0.006 + Math.random() * 0.006; p.inward = 0.0011 + Math.random() * 0.0013; p.size = 2 + Math.random() * 2.2; p.trail = []; p.pulse = Math.random() * 6.28; }
  function setupWheelCanvas(canvas) {
    if (!canvas) return;
    _wc.canvas = canvas; _wc.ctx = canvas.getContext("2d");
    _wc.stages = [
      { name: "Initiate", color: "#F59E0B" }, { name: "Research", color: "#29B5E8" },
      { name: "Building", color: "#8B5CF6" }, { name: "Built", color: "#14B8A6" }, { name: "Narrated", color: "#06B6D4" }
    ].map(function (s, i) { s.angle = -Math.PI / 2 + i * 2 * Math.PI / 5; return s; });
    _wc.particles = [];
    for (var i = 0; i < 32; i++) { var p = {}; _wcRespawn(p); p.rf = 0.2 + Math.random() * 1.06; _wc.particles.push(p); }
    window.addEventListener("resize", _wcSize);
  }
  function _wcSize() {
    var c = _wc.canvas; if (!c) return;
    var dpr = window.devicePixelRatio || 1; var r = c.getBoundingClientRect(); if (!r.width) return;
    c.width = r.width * dpr; c.height = r.height * dpr; _wc.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    _wc.cx = r.width / 2; _wc.cy = r.height / 2; _wc.radius = Math.min(_wc.cx, _wc.cy) * 0.66;
  }
  function startWheel() { if (_wc.running || !_wc.ctx) return; _wc.running = true; _wcSize(); _wcDraw(); }
  function stopWheel() { _wc.running = false; if (_wc.raf) { cancelAnimationFrame(_wc.raf); _wc.raf = null; } }
  function _wcDraw() {
    if (!_wc.running) return;
    var ctx = _wc.ctx, cx = _wc.cx, cy = _wc.cy, radius = _wc.radius;
    if (!radius) { _wcSize(); radius = _wc.radius; cx = _wc.cx; cy = _wc.cy; }
    var dpr = window.devicePixelRatio || 1;
    var w = _wc.canvas.width / dpr, h = _wc.canvas.height / dpr;
    ctx.fillStyle = "rgba(10,10,18,0.18)"; ctx.fillRect(0, 0, w, h); _wc.t += 0.016;
    for (var r = 0.72; r <= 1.18; r += 0.15) { ctx.beginPath(); ctx.arc(cx, cy, radius * r, 0, 6.283); ctx.strokeStyle = "rgba(42,45,58,0.4)"; ctx.lineWidth = 0.5; ctx.stroke(); }
    ctx.beginPath(); ctx.arc(cx, cy, radius, 0, 6.283); ctx.strokeStyle = "rgba(41,181,232,0.22)"; ctx.lineWidth = 2; ctx.stroke();
    _wc.stages.forEach(function (s, i) {
      var x = cx + Math.cos(s.angle) * radius, y = cy + Math.sin(s.angle) * radius;
      var g = ctx.createRadialGradient(x, y, 0, x, y, 54); g.addColorStop(0, s.color + "40"); g.addColorStop(1, "transparent");
      ctx.fillStyle = g; ctx.fillRect(x - 54, y - 54, 108, 108);
      ctx.beginPath(); ctx.arc(x, y, 30 + 4 * Math.sin(_wc.t * 1.5 + i), 0, 6.283); ctx.fillStyle = s.color + "30"; ctx.fill(); ctx.strokeStyle = s.color; ctx.lineWidth = 1.6; ctx.stroke();
      ctx.fillStyle = s.color; ctx.font = 'bold 12px -apple-system,sans-serif'; ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText(s.name, x, y);
    });
    var sa = -Math.PI / 2 + _wc.t * 0.4, sx = cx + Math.cos(sa) * radius, sy = cy + Math.sin(sa) * radius;
    for (var i2 = 0; i2 < 26; i2++) { var ta = sa - i2 * 0.04, tx = cx + Math.cos(ta) * radius, ty = cy + Math.sin(ta) * radius; ctx.beginPath(); ctx.arc(tx, ty, 4 - i2 * 0.1, 0, 6.283); ctx.fillStyle = "rgba(41,181,232," + ((1 - i2 / 26) * 0.7) + ")"; ctx.fill(); }
    ctx.beginPath(); ctx.arc(sx, sy, 6, 0, 6.283); ctx.fillStyle = "#29B5E8"; ctx.fill();
    ctx.fillStyle = "rgba(41,181,232,0.95)"; ctx.font = 'bold 12px -apple-system,sans-serif'; ctx.textAlign = "center"; ctx.fillText("SPIN", sx, sy - 17);
    _wc.particles.forEach(function (p) {
      p.angle += p.speed; p.pulse += 0.05; p.rf -= p.inward;
      var o = radius * p.rf; var px = cx + Math.cos(p.angle) * o, py = cy + Math.sin(p.angle) * o;
      var band = Math.min(0.999, Math.max(0, 1 - (p.rf - 0.19) / (1.28 - 0.19)));
      var col = _wc.stages[Math.min(4, Math.floor(band * 5))].color;
      var fade = Math.max(0, Math.min(1, (p.rf - 0.19) / 0.14));
      p.trail.push({ x: px, y: py }); if (p.trail.length > 9) p.trail.shift();
      for (var j = 0; j < p.trail.length - 1; j++) { var a = j / p.trail.length * 0.4 * fade; ctx.beginPath(); ctx.moveTo(p.trail[j].x, p.trail[j].y); ctx.lineTo(p.trail[j + 1].x, p.trail[j + 1].y); ctx.strokeStyle = col + Math.floor(a * 255).toString(16).padStart(2, "0"); ctx.lineWidth = p.size * 0.5; ctx.stroke(); }
      ctx.globalAlpha = fade; ctx.beginPath(); ctx.arc(px, py, p.size * (0.8 + 0.2 * Math.sin(p.pulse)), 0, 6.283); ctx.fillStyle = col; ctx.fill(); ctx.globalAlpha = 1;
      if (p.rf <= 0.19) { _wc.ripples.push({ a: 0.9 }); _wcRespawn(p); }
    });
    for (var k = _wc.ripples.length - 1; k >= 0; k--) { var rp = _wc.ripples[k]; rp.a -= 0.03; var rr = radius * 0.19 * (1.5 - rp.a); ctx.beginPath(); ctx.arc(cx, cy, rr, 0, 6.283); ctx.strokeStyle = "rgba(236,72,153," + Math.max(0, rp.a * 0.55) + ")"; ctx.lineWidth = 1.4; ctx.stroke(); if (rp.a <= 0) _wc.ripples.splice(k, 1); }
    var cg = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius * 0.36); cg.addColorStop(0, "rgba(236,72,153,0.22)"); cg.addColorStop(0.6, "rgba(236,72,153,0.06)"); cg.addColorStop(1, "transparent");
    ctx.fillStyle = cg; ctx.beginPath(); ctx.arc(cx, cy, radius * 0.36, 0, 6.283); ctx.fill();
    ctx.beginPath(); ctx.arc(cx, cy, radius * 0.19 + 2 * Math.sin(_wc.t * 1.5), 0, 6.283); ctx.strokeStyle = "rgba(236,72,153,0.5)"; ctx.lineWidth = 1.4; ctx.stroke();
    ctx.fillStyle = "#EC4899"; ctx.font = 'bold 16px -apple-system,sans-serif'; ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText("OUTCOME", cx, cy - 6);
    ctx.font = '10px -apple-system,sans-serif'; ctx.fillStyle = "rgba(136,136,160,0.8)"; ctx.fillText("every spin points here", cx, cy + 13);
    _wc.raf = requestAnimationFrame(_wcDraw);
  }

  /* ---------- refresh + wiring ---------- */
  function refresh() {
    if (!LIVE) return Promise.resolve();
    OUTCOMES = null;
    return fetch("/api/data").then(function (r) { return r.json(); }).then(function (d) { boot(d); });
  }
  function switchView(v) {
    Array.prototype.forEach.call(document.querySelectorAll(".global-tab"), function (b) { b.classList.toggle("active", b.dataset.view === v); });
    Array.prototype.forEach.call(document.querySelectorAll(".view"), function (s) { s.classList.toggle("active", s.id === "view-" + v); });
    if (v === "outcomes") renderOutcomes();
    if (v === "wheel") renderWheel(); else stopWheel();
  }

  function wire() {
    Array.prototype.forEach.call(document.querySelectorAll(".global-tab"), function (b) {
      b.addEventListener("click", function () { switchView(b.dataset.view); });
    });
    Array.prototype.forEach.call(document.querySelectorAll("#classic-subtabs .tab"), function (b) {
      b.addEventListener("click", function () {
        Array.prototype.forEach.call(document.querySelectorAll("#classic-subtabs .tab"), function (x) { x.classList.remove("active"); });
        b.classList.add("active"); renderClassic(b.dataset.sub);
      });
    });
    // click-through on classic rows/cards -> detail
    $("#classic-body").addEventListener("click", function (ev) {
      var row = ev.target.closest("[data-id]"); if (row && row.dataset.id) openDetail(row.dataset.id);
    });
    $("#drawer-close").addEventListener("click", closeDrawer);
    $("#drawer-scrim").addEventListener("click", closeDrawer);
    $("#refresh-btn").addEventListener("click", refresh);
    $("#add-btn").addEventListener("click", openModal);
    $("#add-close").addEventListener("click", closeModal);
    $("#add-cancel").addEventListener("click", closeModal);
    $("#modal-scrim").addEventListener("click", closeModal);
    $("#add-submit").addEventListener("click", submitAdd);
    $("#f-type").addEventListener("change", syncAddFields);
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") { closeDrawer(); closeModal(); } });
  }

  wire(); load();
})();
