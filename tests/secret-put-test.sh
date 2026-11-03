# secret-put behaviour matrix. Runs each case under a pty (`script`), because
# the tool deliberately reads from /dev/tty and refuses without one.
#   bash secret-put-test.sh /path/to/secret-put WORKDIR
set -u
SP=$1; T=$2; mkdir -p "$T"; cd "$T" || exit 1
pass=0 fail=0
run() { printf "$1" | script -qec "$2" /dev/null 2>&1 | tr -d '\r'; return "${PIPESTATUS[1]}"; }
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
TOK=abcdefghijabcdefghijabcdefghijabcdefghij

out=$(run "$TOK\r\n" "$SP $T/tok --len 40")
[[ $(wc -c < tok) == 40 && $out == *"OK $T/tok  40 bytes"* ]] && ok "bare: CRLF stripped, 40 bytes" || bad "bare CRLF ($out)"
[[ $out != *"$TOK"*"OK"* || $(grep -c "OK.*$TOK" <<<"$out") == 0 ]] && ok "OK line carries no value" || bad "value in OK line"

run "short\nn\n" "$SP $T/tok --len 40" >/dev/null; rc=$?
[[ $rc != 0 && $(cat tok) == "$TOK" ]] && ok "length mismatch declined, file untouched" || bad "decline (rc=$rc)"

run "sk-other-1\ny\n" "$SP $T/tok2 --len 40 --prefix sk-api" >/dev/null
[[ $(cat tok2) == sk-other-1 ]] && ok "shape mismatch can be accepted" || bad "accept"

printf 'A=1\n# comment\nB=keep' > x.env; chmod 640 x.env
run 'p$ss"w0rd&x\n' "$SP $T/x.env --env PASS" >/dev/null
[[ $(stat -c %a x.env) == 640 ]] && ok "env: mode kept" || bad "env mode"
grep -qx '# comment' x.env && grep -qx 'B=keep' x.env && ok "env: other lines kept" || bad "env lines"
[[ $(bash -c "set -a; . $T/x.env; printf %s \"\$PASS\"") == 'p$ss"w0rd&x' ]] && ok "env: special chars read back exactly" || bad "env readback"
run "newer\n" "$SP $T/x.env --env A" >/dev/null
[[ $(grep -c '^A=' x.env) == 1 ]] && grep -qx 'A=newer' x.env && ok "env: key replaced, not duplicated" || bad "env replace"

run "it's\n" "$SP $T/x.env --env Q" >/dev/null; rc=$?
[[ $rc != 0 ]] && ! grep -q '^Q=' x.env && ok "single quote refused" || bad "quote"

c=$("$SP" --check "$T/x.env")
[[ $c != *newer* && $c != *w0rd* && $c == *"PASS"*"11 chars"* ]] && ok "--check env: lengths, no values" || bad "check env ($c)"
printf 'dGVzdA==' > b64
c=$("$SP" --check "$T/b64")
[[ $c != *dGVzdA* && $c == *"trailing newline: no"* ]] && ok "--check bare base64: no content shown" || bad "check b64 ($c)"

mkdir ro; chmod 555 ro
out=$(run "" "$SP $T/ro/x"); rc=$?
[[ $rc != 0 && $out == *"cannot write"* && $out != *Paste* ]] && ok "unwritable dir refused before prompt" || bad "unwritable ($out)"
out=$(run "" "$SP $T/o --owner root")
if [[ $(id -u) != 0 ]]; then
  [[ $out == *"need root"* && $out != *Paste* ]] && ok "--owner as non-root refused before prompt" || bad "owner ($out)"
fi
run "\n" "$SP $T/e" >/dev/null; rc=$?
[[ $rc != 0 && ! -e e ]] && ok "empty paste refused" || bad "empty"
[[ -z $(find . -name '.secret-put.*') ]] && ok "no temp files left" || bad "temp files"

echo "pass=$pass fail=$fail"
[[ $fail == 0 ]]
