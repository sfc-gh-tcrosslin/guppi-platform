#!/usr/bin/env bash
# guppi-platform — git pre-push hook
# Enforces that every commit being pushed contains a Wheel: INIT-N or Wheel: NONE footer.
# Install: cp hooks/pre-push.sh .git/hooks/pre-push && chmod +x .git/hooks/pre-push
# Override: include "Wheel: NONE; reason: <text>" in commit message (logged in drift report).

set -euo pipefail

# stdin = lines: <local_ref> <local_sha> <remote_ref> <remote_sha>
# Read what's being pushed
EXIT_CODE=0
ORPHAN_COMMITS=()

while read -r local_ref local_sha remote_ref remote_sha; do
  if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
    # Branch deletion - skip
    continue
  fi

  if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
    # New branch - check all commits unique to this push
    RANGE="$local_sha"
    COMMITS=$(git rev-list "$RANGE" --not --remotes 2>/dev/null || git rev-list "$RANGE" -n 50)
  else
    RANGE="${remote_sha}..${local_sha}"
    COMMITS=$(git rev-list "$RANGE")
  fi

  for commit in $COMMITS; do
    MSG=$(git log -1 --format=%B "$commit")
    # Match either Wheel: INIT-NNN or explicit override
    if echo "$MSG" | grep -qE '^Wheel: (INIT-[0-9]+|NONE)'; then
      continue
    fi
    SHORT=$(git log -1 --format='%h %s' "$commit")
    ORPHAN_COMMITS+=("$SHORT")
    EXIT_CODE=1
  done
done

if [ ${#ORPHAN_COMMITS[@]} -gt 0 ]; then
  echo ""
  echo "  ===== guppi-platform pre-push: WHEEL FOOTER MISSING =====" >&2
  echo "  RULE-013/014: every commit on guppi-platform must reference a wheel initiative." >&2
  echo "  Add a 'Wheel: INIT-N' footer to each commit message before pushing." >&2
  echo "  To explicitly opt out (logged in drift report): 'Wheel: NONE; reason: <text>'." >&2
  echo "" >&2
  echo "  Orphan commits:" >&2
  for c in "${ORPHAN_COMMITS[@]}"; do
    echo "    $c" >&2
  done
  echo "" >&2
  echo "  Fix:" >&2
  echo "    git rebase -i <base>" >&2
  echo "    # for each orphan commit, change 'pick' to 'reword', save," >&2
  echo "    # then append:  Wheel: INIT-N" >&2
  echo "" >&2
fi

exit $EXIT_CODE
