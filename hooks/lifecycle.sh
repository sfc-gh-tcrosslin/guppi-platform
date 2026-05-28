#!/usr/bin/env bash
# CoCo Platform — Lifecycle Hook State Machine
# Manages phase tracking, write-gating, and session resume.

set -euo pipefail

STATE_FILE="${CORTEX_PROJECT_DIR:-.}/.cortex-plugin/.state.json"
EVENT="$1"

ensure_state() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<'INIT'
{
  "phase": "ad-hoc",
  "refs_read": [],
  "active_skill": null,
  "last_updated": null
}
INIT
  fi
}

read_state() {
  ensure_state
  cat "$STATE_FILE"
}

case "$EVENT" in
  session-start)
    ensure_state
    STATE=$(read_state)
    PHASE=$(echo "$STATE" | jq -r '.phase // "ad-hoc"')
    SKILL=$(echo "$STATE" | jq -r '.active_skill // "none"')
    
    cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[coco-platform] Session resumed. Phase: ${PHASE} | Active skill: ${SKILL} | State file: ${STATE_FILE}"
}
EOF
    ;;

  pre-write)
    STATE=$(read_state)
    SKILL=$(echo "$STATE" | jq -r '.active_skill // empty')
    REFS_READ=$(echo "$STATE" | jq -r '.refs_read | length')
    
    # If no skill active or in ad-hoc/hotfix mode, allow all writes
    if [ -z "$SKILL" ] || [ "$SKILL" = "null" ] || [ "$SKILL" = "hotfix" ]; then
      echo '{"decision": "allow"}'
      exit 0
    fi

    # For gated skills, check if references have been consumed
    # Skills that require reference reading before writes:
    GATED_SKILLS="clinical-outcome-predictor|snowflake-health-data-forge|ontology-builder|coco-enterprise-pipeline"
    
    if echo "$SKILL" | grep -qE "$GATED_SKILLS"; then
      if [ "$REFS_READ" -lt 1 ]; then
        cat <<EOF
{
  "decision": "block",
  "reason": "[coco-platform] Write blocked: skill '${SKILL}' requires reading reference docs first. Use Read tool on the skill's references/ directory."
}
EOF
        exit 2
      fi
    fi

    echo '{"decision": "allow"}'
    ;;

  post-skill)
    # Read stdin for tool input/output context
    INPUT=$(cat)
    SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.name // "unknown"' 2>/dev/null || echo "unknown")
    
    ensure_state
    # Update active skill in state
    jq --arg skill "$SKILL_NAME" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.active_skill = $skill | .last_updated = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    
    echo '{"decision": "allow"}'
    ;;

  stop)
    STATE=$(read_state)
    PHASE=$(echo "$STATE" | jq -r '.phase // "ad-hoc"')
    SKILL=$(echo "$STATE" | jq -r '.active_skill // "none"')
    REFS=$(echo "$STATE" | jq -r '.refs_read | length')
    
    cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[coco-platform] Phase: ${PHASE} | Skill: ${SKILL} | Refs read: ${REFS}"
}
EOF
    ;;

  *)
    echo '{"decision": "allow"}'
    ;;
esac
