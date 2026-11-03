# secret-put — place a secret in a file without it touching the screen, the
# command line, shell history or a hand-held editor.
#
# Why this exists: every secret failure on record was plumbing, not a leak into
# chat (2026-08 → 2026-11). A `read -rs` mid-paste stored the *next command* as
# the token; `sudo cat >` as the wrong user ran the token as a command and put it
# in bash history; "press Enter, then Ctrl-D" and nano made a 40-byte token 41;
# a .env sourced as shell choked on a `$` and printed half a password. This tool
# is one command, alone in its block, that cannot do any of those things.
#
#   secret-put PATH [--env KEY] [--owner U] [--group G] [--mode M]
#                   [--len N] [--prefix P]
#   secret-put --check PATH [--env ANY]   (env view if PATH ends .env or --env given)
#
# Bare mode (default): PATH's whole contents become the secret, no newline.
# --env KEY: set KEY=value in a KEY=value file, keeping every other line.
# --len / --prefix: shape checks. A mismatch asks before writing rather than
# refusing, because a check written from stale knowledge (sk-ant-api vs
# sk-ant-usr, 2026-10-22) must not block a valid secret.
# --check: print metadata only — owner, mode, size, trailing newline, and for an
# env file each key with its value's length. Never a character of a value.
#
# Prints one line starting OK or NOT WRITTEN. On any failure nothing is written.

set -euo pipefail
umask 077

die() { printf 'NOT WRITTEN: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n 's/^#   //p' "$0" >&2 || true
  exit 2
}

meta() {  # owner:group mode
  stat -c '%U:%G %a' "$1"
}

check() {
  local f=$1
  [[ -e $f ]] || die "$f does not exist"
  [[ -r $f ]] || die "$f exists but is not readable by $(id -un); try sudo"
  local size nl=no
  size=$(stat -c %s "$f")
  if (( size > 0 )) && [[ $(tail -c1 "$f" | od -An -c | tr -d ' ') == '\n' ]]; then
    nl=yes
  fi
  # Env parsing only on an explicit signal. Guessing from contents would print
  # the head of a bare base64 token ("dGVzdA==") as if it were a key name.
  if [[ -n $key || $f == *.env || $f == *.env.* ]]; then
    printf '%s  %s  %s bytes  env file:\n' "$f" "$(meta "$f")" "$size"
    # Key names and value lengths only. awk never prints $0.
    awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {
      k=$1; v=substr($0, length(k)+2)
      if (v ~ /^\x27.*\x27$/ || v ~ /^".*"$/) v=substr(v, 2, length(v)-2)
      printf "  %-32s %s\n", k, (length(v) ? length(v) " chars" : "EMPTY")
    }' "$f"
  else
    printf '%s  %s  %s bytes  trailing newline: %s\n' "$f" "$(meta "$f")" "$size" "$nl"
  fi
}

path="" key="" owner="" group="" mode="" want_len="" want_prefix="" do_check=0
while (( $# )); do
  case $1 in
    --check)  do_check=1 ;;
    --env)    key=${2:?--env needs a KEY}; shift ;;
    --owner)  owner=${2:?}; shift ;;
    --group)  group=${2:?}; shift ;;
    --mode)   mode=${2:?}; shift ;;
    --len)    want_len=${2:?}; shift ;;
    --prefix) want_prefix=${2:?}; shift ;;
    -h|--help) usage ;;
    -*)       die "unknown option $1" ;;
    *)        [[ -z $path ]] || die "one PATH only"; path=$1 ;;
  esac
  shift
done
[[ -n $path ]] || usage

if (( do_check )); then check "$path"; exit 0; fi

[[ -z $key || $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--env KEY must be a shell-style name"
[[ -z $mode || $mode =~ ^0?[0-7]{3}$ ]] || die "--mode must be octal, e.g. 0400"
[[ -z $want_len || $want_len =~ ^[0-9]+$ ]] || die "--len must be a number"

# Every check that can fail happens BEFORE the prompt, so a wrong user or a
# missing sudo never leaves a pasted secret sitting at a shell prompt.
dir=$(dirname -- "$path")
[[ -d $dir ]] || die "directory $dir does not exist"
[[ -w $dir ]] || die "$(id -un) cannot write $dir — run with sudo (and check you are the right user)"
if [[ -n $owner || -n $group ]] && (( EUID != 0 )); then
  die "--owner/--group need root — run with sudo"
fi
[[ -e $path && ! -f $path ]] && die "$path exists and is not a regular file"
if [[ -n $key && -e $path ]]; then
  [[ -r $path ]] || die "cannot read existing $path to keep its other lines"
fi
[[ -t 0 || -r /dev/tty ]] || die "no terminal to read from"

# Keep the existing file's ownership and mode unless told otherwise.
if [[ -e $path ]]; then
  read -r cur_owner cur_mode < <(stat -c '%U:%G %a' "$path")
  [[ -n $owner ]] || owner=${cur_owner%%:*}
  [[ -n $group ]] || group=${cur_owner#*:}
  [[ -n $mode  ]] || mode=$cur_mode
fi
mode=${mode:-0400}

label=${key:-$(basename -- "$path")}
IFS= read -rsp "Paste $label (hidden), then press Enter: " secret < /dev/tty || die "no input"
printf '\n' >&2
# Strip every CR, LF, tab and space: a pasted secret never legitimately has them,
# and a trailing newline is the classic 41-byte token.
secret=${secret//[$'\r\n\t ']/}
[[ -n $secret ]] || die "nothing pasted"

warn=""
if [[ -n $want_len && ${#secret} -ne $want_len ]]; then
  warn+="length is ${#secret}, expected $want_len. "
fi
if [[ -n $want_prefix && $secret != "$want_prefix"* ]]; then
  warn+="does not start with $want_prefix. "
fi
if [[ -n $warn ]]; then
  read -rp "Check: ${warn% } Write it anyway? [y/N] " ans < /dev/tty || ans=""
  [[ $ans == [yY] ]] || { unset secret; die "declined — $warn"; }
fi

if [[ -n $key && $secret == *"'"* ]]; then
  unset secret
  die "the value contains a single quote, which no .env reader handles the same way; store it as a bare file instead"
fi

tmp=$(mktemp -- "$dir/.secret-put.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

if [[ -z $key ]]; then
  printf '%s' "$secret" > "$tmp"
else
  # Unquoted when every character is inert; single-quoted otherwise. Both read
  # back identically under systemd EnvironmentFile, python-dotenv and bash.
  if [[ $secret =~ ^[A-Za-z0-9._~+/=:@%,-]+$ ]]; then line="$key=$secret"; else line="$key='$secret'"; fi
  if [[ -e $path ]]; then
    grep -vE "^${key}=" -- "$path" > "$tmp" || true
    # Make sure the kept lines end in a newline before appending.
    [[ ! -s $tmp || $(tail -c1 "$tmp" | od -An -c | tr -d ' ') == '\n' ]] || printf '\n' >> "$tmp"
  fi
  printf '%s\n' "$line" >> "$tmp"
  unset line
fi
n=${#secret}
unset secret

chmod "$mode" -- "$tmp"
if [[ -n $owner || -n $group ]]; then chown -- "${owner:-root}${group:+:$group}" "$tmp"; fi
mv -f -- "$tmp" "$path"
trap - EXIT

if [[ -n $key ]]; then
  printf 'OK %s  %s=<%s chars>  %s\n' "$path" "$key" "$n" "$(meta "$path")"
else
  printf 'OK %s  %s bytes  %s\n' "$path" "$(stat -c %s "$path")" "$(meta "$path")"
fi
