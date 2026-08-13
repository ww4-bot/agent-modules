# shellcheck shell=bash
# ── PreToolUse guard: LOGIC ──────────────────────────────────────────────────
#
# This file is appended to a generated PROFILE block that defines:
#   AGENT_USER PROTECTED_BRANCH WORKSPACE OPERATOR
#   PROTECTED_PATHS[] WRITABLE_PATHS[] APPLY_COMMANDS[]
#
# It is deliberately NOT a template. Every fence below encodes a specific
# incident, and the 50-case adversarial matrix in tests/ is what proves they
# still fire. Change the profile, not this file. If this file must change, the
# matrix runs in CI and in the module's own check — a fence that stops firing
# looks exactly like a fence that was never needed.

deny() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

input="$(cat)"
tool="$(printf '%s' "$input"  | jq -r '.tool_name // empty')"
cmd="$(printf '%s' "$input"   | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$input"   | jq -r '.cwd // empty')"

# ── AGENT-SCOPE GUARD ───────────────────────────────────────────────────────
# Managed settings are HOST-GLOBAL: this hook runs for EVERY Claude Code session
# on the box, including the operator's own. That is wrong here — the fences are
# written around the AGENT's workspace, and applied to the operator they
# misfire: the delete fence protects their home, so they would be denied
# deleting their own files in their own session.
#
# The operator is not the threat model. They have real sudo; a PreToolUse hook
# was never what stood between them and the disk.
[ "$(id -un 2>/dev/null)" = "$AGENT_USER" ] || { printf '{}'; exit 0; }

# Only guard Bash; other tools are governed by the settings allow/deny lists.
[ "$tool" = "Bash" ] || { printf '{}'; exit 0; }

# ── Operand isolation ───────────────────────────────────────────────────────
# Several fences used to substring-match the WHOLE command line, producing a
# steady stream of false denials on benign work: a /dev/null redirect, a system
# path in a SEPARATE pipeline stage, a read-only `grep -ciE 'token|secret|passwd'`,
# and — the case that proves the point — a command containing no delete at all,
# denied because heredoc prose DESCRIBING this guard mentioned the tokens it
# matches on. A fence cannot tell a command from a description of a command
# unless it looks at command structure.
#
# These helpers are deliberately crude and FAIL CLOSED: when in doubt they keep
# more text, so a fence errs toward denying.

# Remove heredoc BODIES (data, not commands). FAILS CLOSED on an unterminated
# heredoc: the original text is returned rather than swallowing everything after
# it — caught by the corpus, where `cat <<EOF\ntext\nrm -rf /etc` slipped past
# because with no terminator the delete looked like body.
strip_heredocs() {
  printf '%s' "$1" | awk -v orig="$1" '
    BEGIN { term = ""; open = 0 }
    {
      if (term != "") {
        line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == term) { term = ""; open = 0 }
        next
      }
      if (match($0, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
        t = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", t); gsub(/['"'"'"]/, "", t)
        term = t; open = 1
      }
      buf = buf $0 "\n"
    }
    END { if (open) printf "%s", orig; else printf "%s", buf }'
}

# Turn shell punctuation into spaces and pad the ends, so a verb is detectable
# however it is wrapped. `eval "rm -rf /etc"` and `x=$(rm -rf /etc)` both become
# ` rm -rf /etc `. Without this the delete trigger needed a literal leading
# space, so BOTH slipped past — as did a leading `shred`.
#
# Newlines become " ; " rather than vanishing: a command at the START of a line
# is still a command, and it keeps `;` as a segment boundary.
normalize_ops() {
  # tr, not sed: sed treats a \001 escape as a back-reference, which silently
  # DELETED the separator and glued `<<EOF` onto the next command.
  printf ' %s ' "$(printf '%s' "$1" \
    | tr '\n\t' '; ' \
    | sed -e 's/[`"'"'"'(){}$]/ /g' -e 's/;/ ; /g')"
}

# Break a line into individual invocations on shell separators, so a fence can
# ask "does the segment that actually runs rm reference a protected path?"
# instead of "does any token anywhere look scary?".
split_segments() {
  printf '%s' "$1" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g'
}

# Blank quoted literals. A quoted string is DATA, never a command name. Without
# this, splitting on `|` tears a quoted regex apart: `grep -E 'token|secret|passwd'`
# produced a synthetic segment that was literally the word `passwd`, which then
# matched the credential fence.
strip_quoted() {
  printf '%s' "$1" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g'
}

cmd_nodoc="$(strip_heredocs "$cmd")"
cmd_norm="$(normalize_ops "$cmd_nodoc")"

# ── Catastrophic deletes — always, everywhere ───────────────────────────────
case "$cmd" in
  *"rm -rf /"|*"rm -fr /"|*"rm -rf / "*|*"rm -fr / "*|*"rm -rf /*"*|*"rm -rf ~"*|*"rm -fr ~"*|*'rm -rf $HOME'*)
    deny "Catastrophic delete pattern — never." ;;
esac

# ── Deletes: permitted only INSIDE the agent's workspace ────────────────────
case "$cmd_norm" in
  *" rm "*|*" -delete "*|*" -delete"|*" unlink "*)
    del_segs="$(split_segments "$cmd_norm" | grep -E '(^|[[:space:]])(rm|unlink)([[:space:]]|$)|-delete|-exec[[:space:]]+rm' || true)"
    # Fail closed: if splitting yielded nothing while the trigger matched, scan all.
    [ -n "$del_segs" ] || del_segs="$cmd_norm"

    # The sudo test runs against the DELETE SEGMENTS, not the whole line.
    # It used to be whole-line, which denied any command that merely contained
    # `sudo` anywhere alongside an unrelated `rm`. That produced repeat false
    # positives across three sessions — most recently blocking
    #   ssh host 'sudo -n cat file' > local ; ... ; rm -f /tmp/scratch
    # where the sudo was a REMOTE read on another machine and the rm was my own
    # scratch file. PR #100 scoped the PATH check this way and left this one
    # behind; this completes that fix.
    # A chained `ls && sudo rm /etc/x` is still caught, because the sudo lives
    # in the same segment as the delete — which is the case that matters.
    if printf '%s' "$del_segs" | grep -qE '(^|[[:space:]])sudo([[:space:]]|$)'; then
      deny "Deleting as root is ${OPERATOR}-only — route via a PR."
    fi
    scrub="$del_segs"
    for w in ${WRITABLE_PATHS[@]+"${WRITABLE_PATHS[@]}"}; do
      scrub="${scrub//"$w"/__WRITABLE__}"
    done
    # /dev/null redirects are I/O plumbing, not delete operands. Only redirect
    # forms are scrubbed; a literal `rm /dev/null` keeps its /dev and is denied.
    scrub="${scrub//2>\/dev\/null/}"; scrub="${scrub//2> \/dev\/null/}"
    scrub="${scrub//&>\/dev\/null/}"; scrub="${scrub//&> \/dev\/null/}"
    scrub="${scrub//>>\/dev\/null/}"; scrub="${scrub//>\/dev\/null/}"; scrub="${scrub//> \/dev\/null/}"
    for p in ${PROTECTED_PATHS[@]+"${PROTECTED_PATHS[@]}"}; do
      case "$scrub" in
        *"$p"*) deny "That delete reaches outside your ${WORKSPACE} workspace — make the change via a PR, or ask ${OPERATOR}." ;;
      esac
    done
    case "$scrub" in
      *"..") deny "That delete reaches outside your ${WORKSPACE} workspace — make the change via a PR, or ask ${OPERATOR}." ;;
    esac
    case "$cwd" in
      "$WORKSPACE"|"$WORKSPACE"/*|/tmp|/tmp/*) : ;;
      *)
        _ok=0
        for w in ${WRITABLE_PATHS[@]+"${WRITABLE_PATHS[@]}"}; do
          case "$cwd" in "$w"|"$w"/*) _ok=1 ;; esac
        done
        [ "$_ok" = "1" ] || deny "Delete from a non-workspace directory (cwd=$cwd) — cd into ${WORKSPACE}, or ask ${OPERATOR}." ;;
    esac
    ;;
  *" shred "*|*" truncate "*) deny "In-place destroy (shred/truncate) — make the change via a PR, or ask ${OPERATOR}." ;;
esac

# ── Credential changes: match the COMMAND, not the word ─────────────────────
# `passwd` used to be a whole-line match, so a read-only
# `grep -ciE 'token|secret|passwd' file` got denied as a credential change.
# Scanning FOR credential words is the opposite of changing one.
cred_hit="$(split_segments "$(strip_quoted "$cmd_nodoc")" \
  | sed -e 's/^[[:space:]]*//' \
  | grep -E '^(sudo[[:space:]]+)?(userdel|useradd|usermod|passwd|chpasswd|gpasswd)([[:space:]]|$)' || true)"
[ -z "$cred_hit" ] || deny "Account/credential change — ${OPERATOR} only."
# The shadow file keeps a whole-line match: no benign reason to touch it, so a
# false positive costs nothing and a miss costs a lot.
case "$cmd_nodoc" in *"/etc/shadow"*) deny "Account/credential change — ${OPERATOR} only." ;; esac

# ── Config-apply commands ───────────────────────────────────────────────────
# Applying is what happens AFTER a merge. An agent that can apply its own
# proposals has no gate at all.
for a in ${APPLY_COMMANDS[@]+"${APPLY_COMMANDS[@]}"}; do
  apply_hit="$(split_segments "$(strip_quoted "$cmd_nodoc")" \
    | sed -e 's/^[[:space:]]*//' \
    | grep -E "^(sudo[[:space:]]+)?${a}([[:space:]]|\$)" || true)"
  [ -z "$apply_hit" ] || deny "\`${a}\` applies config to live systems — that is a post-merge action for ${OPERATOR}, not a session action. Open a PR."
done

# ── Disk / format ops ───────────────────────────────────────────────────────
# Matched against $cmd_norm, NOT $cmd_nodoc. These patterns need a leading
# space, and only the normalised view is space-padded — so against un-normalised
# text a command STARTING with the verb slipped through entirely:
# `parted /dev/sdb mklabel gpt` was PERMITTED, as were leading `fdisk` and
# `wipefs`. (`dd` was masked by the of=/dev/ pattern and `mkfs` has no leading
# space in its pattern, which is why this went unnoticed for months.)
# Found by the test matrix 2026-08-10; the same hole exists in gromit's live
# guard and is queued as a gated backport.
case "$cmd_norm" in
  *mkfs*|*" dd "*|*"of=/dev/"*|*" wipefs"*|*" fdisk"*|*" parted"*)
    deny "Disk/format op — must be run by ${OPERATOR}." ;;
  *">/dev/sd"*|*"> /dev/sd"*|*">/dev/nvme"*|*"> /dev/nvme"*)
    deny "Raw block-device write — ${OPERATOR} only." ;;
esac

# ── Pushes to the protected branch ──────────────────────────────────────────
case "$cmd_nodoc" in
  *"git push"*)
    # Match the push REFSPEC, not the branch name anywhere on the line. The old
    # rule was whole-line, so a chained `git switch main`, a push to a non-main
    # branch (`main:testing`), an echo mentioning main, or a heredoc body all
    # tripped it. Scope to the push invocation.
    seg="${cmd##*git push}"
    seg="${seg%%[;&|]*}"
    seg="${seg%%$'\n'*}"
    case "$seg" in
      *":${PROTECTED_BRANCH}"|*":${PROTECTED_BRANCH} "*|*" ${PROTECTED_BRANCH}"|*" ${PROTECTED_BRANCH} "*)
        deny "Direct push to ${PROTECTED_BRANCH} — open a PR; ${OPERATOR} merges." ;;
    esac
    case "$seg" in
      *"--force"*|*" -f "*|*" -f")
        case "$seg" in
          *":${PROTECTED_BRANCH}"|*":${PROTECTED_BRANCH} "*|*" ${PROTECTED_BRANCH}"|*" ${PROTECTED_BRANCH} "*)
            deny "Force-push to ${PROTECTED_BRANCH} is never allowed." ;;
        esac ;;
    esac
    ;;
esac

# Everything else: defer to the settings allow/ask/deny lists. We deliberately
# never auto-"allow" from here.
printf '{}'
exit 0
