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
# ONE LIST: terms come from GUPPIWHEEL.PUBLIC.CUSTOMER_TERMS_V — the same view the wheel's
# share-leak tripwire reads. It is manual terms (CUSTOMER_SUBJECT_TERMS) PLUS every customer
# account the wheel already records (ARTIFACTS.METADATA:account), MINUS exclusions
# (CUSTOMER_SUBJECT_TERMS rows with ACTIVE = FALSE). A customer is protected as soon as their
# work carries an account — nobody has to remember to register them. Never hardcoded here:
# a term list in code publishes the very names it exists to protect.
#
# ONE SCRIPT, THREE MOMENTS (all via .githooks/, see INSTALL):
#   pre-commit  : ADDED lines of the staged diff (removing a name is never blocked, so the
#                 guard can't block its own remediation commits)
#   commit-msg  : the commit message
#   pre-push    : every commit being pushed — each commit's added lines AND message. History
#                 ships, not the net diff: a name added then removed later still leaks.
#   --range R   : same as pre-push for an explicit rev range (sdlc-preflight calls this)
#
# INSTALL (once per clone — versioned hooks, nothing to copy):
#   git config core.hooksPath .githooks
#   git config guppi.connection <snowflake connection that can read GUPPIWHEEL>
#
# BYPASS (use sparingly; says so out loud):
#   GUPPI_ALLOW_CUSTOMER_NAMES=1 git commit|push ...
#
# POSTURE: fails CLOSED on a match everywhere. On an internal error (no wheel, no python, no
# cached terms) it fails OPEN at commit time — a guard that wedges commits when the warehouse
# is asleep gets deleted — but CLOSED at push/range time, because push is the last gate before
# the public remote. The term cache (refreshed at most daily) makes that rare.

set -uo pipefail   # deliberately no -e

CACHE="$(git rev-parse --git-dir)/guppi-customer-terms.txt"
MAX_AGE_MIN=1440

if [ "${GUPPI_ALLOW_CUSTOMER_NAMES:-0}" = "1" ]; then
  echo "guppi: customer-name guard BYPASSED via GUPPI_ALLOW_CUSTOMER_NAMES=1" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode.
# ---------------------------------------------------------------------------
MODE="staged changes"; STRICT=0; RANGES=()
if [ "${1:-}" = "--pre-push" ]; then
  MODE="commits being pushed"; STRICT=1
  Z=0000000000000000000000000000000000000000
  while read -r _lref lsha _rref rsha; do
    [ -n "${lsha:-}" ] && [ "$lsha" != "$Z" ] || continue            # branch deletion
    if [ "$rsha" = "$Z" ]; then RANGES+=("$lsha --not --remotes")     # new branch
    else RANGES+=("$rsha..$lsha"); fi
  done
elif [ "${1:-}" = "--range" ]; then
  MODE="commits in ${2:-origin/main..HEAD}"; STRICT=1
  RANGES+=("${2:-origin/main..HEAD}")
elif [ "$#" -ge 1 ] && [ -f "${1:-}" ]; then
  MODE="commit message"
fi

# ---------------------------------------------------------------------------
# Refresh the term cache from the wheel when stale/missing. Never fatal.
# Connection: GUPPI_WHEEL_CONNECTION > git config guppi.connection > SNOWFLAKE_CONNECTION_NAME
# > connector default. Pin it per repo: the default connection may point at an account with no
# wheel, and then the cache silently never refreshes.
# ---------------------------------------------------------------------------
CONN="${GUPPI_WHEEL_CONNECTION:-$(git config --get guppi.connection 2>/dev/null || true)}"
CONN="${CONN:-${SNOWFLAKE_CONNECTION_NAME:-}}"

refresh_terms() {
  command -v python3 >/dev/null 2>&1 || return 1
  GUPPI_CONN="$CONN" python3 - "$CACHE" <<'PY' 2>/dev/null
import os, sys
try:
    import snowflake.connector
except Exception:
    sys.exit(1)
cn = os.getenv("GUPPI_CONN")
try:
    conn = snowflake.connector.connect(connection_name=cn) if cn else snowflake.connector.connect()
    cur = conn.cursor()
    try:
        cur.execute("SELECT TERM FROM GUPPIWHEEL.PUBLIC.CUSTOMER_TERMS_V")
    except Exception:   # older install without the view
        cur.execute("SELECT TERM FROM GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS WHERE ACTIVE")
    terms = [r[0].strip() for r in cur.fetchall() if r[0] and r[0].strip()]
    conn.close()
except Exception:
    sys.exit(1)
if not terms:
    sys.exit(1)
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh:
    fh.write("\n".join(terms) + "\n")
os.replace(tmp, sys.argv[1])
PY
}

if [ ! -s "$CACHE" ] || [ -n "$(find "$CACHE" -mmin +${MAX_AGE_MIN} 2>/dev/null)" ]; then
  refresh_terms || true
fi

if [ ! -s "$CACHE" ]; then
  if [ "$STRICT" = "1" ]; then
    echo "guppi: customer-name guard BLOCKED push — no term list and the wheel is unreachable." >&2
    echo "       Nothing could be checked. Set: git config guppi.connection <conn>" >&2
    echo "       Or bypass knowingly: GUPPI_ALLOW_CUSTOMER_NAMES=1 git push ..." >&2
    exit 1
  fi
  echo "guppi: customer-name guard SKIPPED — no term cache and the wheel is unreachable." >&2
  echo "       Nothing was checked (push will re-check). Set: git config guppi.connection <conn>" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the scan target.
# ---------------------------------------------------------------------------
SCAN="$(mktemp)"
trap 'rm -f "$SCAN"' EXIT

if [ "${#RANGES[@]}" -gt 0 ]; then
  for r in "${RANGES[@]}"; do
    # shellcheck disable=SC2086  # r is "a..b" or "sha --not --remotes" — word-split on purpose
    git log --format=%B $r >> "$SCAN" 2>/dev/null
    git log -p -U0 --no-color --format= $r 2>/dev/null \
      | grep -E '^\+' | grep -vE '^\+\+\+' >> "$SCAN"
  done
elif [ "$MODE" = "commit message" ]; then
  grep -v '^#' "$1" > "$SCAN" 2>/dev/null
else
  git diff --cached -U0 --no-color -- . \
    | grep -E '^\+' | grep -vE '^\+\+\+' > "$SCAN" 2>/dev/null
fi

[ -s "$SCAN" ] || exit 0

# ---------------------------------------------------------------------------
# Match. Case-insensitive, fixed-string.
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
    - Already committed? Amend/rebase the offending commit — history ships, not the diff.
    - If the name is legitimately public, exclude it (works for wheel-derived names too):
        MERGE INTO GUPPIWHEEL.PUBLIC.CUSTOMER_SUBJECT_TERMS t USING (SELECT '<NAME>' TERM) s
          ON UPPER(t.TERM)=UPPER(s.TERM) WHEN MATCHED THEN UPDATE SET ACTIVE=FALSE
          WHEN NOT MATCHED THEN INSERT (TERM, NOTES, ACTIVE) VALUES (s.TERM, 'public', FALSE);
    - One-off override:  GUPPI_ALLOW_CUSTOMER_NAMES=1 git commit|push ...

EOF
  exit 1
fi

exit 0
