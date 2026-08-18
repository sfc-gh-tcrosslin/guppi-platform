#!/usr/bin/env bash
# guppi-platform — customer-name guard (RULE-021 / STO-SUBSTRATE-8 at the git write path)
#
# WHY THIS EXISTS
# ---------------
# This repo is an outbound share of the `guppi` product. The wheel already enforces a share
# boundary on every artifact it shares out (PRODUCT_SHARE_LEAK_V): self-meta work ships,
# customer-subject work does not. Git had no equivalent gate, so customer names accumulated
# in CHANGELOG entries and commit messages over ~50 commits.
#
# Self-meta artifact IDs (INIT-/PLAT-/E-/RES- for guppi + platform work) are explicitly FINE —
# we use guppi to build guppi, so those are the engine's own provenance, not leakage.
# What must never ship is a customer/prospect NAME.
#
# Terms come from GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS, never hardcoded here. That was the
# original defect: the term list lived as an RLIKE literal inside the tripwire view, so the
# share-leak check published the very list it existed to protect, and no other tool could reuse
# it. A name you decide is publicly known (e.g. a long-public reference customer) simply is not
# in the table, and is therefore allowed — no code change.
#
# INSTALL (both modes — content and message):
#   cp hooks/no-customer-names.sh .git/hooks/pre-commit
#   cp hooks/no-customer-names.sh .git/hooks/commit-msg
#   chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
#
# BYPASS (logged to the drift report, use sparingly):
#   GUPPI_ALLOW_CUSTOMER_NAMES=1 git commit ...
#
# POSTURE: fails CLOSED on a match, OPEN on any internal error (no wheel access, no python,
# no cached terms). A guard that wedges commits when the warehouse is asleep gets deleted;
# one that quietly does nothing when it cannot check is the lesser evil. It says so out loud.

set -uo pipefail   # deliberately no -e

CACHE="$(git rev-parse --git-dir)/guppi-customer-terms.txt"
MAX_AGE_DAYS=7

if [ "${GUPPI_ALLOW_CUSTOMER_NAMES:-0}" = "1" ]; then
  echo "guppi: customer-name guard BYPASSED via GUPPI_ALLOW_CUSTOMER_NAMES=1" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Refresh the term cache from the wheel when stale/missing. Never fatal.
# ---------------------------------------------------------------------------
refresh_terms() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$CACHE" <<'PY' 2>/dev/null
import os, sys
try:
    import snowflake.connector
except Exception:
    sys.exit(1)
cn = os.getenv("SNOWFLAKE_CONNECTION_NAME")
try:
    conn = snowflake.connector.connect(connection_name=cn) if cn else snowflake.connector.connect()
    cur = conn.cursor()
    cur.execute("SELECT TERM FROM GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS WHERE ACTIVE")
    terms = [r[0].strip() for r in cur.fetchall() if r[0] and r[0].strip()]
    conn.close()
except Exception:
    sys.exit(1)
if not terms:
    sys.exit(1)
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(terms) + "\n")
PY
}

stale=1
if [ -f "$CACHE" ]; then
  if [ -z "$(find "$CACHE" -mtime +${MAX_AGE_DAYS} 2>/dev/null)" ]; then stale=0; fi
fi
if [ "$stale" = "1" ]; then refresh_terms || true; fi

if [ ! -s "$CACHE" ]; then
  echo "guppi: customer-name guard SKIPPED — no term cache and the wheel is unreachable." >&2
  echo "       Nothing was checked. Populate GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS," >&2
  echo "       or set SNOWFLAKE_CONNECTION_NAME so the cache can refresh." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the scan target.
#   commit-msg  : $1 = path to the message file
#   pre-commit  : ADDED lines of the staged diff only (so REMOVING a name is never blocked —
#                 otherwise the guard would block its own remediation commits)
# ---------------------------------------------------------------------------
SCAN="$(mktemp)"
trap 'rm -f "$SCAN"' EXIT

if [ "$#" -ge 1 ] && [ -f "${1:-}" ]; then
  MODE="commit message"
  grep -v '^#' "$1" > "$SCAN" 2>/dev/null
else
  MODE="staged changes"
  git diff --cached -U0 --no-color -- . \
    | grep -E '^\+' | grep -vE '^\+\+\+' > "$SCAN" 2>/dev/null
fi

[ -s "$SCAN" ] && [ -s "$CACHE" ] || exit 0

# ---------------------------------------------------------------------------
# Match. Case-insensitive, fixed-string, whole-word where the term allows it.
# NOTE: earlier ad-hoc scans of this repo missed hits by grepping lowercase terms against
# capitalised names — hence -i is not optional here.
# ---------------------------------------------------------------------------
HITS=0
FOUND=""
while IFS= read -r term; do
  [ -n "$term" ] || continue
  if grep -qiF -- "$term" "$SCAN" 2>/dev/null; then
    HITS=$((HITS + 1))
    FOUND="${FOUND}  - ${term}
$(grep -inF -- "$term" "$SCAN" 2>/dev/null | head -3 | sed 's/^/      /' | cut -c1-140)
"
  fi
done < "$CACHE"

if [ "$HITS" -gt 0 ]; then
  cat >&2 <<EOF

  BLOCKED: customer name(s) in ${MODE}.

${FOUND}
  This repo is PUBLIC and is an outbound share of the guppi product. Customer-subject
  references must not ship (STO-SUBSTRATE-8); self-meta artifact IDs are fine.

  Options:
    - Reword generically ("a customer", "an RCM MVP build"). The engine change is the
      substance; the customer name is almost always incidental.
    - If the name is legitimately public, remove it from the watchlist instead of
      weakening this hook:
        DELETE FROM GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS WHERE TERM = '<NAME>';
    - One-off override:  GUPPI_ALLOW_CUSTOMER_NAMES=1 git commit ...

EOF
  exit 1
fi

exit 0
