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
  "systemMessage": "[guppi-platform] Session resumed. Phase: ${PHASE} | Active skill: ${SKILL} | State file: ${STATE_FILE}. [radar] Session-start check: query new items (GUPPIWHEEL.PUBLIC.RADAR_ITEMS WHERE DELIVERED=FALSE ORDER BY FOUND_AT DESC); if any, summarize them for the user and offer the rolling feed (CALL GUPPIWHEEL.PUBLIC.GET_ARTIFACT_LAUNCH('NAR-RADAR')), then UPDATE those rows SET DELIVERED=TRUE. If none, stay silent."
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
  "reason": "[guppi-platform] Write blocked: skill '${SKILL}' requires reading reference docs first. Use Read tool on the skill's references/ directory."
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
    INIT=$(echo "$STATE" | jq -r '.current_initiative // "none"')
    
    cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[guppi-platform] Phase: ${PHASE} | Skill: ${SKILL} | Refs read: ${REFS} | Wheel: ${INIT}"
}
EOF
    ;;

  post-create-plan)
    # Scope guard: only nag when working in guppi-platform repo
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ "$REPO_ROOT" != *guppi-platform* ]]; then
      echo '{"decision": "allow"}'
      exit 0
    fi

    # When create_plan tool fires, capture the plan name and offer to publish to wheel.
    # Stdin has tool_input + tool_response from the create_plan call.
    INPUT=$(cat)
    PLAN_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null)
    
    if [ -z "$PLAN_NAME" ]; then
      echo '{"decision": "allow"}'
      exit 0
    fi
    
    # Find the just-written plan file
    PLAN_DIR="${HOME}/.snowflake/cortex/plans"
    PLAN_FILE="${PLAN_DIR}/${PLAN_NAME}.plan.md"
    if [ ! -f "$PLAN_FILE" ]; then
      # Could also be in playground workspace
      PLAN_FILE="${HOME}/.snowflake/cortex/playground/workspace/.snowflake/cortex/plans/${PLAN_NAME}.plan.md"
    fi
    
    STATE=$(read_state)
    CURRENT_INIT=$(echo "$STATE" | jq -r '.current_initiative // empty')
    
    if [ -f "$PLAN_FILE" ] && [ -n "$CURRENT_INIT" ]; then
      cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[guppi-platform] Plan '${PLAN_NAME}' created. Reminder: publish as NARRATIVE under ${CURRENT_INIT} via 'snow sql -q \"CALL GUPPIWHEEL.PUBLIC.PUBLISH_ARTIFACT(...)\"' or use /wheel publish-plan."
}
EOF
    elif [ -f "$PLAN_FILE" ]; then
      cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[guppi-platform] Plan '${PLAN_NAME}' created. No active initiative set. RULE-013 reminder: publish this plan as a NARRATIVE under an INITIATIVE in the wheel. Use '/wheel start' to open one, or '/wheel publish-plan' to manually narrative."
}
EOF
    else
      echo '{"decision": "allow"}'
    fi
    ;;

  post-switch-mode)
    # Scope guard: only nag when working in guppi-platform repo
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ "$REPO_ROOT" != *guppi-platform* ]]; then
      echo '{"decision": "allow"}'
      exit 0
    fi

    # When switch_mode fires, especially plan -> agent, remind about wheel discipline.
    INPUT=$(cat)
    TARGET=$(echo "$INPUT" | jq -r '.tool_input.target_mode_id // empty' 2>/dev/null)
    
    if [ "$TARGET" != "agent" ]; then
      echo '{"decision": "allow"}'
      exit 0
    fi
    
    STATE=$(read_state)
    CURRENT_INIT=$(echo "$STATE" | jq -r '.current_initiative // empty')
    
    if [ -z "$CURRENT_INIT" ]; then
      cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[guppi-platform] Switched to agent mode without an active initiative. RULE-013/014 reminder: every meaningful work session opens with SUBMIT_INITIATIVE. Use /wheel start to open one before substantial changes."
}
EOF
    else
      cat <<EOF
{
  "decision": "allow",
  "systemMessage": "[guppi-platform] Executing under ${CURRENT_INIT}. Output should land as artifacts in the wheel."
}
EOF
    fi
    ;;

  *)
    echo '{"decision": "allow"}'
    ;;
esac
