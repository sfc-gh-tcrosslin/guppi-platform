"""
GUPPI Local Search Index (SQLite FTS5)
======================================
Indexes:
  1. Chrome Open Tabs (live via macOS osascript)
  2. Chrome History & Bookmarks (lock-safe temp copy across Chrome profiles)
  3. ~/Downloads (HTML decks, PDFs, docs, archives, project folders)
  4. ~/.snowflake/cortex (skills, plugins, playground/workspace) & /memories

Database lives at ~/.snowflake/cortex/guppi_local_index.db (outside git).
Zero external dependencies (uses Python stdlib sqlite3 + FTS5).
"""
import os
import re
import json
import time
import glob
import shutil
import sqlite3
import hashlib
import tempfile
import subprocess
from html import unescape
from urllib.parse import urlparse

DB_PATH = os.path.expanduser(
    os.getenv("GUPPI_LOCAL_INDEX_DB", "~/.snowflake/cortex/guppi_local_index.db")
)

CHROME_BASE = os.path.expanduser("~/Library/Application Support/Google/Chrome")
DOWNLOADS_DIR = os.path.expanduser("~/Downloads")
COCO_ROOT = os.path.expanduser("~/.snowflake/cortex")

SKIP_DIRS = {
    ".git", "node_modules", ".next", "__pycache__", ".venv", "venv",
    "dist", "build", "cache", "remote-cache", "logs", "Snapshots",
    ".pytest_cache", ".mypy_cache", ".tox", "coverage", "target"
}

TEXT_EXTS = {
    ".md", ".txt", ".sql", ".py", ".js", ".ts", ".tsx", ".jsx",
    ".yaml", ".yml", ".toml", ".json", ".sh", ".css", ".R"
}
HTML_EXTS = {".html", ".htm"}
DOC_EXTS = {
    ".pdf", ".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".xls",
    ".csv", ".zip", ".tgz", ".gz", ".ics"
}
INDEXABLE_EXTS = TEXT_EXTS | HTML_EXTS | DOC_EXTS

WEBKIT_EPOCH_OFFSET = 11644473600  # seconds between 1601-01-01 and 1970-01-01


def _conn():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    _init_schema(conn)
    return conn


def _init_schema(conn):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            val TEXT
        );
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            uri_or_path TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            snippet_text TEXT NOT NULL,
            mtime REAL NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            extra_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_items_source_mtime ON items(source, mtime DESC);
        CREATE INDEX IF NOT EXISTS idx_items_path ON items(uri_or_path);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            id UNINDEXED,
            source UNINDEXED,
            title,
            subtitle,
            uri_or_path,
            snippet_text,
            tokenize='porter unicode61'
        );
    """)


def _make_id(source, uri):
    return hashlib.sha1(f"{source}:{uri}".encode("utf-8", errors="ignore")).hexdigest()[:20]


def _human_tokens(name):
    return re.sub(r"[_\-\./]+", " ", name or "")


def _domain_of(url):
    try:
        return urlparse(url).netloc or url
    except Exception:
        return ""


def _extract_html_text(path, max_chars=6000):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            raw = f.read(350_000)
    except Exception:
        return None, ""
    title_m = re.search(r"<title[^>]*>(.*?)</title>", raw, re.I | re.S)
    title = unescape(re.sub(r"\s+", " ", title_m.group(1)).strip()) if title_m else None
    cleaned = re.sub(r"<(script|style|svg|head|noscript)[^>]*>.*?</\1>", " ", raw, flags=re.I | re.S)
    cleaned = re.sub(r"data:[a-zA-Z0-9/+=\-;]+", " ", cleaned)
    headings = [
        unescape(re.sub(r"<[^>]+>", " ", m).strip())
        for m in re.findall(r"<h[1-3][^>]*>(.*?)</h[1-3]>", cleaned, flags=re.I | re.S)[:12]
    ]
    text = unescape(re.sub(r"<[^>]+>", " ", cleaned))
    text = re.sub(r"\s+", " ", text).strip()
    if not title and headings:
        title = headings[0][:140]
    lead = " · ".join(h for h in headings if h)[:400]
    body = (f"{lead} — {text}" if lead else text)[:max_chars]
    return title, body


def _extract_text_file(path, ext, max_chars=5000):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            raw = f.read(120_000)
    except Exception:
        return None, ""
    title = None
    if ext == ".md":
        m_name = re.search(r"^name:\s*(.+)$", raw[:1000], re.M)
        m_h1 = re.search(r"^#\s+(.+)$", raw[:2000], re.M)
        if m_h1:
            title = m_h1.group(1).strip()[:140]
        elif m_name:
            title = m_name.group(1).strip()[:140]
    text = re.sub(r"\s+", " ", raw).strip()[:max_chars]
    return title, text


def _extract_csv_head(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = [f.readline().strip() for _ in range(3)]
        return " | ".join(l for l in lines if l)[:1500]
    except Exception:
        return ""


def _fetch_chrome_open_tabs():
    """Return live open Chrome tabs via osascript without launching Chrome if closed.
    Returns None on transient AppleScript error/timeout so caller preserves cached tabs."""
    script = """
    if application "Google Chrome" is running then
        tell application "Google Chrome"
            set out to ""
            set wIdx to 0
            repeat with w in windows
                set wIdx to wIdx + 1
                set activeIdx to active tab index of w
                set tIdx to 0
                repeat with t in tabs of w
                    set tIdx to tIdx + 1
                    set tUrl to URL of t
                    set tTitle to title of t
                    set isAct to (tIdx is equal to activeIdx)
                    set out to out & wIdx & "\\t" & tIdx & "\\t" & isAct & "\\t" & tUrl & "\\t" & tTitle & "\\n"
                end repeat
            end repeat
            return out
        end tell
    else
        return "NOT_RUNNING"
    end if
    """
    try:
        res = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=10.0
        )
        if res.returncode != 0:
            return None
        stdout = (res.stdout or "").strip()
        if stdout == "NOT_RUNNING":
            return []
        if not stdout:
            return None
        tabs = []
        now = time.time()
        for line in stdout.splitlines():
            parts = line.split("\t", 4)
            if len(parts) < 5:
                continue
            w_idx, t_idx, is_act, url, title = parts
            if not url or url.startswith("chrome://newtab"):
                continue
            domain = _domain_of(url)
            tabs.append({
                "id": _make_id("chrome_tab", f"{w_idx}:{t_idx}:{url}"),
                "source": "chrome_tab",
                "kind": "tab",
                "title": (title.strip() or domain or url)[:240],
                "uri_or_path": url.strip(),
                "subtitle": f"Window {w_idx} · Tab {t_idx} · {domain}",
                "snippet_text": f"{title} {domain} {_human_tokens(url)}",
                "mtime": now,
                "size_bytes": 0,
                "extra_json": json.dumps({
                    "window_index": int(w_idx),
                    "tab_index": int(t_idx),
                    "active": is_act.lower() == "true",
                    "domain": domain,
                }),
            })
        return tabs
    except Exception:
        return None


def _fetch_chrome_history_and_bookmarks(max_history_per_profile=2000):
    items_by_id = {}
    if not os.path.isdir(CHROME_BASE):
        return []

    profiles = ["Default"] + sorted(
        d for d in os.listdir(CHROME_BASE)
        if d.startswith("Profile ") and os.path.isdir(os.path.join(CHROME_BASE, d))
    )

    for prof in profiles:
        prof_dir = os.path.join(CHROME_BASE, prof)
        # 1. Bookmarks JSON
        bm_path = os.path.join(prof_dir, "Bookmarks")
        if os.path.isfile(bm_path):
            try:
                with open(bm_path, "r", encoding="utf-8", errors="ignore") as f:
                    bm_data = json.load(f)

                def _walk_bm(node, folder=""):
                    if not isinstance(node, dict):
                        return
                    ntype = node.get("type")
                    name = (node.get("name") or "").strip()
                    if ntype == "url":
                        url = (node.get("url") or "").strip()
                        if url and not url.startswith("javascript:"):
                            domain = _domain_of(url)
                            raw_ts = int(node.get("date_last_used") or node.get("date_added") or 0)
                            ts = (raw_ts / 1_000_000 - WEBKIT_EPOCH_OFFSET) if raw_ts > 0 else time.time()
                            iid = _make_id("chrome_history", f"bm:{url}")
                            items_by_id[iid] = {
                                "id": iid,
                                "source": "chrome_history",
                                "kind": "bookmark",
                                "title": (name or domain or url)[:240],
                                "uri_or_path": url,
                                "subtitle": f"Bookmark ({prof}{' / ' + folder if folder else ''}) · {domain}",
                                "snippet_text": f"Bookmark {folder} {name} {domain} {_human_tokens(url)}",
                                "mtime": max(0.0, ts),
                                "size_bytes": 0,
                                "extra_json": json.dumps({"profile": prof, "folder": folder, "domain": domain, "bookmark": True}),
                            }
                    for child in (node.get("children") or []):
                        _walk_bm(child, f"{folder}/{name}".strip("/") if name else folder)

                roots = (bm_data.get("roots") or {})
                for rkey, rnode in roots.items():
                    _walk_bm(rnode, rkey)
            except Exception:
                pass

        # 2. History SQLite (copy to temp file so Chrome lock never blocks)
        hist_path = os.path.join(prof_dir, "History")
        if os.path.isfile(hist_path):
            tmp_fd, tmp_path = tempfile.mkstemp(prefix="guppi_chrome_hist_", suffix=".db")
            os.close(tmp_fd)
            try:
                shutil.copy2(hist_path, tmp_path)
                hconn = sqlite3.connect(tmp_path, timeout=3.0)
                cur = hconn.cursor()
                cur.execute(
                    """
                    SELECT url, title, visit_count, last_visit_time
                    FROM urls
                    WHERE hidden = 0 AND last_visit_time > 0
                    ORDER BY last_visit_time DESC
                    LIMIT ?
                    """,
                    (max_history_per_profile,),
                )
                for url, title, vcount, last_vt in cur.fetchall():
                    if not url or url.startswith(("chrome://", "chrome-extension://", "about:")):
                        continue
                    domain = _domain_of(url)
                    clean_title = (title or "").strip() or domain or url
                    ts = max(0.0, (int(last_vt) / 1_000_000) - WEBKIT_EPOCH_OFFSET)
                    iid = _make_id("chrome_history", url)
                    existing = items_by_id.get(iid)
                    if existing and existing["mtime"] >= ts:
                        continue
                    items_by_id[iid] = {
                        "id": iid,
                        "source": "chrome_history",
                        "kind": "history",
                        "title": clean_title[:240],
                        "uri_or_path": url,
                        "subtitle": f"{domain} · {vcount} visit{'s' if vcount != 1 else ''} ({prof})",
                        "snippet_text": f"{clean_title} {domain} {_human_tokens(url)}",
                        "mtime": ts,
                        "size_bytes": 0,
                        "extra_json": json.dumps({
                            "profile": prof,
                            "visit_count": int(vcount or 1),
                            "domain": domain,
                        }),
                    }
                hconn.close()
            except Exception:
                pass
            finally:
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

    return list(items_by_id.values())


def _walk_roots():
    """Return (source, label, root_dir, max_depth) roots to scan."""
    roots = [
        ("downloads", "Downloads", DOWNLOADS_DIR, 4),
        ("coco", "CoCo Skills", os.path.join(COCO_ROOT, "skills"), 4),
        ("coco", "CoCo Plugins", os.path.join(COCO_ROOT, "plugins"), 5),
        ("coco", "CoCo Workspace", os.path.join(COCO_ROOT, "playground", "workspace"), 4),
    ]
    extra_env = os.getenv("GUPPI_SEARCH_DIRS", "").strip()
    if extra_env:
        for p in extra_env.split(":"):
            p = os.path.expanduser(p.strip())
            if p and os.path.isdir(p):
                roots.append(("coco", os.path.basename(p), p, 4))
    return roots


def _classify_kind(path, ext):
    base = os.path.basename(path)
    if base == "SKILL.md":
        return "skill"
    if ext in HTML_EXTS:
        return "html"
    if ext == ".pdf":
        return "pdf"
    if ext == ".md":
        return "md"
    if ext == ".sql":
        return "sql"
    if ext == ".py":
        return "py"
    if ext in (".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".xls", ".csv"):
        return ext.lstrip(".")
    if ext in (".zip", ".tgz", ".gz"):
        return "archive"
    return ext.lstrip(".") or "file"


def sync_index(force=False, tabs_only=False):
    """Synchronize open Chrome tabs, Chrome history/bookmarks, Downloads, and CoCo folders."""
    t0 = time.time()
    conn = _conn()
    cur = conn.cursor()

    # 1. Refresh live Chrome open tabs (preserve cached tabs if osascript returns None)
    tabs = _fetch_chrome_open_tabs()
    if tabs is not None:
        cur.execute("DELETE FROM items WHERE source = 'chrome_tab'")
        cur.execute("DELETE FROM items_fts WHERE source = 'chrome_tab'")
        for it in tabs:
            cur.execute(
                """
                INSERT OR REPLACE INTO items
                (id, source, kind, title, uri_or_path, subtitle, snippet_text, mtime, size_bytes, extra_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (it["id"], it["source"], it["kind"], it["title"], it["uri_or_path"],
                 it["subtitle"], it["snippet_text"], it["mtime"], it["size_bytes"], it["extra_json"]),
            )
            cur.execute(
                """
                INSERT INTO items_fts (id, source, title, subtitle, uri_or_path, snippet_text)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (it["id"], it["source"], it["title"], it["subtitle"], it["uri_or_path"], it["snippet_text"]),
            )
        cur.execute("INSERT OR REPLACE INTO meta (key, val) VALUES ('last_tabs_sync_epoch', ?)", (str(time.time()),))

    if tabs_only:
        conn.commit()
        conn.close()
        return {"tabs": len(tabs) if tabs is not None else -1, "elapsed_ms": int((time.time() - t0) * 1000)}

    # 2. Refresh Chrome History & Bookmarks
    hist_items = _fetch_chrome_history_and_bookmarks()
    cur.execute("DELETE FROM items WHERE source = 'chrome_history'")
    cur.execute("DELETE FROM items_fts WHERE source = 'chrome_history'")
    for it in hist_items:
        cur.execute(
            """
            INSERT OR REPLACE INTO items
            (id, source, kind, title, uri_or_path, subtitle, snippet_text, mtime, size_bytes, extra_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (it["id"], it["source"], it["kind"], it["title"], it["uri_or_path"],
             it["subtitle"], it["snippet_text"], it["mtime"], it["size_bytes"], it["extra_json"]),
        )
        cur.execute(
            """
            INSERT INTO items_fts (id, source, title, subtitle, uri_or_path, snippet_text)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (it["id"], it["source"], it["title"], it["subtitle"], it["uri_or_path"], it["snippet_text"]),
        )

    # 3. Incremental walk of Downloads + CoCo folders
    existing_files = {}
    if not force:
        cur.execute("SELECT id, uri_or_path, mtime, size_bytes FROM items WHERE source IN ('downloads', 'coco')")
        for row in cur.fetchall():
            existing_files[row["uri_or_path"]] = (row["id"], row["mtime"], row["size_bytes"])

    seen_paths = set()
    upserted_files = 0

    for base_source, label, root_dir, max_depth in _walk_roots():
        if not os.path.isdir(root_dir):
            continue
        root_depth = root_dir.rstrip(os.sep).count(os.sep)
        for dirpath, dirnames, filenames in os.walk(root_dir):
            depth = dirpath.rstrip(os.sep).count(os.sep) - root_depth
            if depth >= max_depth:
                dirnames[:] = []
            else:
                dirnames[:] = [
                    d for d in dirnames
                    if not d.startswith(".") and d not in SKIP_DIRS
                ]

            for fname in filenames:
                if fname.startswith("."):
                    continue
                ext = os.path.splitext(fname)[1].lower()
                if ext not in INDEXABLE_EXTS:
                    continue
                fpath = os.path.join(dirpath, fname)
                if fpath in seen_paths:
                    continue
                seen_paths.add(fpath)

                try:
                    st = os.stat(fpath)
                except OSError:
                    continue
                mtime = float(st.st_mtime)
                size_bytes = int(st.st_size)

                source = base_source

                prev = existing_files.get(fpath)
                if prev and abs(prev[1] - mtime) < 0.01 and prev[2] == size_bytes:
                    continue

                kind = _classify_kind(fpath, ext)
                rel_dir = os.path.relpath(dirpath, os.path.expanduser("~"))
                subtitle = f"~/{rel_dir}"

                extracted_title = None
                body_text = ""
                if ext in HTML_EXTS and size_bytes < 15_000_000:
                    extracted_title, body_text = _extract_html_text(fpath)
                elif ext in TEXT_EXTS and size_bytes < 2_000_000:
                    extracted_title, body_text = _extract_text_file(fpath, ext)
                elif ext == ".csv" and size_bytes < 50_000_000:
                    body_text = _extract_csv_head(fpath)

                if fname == "SKILL.md":
                    skill_folder = os.path.basename(dirpath)
                    title = f"{skill_folder} ({extracted_title or 'SKILL.md'})"
                elif extracted_title and ext in HTML_EXTS:
                    title = f"{extracted_title} ({fname})"
                else:
                    title = extracted_title or fname

                snippet_text = f"{_human_tokens(fname)} {_human_tokens(rel_dir)} {title} {body_text}".strip()[:8000]
                iid = _make_id(source, fpath)

                cur.execute("DELETE FROM items WHERE uri_or_path = ?", (fpath,))
                cur.execute("DELETE FROM items_fts WHERE uri_or_path = ?", (fpath,))
                cur.execute(
                    """
                    INSERT INTO items
                    (id, source, kind, title, uri_or_path, subtitle, snippet_text, mtime, size_bytes, extra_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        iid, source, kind, title[:240], fpath, subtitle,
                        snippet_text, mtime, size_bytes,
                        json.dumps({"ext": ext, "in_downloads": fpath.startswith(DOWNLOADS_DIR)}),
                    ),
                )
                cur.execute(
                    """
                    INSERT INTO items_fts (id, source, title, subtitle, uri_or_path, snippet_text)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (iid, source, title[:240], subtitle, fpath, snippet_text),
                )
                upserted_files += 1

    # Prune deleted local files
    for old_path, (old_id, _, _) in existing_files.items():
        if old_path not in seen_paths and not os.path.exists(old_path):
            cur.execute("DELETE FROM items WHERE id = ?", (old_id,))
            cur.execute("DELETE FROM items_fts WHERE id = ?", (old_id,))

    now_str = time.strftime("%Y-%m-%d %H:%M:%S")
    cur.execute("INSERT OR REPLACE INTO meta (key, val) VALUES ('last_sync_epoch', ?)", (str(time.time()),))
    cur.execute("INSERT OR REPLACE INTO meta (key, val) VALUES ('last_sync_str', ?)", (now_str,))
    conn.commit()
    counts = _get_counts(conn)
    conn.close()
    return {
        "status": "ok",
        "last_sync": now_str,
        "upserted_files": upserted_files,
        "counts": counts,
        "elapsed_ms": int((time.time() - t0) * 1000),
    }


def _get_counts(conn):
    cur = conn.cursor()
    cur.execute("SELECT source, COUNT(*) AS n FROM items GROUP BY source")
    by_src = {r["source"]: int(r["n"]) for r in cur.fetchall()}
    cur.execute(
        "SELECT COUNT(*) FROM items WHERE source = 'downloads' OR uri_or_path LIKE ?",
        (f"{DOWNLOADS_DIR}/%",),
    )
    dl_total = int(cur.fetchone()[0])
    total = sum(by_src.values())
    return {
        "all": total,
        "chrome_tab": by_src.get("chrome_tab", 0),
        "chrome_history": by_src.get("chrome_history", 0),
        "downloads": dl_total,
        "coco": by_src.get("coco", 0),
    }


def _build_fts_query(q):
    tokens = re.findall(r"[a-zA-Z0-9]+", (q or "").lower())
    if not tokens:
        return ""
    return " AND ".join(f'"{t}"*' for t in tokens[:10])


def _source_where(source):
    if not source or source == "all":
        return "1=1", ()
    if source == "downloads":
        return "(i.source = 'downloads' OR i.uri_or_path LIKE ?)", (f"{DOWNLOADS_DIR}/%",)
    return "i.source = ?", (source,)


def search_index(q="", source="all", limit=100):
    conn = _conn()
    cur = conn.cursor()
    cur.execute("SELECT val FROM meta WHERE key = 'last_sync_epoch'")
    row = cur.fetchone()
    last_epoch = float(row["val"]) if row and row["val"] else 0.0
    conn.close()

    # Build once if the index has never been built. After that it only changes on the
    # daily sync (python3 local_search.py --sync), the Re-index button, or Close Tab.
    if last_epoch == 0.0:
        sync_index(force=False)

    conn = _conn()
    cur = conn.cursor()
    cur.execute("SELECT val FROM meta WHERE key = 'last_sync_str'")
    r_sync = cur.fetchone()
    last_sync_str = r_sync["val"] if r_sync else "—"
    counts = _get_counts(conn)

    where_sql, where_params = _source_where(source)
    fts_q = _build_fts_query(q)
    results = []

    if fts_q:
        sql = f"""
            SELECT
                i.id, i.source, i.kind, i.title, i.uri_or_path, i.subtitle,
                i.mtime, i.size_bytes, i.extra_json,
                snippet(items_fts, 5, '<mark>', '</mark>', ' … ', 28) AS match_snippet,
                bm25(items_fts, 12.0, 4.0, 3.0, 1.0)
                  + CASE WHEN i.source = 'chrome_tab' THEN -8.0
                         WHEN i.kind = 'skill' THEN -3.0
                         WHEN i.kind = 'html' THEN -2.0
                         ELSE 0.0 END AS rank_score
            FROM items_fts
            JOIN items i ON i.id = items_fts.id
            WHERE items_fts MATCH ? AND {where_sql}
            ORDER BY rank_score ASC, i.mtime DESC
            LIMIT ?
        """
        try:
            cur.execute(sql, (fts_q, *where_params, int(limit)))
            for r in cur.fetchall():
                results.append(_row_to_dict(r))
        except sqlite3.OperationalError:
            results = []

        # Fallback substring search if FTS returned nothing
        if not results:
            like_pat = f"%{q.strip()}%"
            cur.execute(
                f"""
                SELECT i.id, i.source, i.kind, i.title, i.uri_or_path, i.subtitle,
                       i.mtime, i.size_bytes, i.extra_json,
                       substr(i.snippet_text, 1, 220) AS match_snippet
                FROM items i
                WHERE (i.title LIKE ? OR i.uri_or_path LIKE ? OR i.snippet_text LIKE ?)
                  AND {where_sql}
                ORDER BY CASE WHEN i.source = 'chrome_tab' THEN 0 ELSE 1 END, i.mtime DESC
                LIMIT ?
                """,
                (like_pat, like_pat, like_pat, *where_params, int(limit)),
            )
            for r in cur.fetchall():
                results.append(_row_to_dict(r))
    else:
        # Empty query: show open tabs first (when source=all or chrome_tab), then most recent items
        cur.execute(
            f"""
            SELECT i.id, i.source, i.kind, i.title, i.uri_or_path, i.subtitle,
                   i.mtime, i.size_bytes, i.extra_json,
                   substr(i.snippet_text, 1, 200) AS match_snippet
            FROM items i
            WHERE {where_sql}
            ORDER BY CASE WHEN i.source = 'chrome_tab' THEN 0 ELSE 1 END, i.mtime DESC
            LIMIT ?
            """,
            (*where_params, int(limit)),
        )
        for r in cur.fetchall():
            results.append(_row_to_dict(r))

    conn.close()
    return {
        "query": q or "",
        "source": source or "all",
        "last_sync": last_sync_str,
        "counts": counts,
        "results": results,
    }


def _row_to_dict(r):
    try:
        extra = json.loads(r["extra_json"] or "{}")
    except Exception:
        extra = {}
    return {
        "id": r["id"],
        "source": r["source"],
        "kind": r["kind"],
        "title": r["title"],
        "uri_or_path": r["uri_or_path"],
        "subtitle": r["subtitle"],
        "mtime": r["mtime"],
        "mtime_str": time.strftime("%Y-%m-%d %H:%M", time.localtime(r["mtime"])) if r["mtime"] else "",
        "size_bytes": r["size_bytes"],
        "snippet": r["match_snippet"] or "",
        "extra": extra,
    }


def perform_action(action, payload):
    """Execute a local action on a search result item (focus_tab, close_tab, open_file, reveal_finder, open_coco)."""
    action = (action or "").strip()
    target = (payload.get("uri_or_path") or "").strip()
    win_idx = payload.get("window_index")
    tab_idx = payload.get("tab_index")

    if action not in ("reindex",) and target:
        _c = _conn()
        _known = _c.execute("SELECT 1 FROM items WHERE uri_or_path = ? LIMIT 1", (target,)).fetchone()
        _c.close()
        if not _known:
            return {"ok": False, "error": "target is not an indexed item"}

    if action == "focus_tab":
        script = """
        on run argv
            set targetUrl to item 1 of argv
            tell application "Google Chrome"
                activate
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        if (URL of t) is equal to targetUrl then
                            set active tab index of w to tIdx
                            set index of w to 1
                            return "focused:" & wIdx & ":" & tIdx
                        end if
                    end repeat
                end repeat
            end tell
            return "not_found"
        end run
        """
        res = subprocess.run(["osascript", "-e", script, target], capture_output=True, text=True, timeout=4.0)
        out = (res.stdout or "").strip()
        if out.startswith("focused:"):
            return {"ok": True, "message": f"Focused Chrome tab ({out})"}
        # Fallback: open URL in Chrome
        subprocess.run(["open", "-a", "Google Chrome", target], timeout=4.0)
        return {"ok": True, "message": "Opened in Chrome"}

    if action == "close_tab":
        script = """
        on run argv
            set targetUrl to item 1 of argv
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is equal to targetUrl then
                            close t
                            return "closed"
                        end if
                    end repeat
                end repeat
            end tell
            return "not_found"
        end run
        """
        res = subprocess.run(["osascript", "-e", script, target], capture_output=True, text=True, timeout=4.0)
        out = (res.stdout or "").strip()
        # Refresh open tabs in SQLite index immediately
        sync_index(tabs_only=True)
        return {"ok": out == "closed", "message": "Closed Chrome tab" if out == "closed" else "Tab already closed"}

    if action == "open_file":
        if target.startswith(("http://", "https://")):
            subprocess.run(["open", target], timeout=4.0)
            return {"ok": True, "message": "Opened URL"}
        if not os.path.exists(target):
            return {"ok": False, "error": f"File not found: {target}"}
        subprocess.run(["open", target], timeout=4.0)
        return {"ok": True, "message": f"Opened {os.path.basename(target)}"}

    if action == "reveal_finder":
        if not os.path.exists(target):
            return {"ok": False, "error": f"File not found: {target}"}
        subprocess.run(["open", "-R", target], timeout=4.0)
        return {"ok": True, "message": f"Revealed {os.path.basename(target)} in Finder"}

    if action == "open_coco":
        if not os.path.exists(target):
            return {"ok": False, "error": f"Path not found: {target}"}
        coco_bin = shutil.which("coco")
        if coco_bin:
            subprocess.Popen([coco_bin, target])
            return {"ok": True, "message": f"Opened {os.path.basename(target)} in CoCo"}
        subprocess.run(["open", "-R", target], timeout=4.0)
        return {"ok": True, "message": f"Revealed {os.path.basename(target)} in Finder ('coco' CLI not in PATH)"}

    return {"ok": False, "error": f"Unknown action: {action}"}


if __name__ == "__main__":
    import sys
    if "--sync" in sys.argv:
        print(json.dumps(sync_index(force="--force" in sys.argv)))
    else:
        print("usage: python3 local_search.py --sync [--force]")
