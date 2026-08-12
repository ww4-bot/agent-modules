#!/usr/bin/env bash
# Run TSV cases against a guard.
#
#   guard-test.sh <guard-path> <cases.tsv> [cwd]
#
# TSV format: expect<TAB>label<TAB>command   (\n in the command = newline)
# `expect` is `deny` or `pass`.
#
# The optional third argument is the cwd presented to the guard. It matters:
# the delete fence permits deletes only from inside the agent's workspace, so
# running the matrix with the wrong cwd produces confusing mass failures rather
# than a real signal. Defaults to the agent's home.
set -uo pipefail

GUARD="${1:?guard path}"
CASES="${2:?tsv path}"
CWD="${3:-/home/claude}"

pass=0; fail=0
while IFS=$'\t' read -r expect label raw; do
  # Skip blanks and comments so a cases file can be annotated.
  [ -z "${expect:-}" ] && continue
  case "$expect" in \#*) continue ;; esac

  cmd=$(printf '%b' "$raw")
  out=$(jq -n --arg c "$cmd" --arg d "$CWD" \
        '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | bash "$GUARD" 2>/dev/null)

  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    got=deny
    why=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | cut -c1-48)
  else
    got=pass; why=""
  fi

  if [ "$got" = "$expect" ]; then
    printf '  [OK]   %-46s %s\n' "$label" "$got"
    pass=$((pass+1))
  else
    printf '  [BAD]  %-46s got=%s want=%s %s\n' "$label" "$got" "$expect" "$why"
    fail=$((fail+1))
  fi
done < "$CASES"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
