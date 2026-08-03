# Remove SSH Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PowerLens initialize normally in SSH sessions by removing the SSH-only degraded path and updating only its regression test and documentation.

**Architecture:** Keep one initialization path in `powerlens.zsh` for both local and SSH shells. Prove the behavior with the existing Zsh integration test using a temporary fake daemon, then align README claims with the resulting runtime behavior.

**Tech Stack:** Zsh, shell integration tests, Markdown, Go verification commands

## Global Constraints

- Delete `_powerlens_is_ssh` and the SSH-only early return from `_powerlens_init`.
- Replace only the SSH degraded-mode test and the README statements that describe that behavior.
- Do not change daemon lifecycle, session counting, installer behavior, configuration, prompt formatting, or metric collection.
- SSH metrics describe the remote macOS host, not the SSH client.
- Add no dependencies.

---

### Task 1: Remove the SSH-only initialization path

**Files:**
- Modify: `tests/test_plugin.zsh:28-45`
- Modify: `powerlens.zsh:14-16,275-280`
- Modify: `README.md:26,287`

**Interfaces:**
- Consumes: `_powerlens_init`, `_powerlens_start_daemon`, `_POWERLENS_PIDFILE`, `_POWERLENS_COUNTER`, and Zsh's `$functions` table.
- Produces: one `_powerlens_init` path that is independent of `SSH_TTY`, `SSH_CONNECTION`, and `SSH_CLIENT`.

- [ ] **Step 1: Replace the degraded SSH test with a normal-initialization regression test**

Replace the `=== SSH guard ===` block in `tests/test_plugin.zsh` with:

```zsh
print "\n=== SSH initialization ==="
SSH_TTY="/dev/ttys001"
local ssh_cache=$(mktemp -d)
_POWERLENS_CACHE="$ssh_cache"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"
local ssh_fake_bin="$_POWERLENS_CACHE/fake_daemon"
printf '#!/bin/sh\nexec sleep 300\n' > "$ssh_fake_bin"
chmod +x "$ssh_fake_bin"
_powerlens_bin="$ssh_fake_bin"
unfunction precmd 2>/dev/null || true

_powerlens_init
sleep 0.1
assert_eq "SSH init creates daemon state" \
  "$(test -f $_POWERLENS_PIDFILE && test -f $_POWERLENS_COUNTER && echo yes || echo no)" "yes"
assert_eq "SSH init registers the refresh hook" \
  "$(( $+functions[precmd] ))" "1"

_powerlens_stop_daemon
rm -rf "$ssh_cache"
unset SSH_TTY
```

This uses the real initialization and daemon lifecycle code while replacing only the long-running collector executable with a temporary sleeping process.

- [ ] **Step 2: Run the focused Zsh suite and verify the regression test fails for the expected reason**

Run:

```bash
zsh tests/test_plugin.zsh
```

Expected: exit status is non-zero; both SSH initialization assertions report `FAIL` because the current guard returns before creating daemon state or registering `precmd`. The rest of the existing assertions continue to pass.

- [ ] **Step 3: Remove the SSH detection function and early return**

Delete this function from `powerlens.zsh`:

```zsh
_powerlens_is_ssh() {
    [[ -n "${SSH_TTY:-}" || -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]
}
```

Change `_powerlens_init` to contain no SSH branch:

```zsh
_powerlens_init() {
    _POWERLENS_DEGRADED=$(_powerlens_degraded)
    _powerlens_start_daemon
    precmd() { _powerlens_update_rprompt }
    zshexit() { (( $+functions[_powerlens_stop_daemon] )) && _powerlens_stop_daemon }
    zle -N zle-line-finish _powerlens_zle_line_finish
    if (( ${TMOUT:-0} == 0 || ${TMOUT:-0} > POWERLENS_REFRESH )); then
        TMOUT=$POWERLENS_REFRESH
    fi
}
```

- [ ] **Step 4: Run the Zsh suite and verify the regression test passes**

Run:

```bash
zsh tests/test_plugin.zsh
```

Expected: exit status 0 and the summary reports zero failed assertions, including passes for daemon state and the `precmd` hook under `SSH_TTY`.

- [ ] **Step 5: Update only the corresponding README claims**

Delete the Features table row:

```markdown
| **SSH-aware** | Daemon skipped in remote shells; shows `--` gracefully |
```

Replace the SSH row in Behavior Reference with:

```markdown
| SSH remote shell | Same as a local shell; shows live metrics from the remote Mac |
```

- [ ] **Step 6: Verify syntax, tests, and scope**

Run:

```bash
zsh -n powerlens.zsh tests/test_plugin.zsh
zsh tests/test_plugin.zsh
zsh tests/test_install.zsh
(cd src && go test ./...)
(cd src && go vet ./...)
git diff --check
git diff -- powerlens.zsh tests/test_plugin.zsh README.md
git status --short
```

Expected: every syntax, test, and vet command exits 0; `git diff --check` prints nothing; the diff contains only the SSH detection removal, its regression test, and the two corresponding README edits; `AGENTS.md` remains untracked and untouched.

- [ ] **Step 7: Commit the implementation**

```bash
git add powerlens.zsh tests/test_plugin.zsh README.md
git commit -m "fix: enable PowerLens metrics over SSH"
```

Expected: the commit includes exactly the three implementation files and does not include `AGENTS.md`.
