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
