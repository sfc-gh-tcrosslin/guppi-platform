#!/usr/bin/env bash
# CoCo Platform — Lifecycle Hook State Machine
# Manages phase tracking, capture-debt gating (RULE-013), and session resume.
#
# DESIGN NOTES (2026-08-16 hardening):
#   1. CANONICAL STATE. State lives at an ABSOLUTE path shared with skills/wheel/SKILL.md.
#      Previously lifecycle.sh used ${CORTEX_PROJECT_DIR:-.}/.cortex-plugin/.state.json while the
#      wheel skill used ~/.snowflake/cortex/.guppi-platform-state.json — split brain. CORTEX_PROJECT_DIR
#      is normally unset, so state resolved against cwd and `cat >` died under `set -e` in any
#      directory lacking .cortex-plugin/. Net effect: no state ever persisted, current_initiative
#      was permanently null, and every reminder was vacuous.
#   2. FAIL OPEN. A hook must never wedge a session. `set -e` is deliberately NOT used; every
#      state/jq operation is guarded and we always emit valid JSON on stdout.
#   3. HYBRID CAPTURE GATE. Creating a NEW deliverable with no open initiative is BLOCKED
#      (a deliberate act is the right moment to demand an initiative). Editing an EXISTING
#      deliverable only warns, so the 10x-iteration loop stays frictionless.
#   4. NO GIT SCOPE GUARD. post-create-plan / post-switch-mode used to early-exit unless cwd was
#      inside the guppi-platform git repo, which silenced them during real customer work.
#      RULE-013 applies to all outputs, not just plugin dogfooding.

set -uo pipefail   # NOTE: no -e. Fail open, never block on internal error.

STATE_FILE="${HOME}/.snowflake/cortex/.guppi-platform-state.json"

allow()      { echo '{"decision": "allow"}'; exit 0; }
have_jq()    { command -v jq >/dev/null 2>&1; }

# JSON-escape a string for safe embedding in our output
jesc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'; }

ensure_state() {
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<'INIT' 2>/dev/null || true
{
  "phase": "ad-hoc",
  "active_skill": null,
  "refs_read": [],
  "current_initiative": null,
  "pending_captures": [],
  "last_updated": null
}
INIT
  fi
}

read_state() {
  ensure_state
  cat "$STATE_FILE" 2>/dev/null || echo '{}'
}

# get_field <jq-path> <default>
get_field() {
  local path="$1" def="${2:-}"
  if ! have_jq; then printf '%s' "$def"; return 0; fi
  local v
  v=$(read_state | jq -r "${path} // empty" 2>/dev/null || true)
  [ -z "$v" ] && v="$def"
  printf '%s' "$v"
}

# Read tool JSON from stdin without hanging if nothing is piped.
read_stdin() {
  local data=""
  IFS= read -r -d '' -t 2 data 2>/dev/null || true
  printf '%s' "$data"
}

# ---- deliverable / scratch classification ------------------------------------
# scratch wins over deliverable: playground + /tmp are scratch by definition.
is_scratch() {
  case "$1" in
    */playground/*|/tmp/*|*/.git/*|*/node_modules/*|*.scratch.*|*/.cortex-plugin/*) return 0 ;;
  esac
  return 1
}

# Deliverable is EXTENSION-driven, not directory-driven. ~/Downloads is "not scratch"
# (so an .html there is a real deliverable), but that must not promote every stray
# .py/.txt/.json in Downloads into a governed artifact — over-blocking is what gets
# hooks disabled. Keep this list to things we actually capture and render.
is_deliverable() {
  case "$1" in
    *.plan.md) return 0 ;;
    *.html|*.htm|*.pdf|*.ipynb|*.pptx|*.docx) return 0 ;;
  esac
  return 1
}

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

record_pending() {
  local p="$1"
  have_jq || return 0
  ensure_state
  local sha ts tmp
  sha=$(sha_of "$p"); ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); tmp="${STATE_FILE}.tmp.$$"
  jq --arg p "$p" --arg s "${sha:-}" --arg t "$ts" \
     '.pending_captures = ((.pending_captures // []) | map(select(.path != $p)) + [{path:$p, sha256:$s, ts:$t}])
      | .last_updated = $t' \
     "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

EVENT="${1:-}"

case "$EVENT" in

  session-start)
    ensure_state
    PHASE=$(get_field '.phase' 'ad-hoc')
    SKILL=$(get_field '.active_skill' 'none')
    INIT=$(get_field '.current_initiative' 'none')
    NPEND=0
    if have_jq; then NPEND=$(read_state | jq -r '(.pending_captures // []) | length' 2>/dev/null || echo 0); fi
    MSG="[guppi-platform] Session resumed. Phase: ${PHASE} | Skill: ${SKILL} | Wheel: ${INIT} | Uncaptured deliverables: ${NPEND}."
    if [ "$INIT" = "none" ]; then
      MSG="${MSG} No active initiative — open one with /wheel start before producing deliverables (RULE-013)."
    fi
    if [ "${NPEND:-0}" != "0" ]; then
      MSG="${MSG} Run /wheel capture on the pending files."
    fi
    MSG="${MSG} [radar] Check GUPPIWHEEL.PUBLIC.RADAR_ITEMS WHERE DELIVERED=FALSE; if any, summarize, offer CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH('NAR-RADAR'), then set DELIVERED=TRUE. If none, stay silent."
    MSG="${MSG} [tripwire] Check GUPPIWHEEL.PUBLIC.DIRECT_DML_TRIPWIRE_V for ungoverned substrate writes in the last 24h; report only if non-empty."
    printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
    exit 0
    ;;

  pre-write)
    INPUT=$(read_stdin)
    TARGET=""
    TOOL=""
    if have_jq && [ -n "$INPUT" ]; then
      TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filePath // empty' 2>/dev/null || true)
      TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)
    fi

    # No path resolved (or no jq): fail open.
    [ -z "$TARGET" ] && allow

    is_scratch "$TARGET" && allow
    is_deliverable "$TARGET" || allow

    INIT=$(get_field '.current_initiative' '')

    # create vs edit: a 'write' to a path that does not yet exist is a creation.
    IS_CREATE=0
    if [ ! -e "$TARGET" ]; then IS_CREATE=1; fi

    if [ -z "$INIT" ] && [ "$IS_CREATE" = "1" ]; then
      REASON="[guppi-platform] BLOCKED by RULE-013 (Headless First): creating a new deliverable ('$(basename "$TARGET")') with no open initiative. Every output is an artifact in GUPPIWHEEL.PUBLIC.ARTIFACTS before any external render. Fix: run '/wheel start \"<title>\"' to open an initiative, then retry. If this is throwaway, write it under a scratch path (playground/, /tmp/, or *.scratch.*) instead."
      printf '{"decision": "block", "reason": "%s"}\n' "$(jesc "$REASON")"
      exit 2
    fi

    record_pending "$TARGET"

    if [ -z "$INIT" ]; then
      MSG="[guppi-platform] RULE-013 warning: editing deliverable '$(basename "$TARGET")' with no open initiative. Recorded as capture debt. Open one with /wheel start, then /wheel capture before the session ends."
      printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
      exit 0
    fi

    MSG="[guppi-platform] Deliverable tracked under ${INIT}. Remember: /wheel capture $(basename "$TARGET") before session end."
    printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
    exit 0
    ;;

  post-skill)
    INPUT=$(read_stdin)
    SKILL_NAME="unknown"
    if have_jq && [ -n "$INPUT" ]; then
      SKILL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.name // "unknown"' 2>/dev/null || echo unknown)
    fi
    ensure_state
    if have_jq; then
      TMP="${STATE_FILE}.tmp.$$"
      jq --arg skill "$SKILL_NAME" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '.active_skill = $skill | .last_updated = $ts' "$STATE_FILE" > "$TMP" 2>/dev/null \
         && mv "$TMP" "$STATE_FILE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
    fi
    allow
    ;;

  post-create-plan)
    # A plan IS a deliverable. RULE-013 applies regardless of which repo we are in.
    INPUT=$(read_stdin)
    PLAN_NAME=""
    if have_jq && [ -n "$INPUT" ]; then
      PLAN_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)
    fi
    [ -z "$PLAN_NAME" ] && allow

    INIT=$(get_field '.current_initiative' '')
    if [ -n "$INIT" ]; then
      MSG="[guppi-platform] Plan '${PLAN_NAME}' created. Publish it as a NARRATIVE under ${INIT}: /wheel publish-plan (RULE-013 — render FROM artifacts, not instead of them)."
    else
      MSG="[guppi-platform] Plan '${PLAN_NAME}' created with no active initiative. RULE-013: open one with /wheel start, then /wheel publish-plan so the plan lands as a NARRATIVE."
    fi
    printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
    exit 0
    ;;

  post-switch-mode)
    INPUT=$(read_stdin)
    TARGET_MODE=""
    if have_jq && [ -n "$INPUT" ]; then
      TARGET_MODE=$(printf '%s' "$INPUT" | jq -r '.tool_input.target_mode_id // empty' 2>/dev/null || true)
    fi
    [ "$TARGET_MODE" != "agent" ] && allow

    INIT=$(get_field '.current_initiative' '')
    if [ -z "$INIT" ]; then
      MSG="[guppi-platform] Entering agent mode with no active initiative. RULE-013/014: open one with /wheel start before producing deliverables."
    else
      MSG="[guppi-platform] Executing under ${INIT}. Output must land as artifacts in the wheel."
    fi
    printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
    exit 0
    ;;

  stop)
    PHASE=$(get_field '.phase' 'ad-hoc')
    INIT=$(get_field '.current_initiative' 'none')
    LIST=""
    NPEND=0
    if have_jq; then
      NPEND=$(read_state | jq -r '(.pending_captures // []) | length' 2>/dev/null || echo 0)
      LIST=$(read_state | jq -r '(.pending_captures // []) | map(.path) | join(", ")' 2>/dev/null || true)
    fi
    if [ "${NPEND:-0}" != "0" ]; then
      MSG="[guppi-platform] UNCAPTURED WORK (${NPEND}): ${LIST}. These exist only as local files and violate RULE-013. Run '/wheel capture <file>' for each (wheel: ${INIT})."
    else
      MSG="[guppi-platform] Phase: ${PHASE} | Wheel: ${INIT} | No uncaptured deliverables."
    fi
    printf '{"decision": "allow", "systemMessage": "%s"}\n' "$(jesc "$MSG")"
    exit 0
    ;;

  *)
    allow
    ;;
esac
