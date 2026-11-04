---
name: step-by-step
description: "How to hand Chris steps he carries out himself: commands to paste on a host or router, admin-panel/GUI steps, getting or placing a secret, or reporting a value back. Load BEFORE writing any such handoff — including a single command block for him, a 'you'll need to…' instruction, or re-issuing steps after a snag. Not for commands you run yourself."
---

# Step-by-step: handing Chris steps he can follow by copy and paste

Load this before you give Chris anything to *do*: a command for a terminal, a
router block, clicks in an admin console, or a secret to fetch or place.

**Read `SITE.md` in this directory first.** This file is the shared core, used
by every agent that imports `agent-modules`. `SITE.md` is this host's layer:
which terminals Chris uses here, his phone/keyboard pattern, which hosts have
`secret-put`, where secrets live, and local evidence. If the two conflict,
`SITE.md` wins for facts about this site, and the core wins for method.

Where this came from: a review of 45 sessions (Aug–Nov 2026) found about 150
handoff failures. In rough counts:

| Failure | ≈ | Typical case |
|---|---|---|
| Written from memory instead of checked | 55 | v7 syntax on a v6 router, sent four times; a GUI menu that doesn't exist, repeated five times; a callback blocked by the agent host's own firewall |
| Placeholder to fill in by hand | 40 | `<community>` read by bash as a redirect; `password=REPLACE_ME` pasted literally on a production router; every hand-merged JSON broke |
| Didn't say where it runs | 30 | bash pasted into cmd; a packet capture with no host named; "the ops host" |
| "As before" / "from my earlier message" | 26 | host A's checklist run on host B; a step never re-pasted, so a time-limited evidence window closed |
| A prompt mid-paste swallowed lines, or a line ran after an earlier one failed | 12 | `read -rs` stored the next command as the token; a failed `cd && git pull` was followed by a rebuild from a stale copy, which rolled the host back |
| Lines that shouldn't run yet were in the block | 6 | the rollback pasted along with the fix during an outage |
| `!` prefix | 3 | `!` negated `mv` and silently stopped an `&&` chain |

Six of these rules already existed as separate memories, each written after
its own incident, and the failures kept happening. So this skill is the single
place for them. If you're about to break a rule, propose a change to the skill
instead.

## 0. Before writing anything

1. **Can I do it myself?** If I can run it, even behind an approval prompt, or
   read the value myself, I do that. A declined tool call means I ask, or say
   why it was declined. It doesn't mean I move the step into Chris's terminal.
   Reads and verifies are mine unless only he can run them.
2. **Phone or keyboard?** Guess from the clock using `SITE.md`'s pattern, then
   confirm in one line: "It's 7:44 p.m., so I'm assuming phone. Right?" Ask
   again if he says he's moved.
   - **Phone:** GUI steps, or at most one short command. No SSH sessions, no
     long pastes, no secrets typed into a terminal. A secret can only go
     browser tab to browser tab, or waits for the keyboard. PR review and
     merge in a web UI works fine from a phone.
   - **Keyboard:** name which terminal each block is for (`SITE.md` lists them).
3. **`!` only after asking.** Before writing a `!` command, ask whether he's
   working inside the agent's own session or multiplexer pane. He usually
   isn't. If he doesn't say yes, don't use `!`. In bash, `!` negates the exit
   status and silently breaks `&&` chains, and it only ever runs on the agent's
   host.
4. **Can the target see this chat?** A hypervisor web console, KVM, bench
   machine or live USB **can't paste**. Give it only short lines he can type by
   hand, and the first lines should get SSH working so the rest can be pasted.
   Never ask him to type base64, a key, a hash or a long URL.

## 1. Check the target before writing a command for it

Every block has to be correct for the machine he's actually on. Check these
first, with a tool or one read-only question:

- OS or firmware **version** (syntax differs), shell (bash, cmd, PowerShell,
  a router CLI), and tool availability (`jq`, `traceroute`, PowerShell modules)
- **user**, and whether sudo needs a password (`sudo -n true`). If I've already
  seen it fail, say so before handing over a sudo step
- **which node** (some hypervisor commands only work on the node that owns the
  VM), which checkout and its remote (`git remote -v`, "is it a git repo at
  all"), the host's clock and timezone
- **reachability from his side**, not from localhost
- **GUI paths against the vendor's current docs**, not memory. If I can't
  confirm a step, mark it *unconfirmed* and give a landmark: "you're on the
  right page when you see X; if not, send a screenshot". When he proves a UI
  claim wrong, write the correction down so a context summary can't bring the
  old claim back.
- what **already exists** (a login method, a resource pool, a tag) before
  telling him to create it
- **run it first** if anything can: a script against something shaped like the
  real target, a router selector through a count, a loop against one item

List every **prerequisite before step 1**: accounts, keys, IDs, which account
issues a token, where to find it, and its scope. A key discovered missing at
step 6 cost an hour.

## 2. Each block

**A plain-text line above every block says where it runs.** Give host, user,
shell, and how he gets there. Put it in prose, not as a comment inside the
block:

> On **db-1 as root**, bash: from your SSH terminal, `ssh db-1` first.

One host per block. A block never moves between hosts partway through, and a
variable set on one host is never used on another.

**It runs exactly as copied.** No placeholders of any kind: `<x>`, `REPLACE_ME`,
`xxx`, `...`, "your group", "the number from above". Instead:
- fetch the value and write it in, or
- let the block work it out (`COMM=$(… config:get …)`), or
- if only he can know it, prompt for it on one line that checks it (§4)

For a file change, never "edit line 5" or "add this fragment". Give a
`sed`/`jq` command, or the **whole file** followed by a check (`jq . && echo OK`,
`bash -n`, the service's own config check).

**Only what runs now, in order.** No rollback, cleanup, "if that passes, then",
or "later" lines inside a block. Put those in prose, or in a separate block
marked *only if needed*. If a check decides whether a change happens, the
check goes in its own message. Exception: a time-boxed test that restores
itself (disable, test, enable) can be one block, and says so.

**Anything that waits for input ends the block.** That means `read -s`,
`cat >`, `install /dev/stdin`, ssh or sudo passwords, an interactive
installer, or Ctrl-D. Put it in its own block, say exactly which keys to press,
and put the check in the next block. Never chain after a command that might
prompt (`git pull` asking for credentials, two `ssh … | ssh …` lines).

**Stop on failure, safe to run twice.** Use a single `&&` chain or `set -e`
that ends in a marker (`echo OK`), so he can see the end was reached. Never put
a second line where it runs after the first one failed. Steps that move or
create things check first: `[ -f new ] && mv new old`. Loops have a limit, and
big or slow commands say how long they take and when to press Ctrl-C.

**Expected output and failure.** Under the block, say what success prints,
using a check that can actually fail ("must print `40`", "count goes 57 → 69",
"prints nothing; an error means stop"). Say what failure looks like and what
to do: "if X, stop and send me the output".

**Paste-safe text.**
- Anything to copy goes in a fenced block, never a `>` quote. Markdown eats
  `_`, `*`, `<` and `>`.
- No em-dashes or curly quotes inside a block.
- No trailing `#` comments on router CLI lines (RouterOS rejects them).
- No heredoc that feeds a program which itself reads from stdin
  (`python3 - <<EOF` with `input()`). Write a temp file and run that.
- `ssh host 'sudo …'` needs `-t`, or it fails when sudo needs a password.

## 3. The sequence

- **One gate per message.** Stop at the first step whose output I need to see.
  Give 3–5 GUI steps at a time. Chris has asked for exactly this: "If a step
  requires a check from you, stop there and don't give the rest until I
  respond."
- **After any snag, resend everything still left**, renumbered and complete,
  with changed steps marked *(changed)*. Never write "as before", "from my
  earlier message", "the rest stands", "same as host A except", or "re-paste
  the function from step 5". If he has to scroll up, the handoff has failed.
- **Every format he needs goes in the message itself**: JSON shape, env key
  names. Not only in a PR or a file he can't see.
- **Reusable helpers go in a file or a tool, not the session.** A shell
  function that has to be re-pasted into every new window gets dropped.
- Keep **"you, now"** separate from the backlog. A 19-item list is a status
  board, not instructions.
- **Don't change the plan while he's partway through it.** If it has to
  change, say where he stands first: "you've done 1; stop there".
- Record what he reports back (board, memory or PR), so a dropped step shows
  up instead of quietly being lost.

## 4. Secrets

Never through chat. Never on a command line, in shell history, in the Nix
store, in a repo, in memory or in a log. Check off each stage:

**Source.** Say exactly where the secret comes from: system, issuing account,
menu path checked against current docs, scope, expiry.

**Input.** On a host with `secret-put` (`agent-modules.nixosModules.secret-put`),
use it, alone in its block. Tell him to run it, wait for the prompt, then paste
the secret and press Enter. Pasting the secret along with the command echoes it.

> On **db-1 as your admin account**, bash. Run this first so a wrong user fails before any secret is involved:

```
sudo -v && echo SUDO_OK
```

> Then:

```
sudo secret-put /var/lib/app/token --owner root --group root --mode 0400 --len 40
```

> It asks for the token with input hidden. Paste and press Enter. Success prints `OK /var/lib/app/token  40 bytes  root:root 400`. Anything starting `NOT WRITTEN` means nothing changed. Send me that line.

`--env KEY` sets one line of a `.env` file and keeps the rest. `--prefix P`
adds a shape check, which asks before writing instead of refusing, so a check
based on outdated knowledge can't block a valid key. `secret-put --check PATH`
shows owner, mode, size and trailing newline, never a value.

**Hosts without it** get the one-line version. It's alone in its block, it
checks before writing, and it writes nothing if the check fails:

```
read -rsp 'Paste token (hidden), then Enter: ' T && echo && T=$(printf %s "$T" | tr -d '\r\n\t ') && [ ${#T} -eq 40 ] && printf %s "$T" | sudo install -o root -g root -m 0400 /dev/stdin /var/lib/app/token && echo "OK $(sudo stat -c %s /var/lib/app/token) bytes" || echo "NOT WRITTEN"; unset T
```

Read a root-only file back with `sudo stat`, never `sudo wc -c < file`: the
`<` is opened by the user's own shell before sudo runs, so it fails with
`Permission denied` and the check prints `OK  bytes` with no number, after
the write has already succeeded.

If a secret has several values, or needs annotations, stage a template with
empty values and have him fill it in place (`SITE.md` names the convention).
Never use an editor or `cat >` / Ctrl-D for a **bare-token** file: both add a
newline, which produces the 41-byte token.

**Storage.** The owner is decided by who reads the file. If the agent reads it:
owned by the agent user, mode 0400. If the agent must not read it:
`root:root 0400`. Never put a root-only credential anywhere the agent can read
"for convenience". A `.env` is read by a parser (systemd `EnvironmentFile`, a
key=value reader), never loaded as shell with `source`: a `$` in a password
broke a sourced file and printed half the password.

**My handling.**
- Never `cat`, `sed` or `grep` a file that might contain a secret without
  filtering it first. A read-only `sed -n` of a compose file once printed a
  live API key into chat.
- Diagnostics print only length, presence and key names, never characters of
  a value. Use `secret-put --check`.
- Host-to-host copies go over a direct ssh pipe with key auth, never relayed
  through him.

**Confirmation, three levels, none showing the value:**
1. **Placed:** owner, mode and bytes (`secret-put --check`).
2. **Shape:** public prefix present, yes or no.
3. **Works:** the consumer actually authenticates. Wherever I can, I check
   this myself (service status, its log, an API call reading the file).

**Leak = burned.** If a secret reaches chat, history or a log: rotate it first,
then clean it out of history and the log, with no debate about whether it
"really" leaked. Tell Chris what was exposed and where.

## 5. GUI steps

- Give the full path from a starting point he can find, with field-by-field
  values: name, value, the box to tick. Include the easy-to-forget settings
  (*Private*, scope, expiry).
- Check the path against current docs before sending (§1). Add a landmark for
  each screen, and say "if it doesn't match, send a screenshot".
- Ask for **one** non-secret value back, and say exactly where to find it on
  the page. Two IDs with similar names on the same page got mixed up.
- For a value that goes from one admin console to another, have him copy it
  browser tab to browser tab, not through chat or email.

## 6. End of message

Finish with one line, **Send me:** …: the exact thing to send back (the OK
line, the count, "done"). If he needs to send nothing, say "Nothing to send.
I'll check it from <where>." Never bury the request mid-paragraph.

## Before sending: checklist

- [ ] Read `SITE.md`?
- [ ] Could I do or read this myself instead?
- [ ] Phone or keyboard confirmed? Which terminal? Any `!` only after asking?
- [ ] Target checked, not recalled: version, user, sudo, node, reachability, current GUI docs?
- [ ] Prerequisites listed before step 1?
- [ ] Every block has a "where it runs" line, and one host per block?
- [ ] No placeholders, no hand edits, no rollback or "later" lines in a block?
- [ ] Every prompting command is alone, at the end of its block, with the keys to press?
- [ ] Each block stops on failure, is safe to run twice, and its expected output is stated?
- [ ] Only up to the first gate? After a snag, the whole remainder resent?
- [ ] Secret: source given, `secret-put` or one-liner used, nothing that could print the value?
- [ ] Ends with **Send me:**?
