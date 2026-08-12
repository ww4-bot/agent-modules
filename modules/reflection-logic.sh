# shellcheck shell=bash
# ── Stop hook: automatic self-improvement checkpoint ─────────────────────────
#
# Appended to a generated header defining: AGENT_USER OPERATOR SESSION_N OPEN_CAP
#
# Two deterministic checkpoints:
#   1. CAPTURE — at session stop, scan the transcript's HUMAN messages for
#      steering markers. If the operator steered and nothing was written to
#      memory or the friction-log, block the stop once and make it capture.
#      This is the loop's front door; capture used to be pure vigilance, and
#      "sometimes I have to prompt for things to be remembered" was the
#      recurring complaint.
#   2. DISTILL — on a cadence, force a brief /retro so logged friction becomes
#      fixes.
#
# SAFETY: this is a NUDGE, not a privilege. Worst case if it misfires is a
# little wasted reflection. It is loop-safe (stop_hook_active), headless-safe
# (CLAUDE_AUTONOMOUS=1 no-ops, so a scheduled run is never derailed), and fires
# at most once per session. The cadence state file is agent-writable on purpose
# — it is a reminder counter, not a security control; resetting it only makes
# the agent reflect LESS, which hurts only itself.

STATE="$HOME/.claude/reflection-state"

# Host-global settings: no-op for anyone who is not the agent.
[ "$(id -un 2>/dev/null)" = "$AGENT_USER" ] || exit 0

MARKERS='remember (this|that|to)|don'"'"'?t forget|i (told|asked) you|i said|you (forgot|missed|keep|should have)|why did(n'"'"'?t)? you|not what i|no[,.] (that|this|you)|instead,|stop (doing|asking)|please stop|that'"'"'?s (wrong|not right)|i have to (prompt|remind|keep)'

input="$(cat)"

# Loop guard: don't re-fire while the model is already continuing due to us.
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
# Headless guard: never derail a scheduled run.
[ -n "${CLAUDE_AUTONOMOUS:-}" ] && exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"

fl="$(find "$HOME/.claude/projects" -name friction-log.md 2>/dev/null | head -1 || true)"
open=0
[ -n "$fl" ] && open="$(awk '/^## Open/{f=1;next} /^## /{f=0} f && /^- \[/{c++} END{print c+0}' "$fl")"

session_count=0; last_session=""; last_reflect=0; reminded_in=""; captured_in=""
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE" 2>/dev/null || true

save_state() {
  { echo "session_count=$session_count"; echo "last_session=$last_session"
    echo "last_reflect=$last_reflect"; echo "reminded_in=$reminded_in"
    echo "captured_in=$captured_in"; } > "$STATE"
}

if [ "$sid" != "$last_session" ]; then
  session_count=$((session_count + 1)); last_session="$sid"
fi

# ── CAPTURE ─────────────────────────────────────────────────────────────────
# The distillation cadence below only counts friction ALREADY logged — it
# cannot recover a lesson never captured. This closes that gap mechanically.
if [ "$captured_in" != "$sid" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  hits="$(grep '"type":"user"' "$transcript" 2>/dev/null | grep -v 'tool_use_id' | grep -icE "$MARKERS" || true)"
  already="$(grep -cE '"file_path":"[^"]*(/memory/|friction-log)[^"]*"' "$transcript" 2>/dev/null || true)"
  if [ "${hits:-0}" -ge 1 ] && [ "${already:-0}" -eq 0 ]; then
    captured_in="$sid"; save_state
    jq -n --arg op "$OPERATOR" '{decision:"block", reason:("Capture checkpoint: this session contains messages from " + $op + " that look like steering, a correction, or a remember-this. Before stopping: (1) if they stated a preference or corrected you, save/update the memory NOW (and the friction-log if you were steered); (2) if the match is a false positive, just stop — no note needed. Be brief; do not redo task work.")}'
    exit 0
  fi
fi

[ "$reminded_in" = "$sid" ] && { save_state; exit 0; }

since=$((session_count - last_reflect))
trigger=0; reason=""
if [ "$open" -ge "$OPEN_CAP" ]; then
  trigger=1
  reason="Self-improvement checkpoint: the friction-log has ${open} OPEN items — enough to be worth distilling. Before wrapping up, run /retro: turn the open friction into fixes (a playbook, a memory lesson, a docs fix, or — for anything needing new power — a gated PR plus an open-loops entry). Keep it honest and brief. If now genuinely isn't the moment, note why and continue."
elif [ "$open" -ge 1 ] && [ "$since" -ge "$SESSION_N" ]; then
  trigger=1
  reason="Self-improvement checkpoint: it's been ${since} sessions since the last reflection and there are ${open} open friction-log item(s) waiting. Run /retro now — distill them into fixes you own (playbook/memory/docs) or a gated PR for anything needing approval. Brief and honest; skip with a one-line why if truly not the time."
fi

if [ "$trigger" = "1" ]; then
  reminded_in="$sid"; last_reflect="$session_count"; save_state
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
  exit 0
fi

save_state
exit 0
