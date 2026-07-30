# One-Line Install and Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one idempotent command that installs or updates PowerLens from
`main`, detects Oh My Zsh versus plain zsh, and safely configures the user's
startup file.

**Architecture:** A repository-root `install.sh` owns preflight checks,
framework detection, Git lifecycle, installation validation, and atomic
`.zshrc` configuration. A black-box zsh test suite executes the real installer
against temporary homes and local Git repositories, so tests never touch the
network or the user's files.

**Tech Stack:** zsh 5.8+, Git, standard macOS command-line tools, existing zsh
test style.

## Global Constraints

- Support macOS 12+ only.
- Support Oh My Zsh and plain zsh only.
- Track the mutable `origin/main` branch.
- Never overwrite an unexpected directory or discard local Git changes.
- Never use `git reset --hard`.
- Do not add Go dependencies.
- Modify `.zshrc` only when its structure is confidently recognized.
- Back up `.zshrc` only when its content will actually change.
- Keep the same command for first installation and later updates.
- Leave the unrelated untracked `AGENTS.md` untouched.

## File Map

- Create `install.sh`: all production installer behavior and its `main`
  entrypoint.
- Create `tests/test_install.zsh`: black-box installer fixtures, assertions,
  and behavior tests.
- Modify `README.md`: recommended one-line flow, update instructions,
  framework behavior, troubleshooting, review-first alternative, and retained
  manual installation.
- Modify
  `docs/superpowers/specs/2026-07-30-one-line-install-update-design.md`: clarify
  that the interpreter used for the pipe is not the user's login shell.

---

### Task 1: Plain-zsh first installation and idempotent configuration

**Files:**

- Create: `tests/test_install.zsh`
- Create: `install.sh`

**Interfaces:**

- Consumes environment variables:
  `HOME`, `SHELL`, `POWERLENS_SHELL_MODE`, `POWERLENS_ZSHRC`,
  `POWERLENS_REPO_URL`, and `POWERLENS_INSTALL_DIR`.
- Produces functions:
  `_powerlens_die(message)`,
  `_powerlens_validate_install(dir)`,
  `_powerlens_install_or_update(dir, repo_url)`,
  `_powerlens_configure_plain_zsh(zshrc, install_dir)`, and
  `_powerlens_main()`.
- Produces a managed plain-zsh block with the exact boundary comments
  `# >>> PowerLens installer >>>` and
  `# <<< PowerLens installer <<<`.

- [ ] **Step 1: Create the black-box fixture and failing plain-zsh test**

Create a test harness that:

1. makes a temporary home and cleanup trap;
2. creates a local Git repository with branch `main`;
3. commits `powerlens.plugin.zsh`, `powerlens.zsh`, and executable fake
   `bin/powerlens-fetch-arm64` and `bin/powerlens-fetch-amd64`;
4. runs the real installer with explicit temporary paths.

The first behavior test must execute:

```zsh
env \
  HOME="$case_dir/home" \
  SHELL=/bin/zsh \
  POWERLENS_SHELL_MODE=zsh \
  POWERLENS_ZSHRC="$case_dir/home/.zshrc" \
  POWERLENS_REPO_URL="$case_dir/origin" \
  POWERLENS_INSTALL_DIR="$case_dir/install" \
  zsh "$PROJECT_ROOT/install.sh"
```

Assert literal outcomes:

```zsh
assert_eq "plain install exits zero" "$status" "0"
assert_file "$case_dir/install/.git"
assert_contains "$case_dir/home/.zshrc" \
  "source \"$case_dir/install/powerlens.plugin.zsh\""
assert_eq "managed block occurs once" \
  "$(count_fixed "$case_dir/home/.zshrc" \
    '# >>> PowerLens installer >>>')" \
  "1"
```

Run the same command a second time and assert:

```zsh
assert_eq "second run exits zero" "$status" "0"
assert_eq "managed block remains single" \
  "$(count_fixed "$case_dir/home/.zshrc" \
    '# >>> PowerLens installer >>>')" \
  "1"
assert_eq "idempotent run creates no backup" \
  "$(count_backups "$case_dir/home")" \
  "1"
```

The expected backup count is one because the first configuration change
creates one backup and the second run creates none.

- [ ] **Step 2: Run the test and verify the feature is absent**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: FAIL because `install.sh` does not exist.

- [ ] **Step 3: Implement the minimal plain-zsh install path**

Start `install.sh` with:

```zsh
#!/usr/bin/env zsh
setopt errexit nounset pipefail

typeset -gr POWERLENS_DEFAULT_REPO_URL="https://github.com/luyangkk/powerlens.git"
typeset -gr POWERLENS_MARKER_START="# >>> PowerLens installer >>>"
typeset -gr POWERLENS_MARKER_END="# <<< PowerLens installer <<<"

_powerlens_die() {
    print -u2 "PowerLens: $1"
    return 1
}
```

Implement `_powerlens_install_or_update` so a missing target is cloned to a
temporary sibling with:

```zsh
git clone --branch main --single-branch -- "$repo_url" "$temporary_dir"
```

Validate both plugin files and the binary selected from:

```zsh
case "$(uname -m)" in
    arm64) binary="bin/powerlens-fetch-arm64" ;;
    x86_64) binary="bin/powerlens-fetch-amd64" ;;
    *) _powerlens_die "unsupported Mac architecture: $(uname -m)" ;;
esac
```

Rename the validated temporary directory into place. Ensure a failure removes
only the explicitly created temporary directory.

Implement `_powerlens_configure_plain_zsh` by:

1. creating the startup file if missing;
2. returning without changes if an active `source` command already names the
   resolved `powerlens.plugin.zsh`;
3. copying the original to
   `${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)`;
4. writing the original plus the managed block to a sibling temporary file;
5. renaming that file over the startup file.

Shell-quote the absolute source path using zsh's `${(q)install_dir}` expansion.
Do not source the file from the installer.

- [ ] **Step 4: Run the test and verify the plain-zsh behavior passes**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: all Task 1 assertions pass with no writes outside the test directory.

- [ ] **Step 5: Commit the first working slice**

```zsh
git add install.sh tests/test_install.zsh
git commit -m "feat: add idempotent plain-zsh installer"
```

---

### Task 2: Oh My Zsh detection and configuration

**Files:**

- Modify: `tests/test_install.zsh`
- Modify: `install.sh`

**Interfaces:**

- Consumes the Task 1 installer lifecycle.
- Produces functions:
  `_powerlens_detect_shell_mode(zshrc)`,
  `_powerlens_default_install_dir(mode)`,
  `_powerlens_plugins_contain_powerlens(zshrc)`, and
  `_powerlens_configure_omz(zshrc, install_dir)`.
- `_powerlens_detect_shell_mode` prints exactly `omz` or `zsh` on success.

- [ ] **Step 1: Add failing framework detection and Oh My Zsh tests**

Add a fixture containing:

```zsh
export ZSH="$HOME/.oh-my-zsh"
plugins=(
  git
)
source "$ZSH/oh-my-zsh.sh"
```

Run without `POWERLENS_SHELL_MODE`, with a temporary
`ZSH_CUSTOM="$case_dir/custom"`, and assert:

```zsh
assert_dir "$case_dir/custom/plugins/powerlens/.git"
loader_line=$(line_number "$zshrc" 'source "$ZSH/oh-my-zsh.sh"')
powerlens_line=$(line_number "$zshrc" 'plugins+=(powerlens)')
assert_true "PowerLens is configured before Oh My Zsh loads" \
  '(( powerlens_line < loader_line ))'
```

Add separate cases where `powerlens` already appears in:

```zsh
plugins=(git powerlens)
```

and:

```zsh
plugins+=(powerlens)
```

Assert the content and backup count remain unchanged. Add a case with two Oh
My Zsh loader lines and assert a non-zero exit with no `.zshrc` modification.

- [ ] **Step 2: Run the focused suite and verify expected failures**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: plain-zsh cases pass; Oh My Zsh cases fail because automatic mode
detection and loader-aware insertion are not implemented.

- [ ] **Step 3: Implement framework detection and Oh My Zsh insertion**

Implement mode selection in this exact priority:

```zsh
case "${POWERLENS_SHELL_MODE:-}" in
    omz|zsh) print -r -- "$POWERLENS_SHELL_MODE"; return 0 ;;
    "") ;;
    *) _powerlens_die "POWERLENS_SHELL_MODE must be omz or zsh"; return 1 ;;
esac
```

Treat any of these as Oh My Zsh evidence:

- `${ZSH:-}/oh-my-zsh.sh` exists;
- `$HOME/.oh-my-zsh/oh-my-zsh.sh` exists;
- the startup file has one active `oh-my-zsh.sh` source line.

Otherwise treat a login shell whose basename is `zsh` as plain zsh. Do not
use `$ZSH_VERSION` as login-shell evidence.

For Oh My Zsh, compute the default directory from:

```zsh
${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/powerlens
```

Detect `powerlens` only as a shell token in active `plugins=(...)` or
`plugins+=(...)` assignments, not as a substring such as
`powerlens-extra` or in a comment.

Count active Oh My Zsh loader lines. Only when the count is exactly one, write
the managed `plugins+=(powerlens)` block before it using a sibling temporary
file and timestamped backup.

- [ ] **Step 4: Run the suite and verify both framework paths pass**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: all plain-zsh and Oh My Zsh detection, placement, existing-config,
and ambiguous-loader assertions pass.

- [ ] **Step 5: Commit framework support**

```zsh
git add install.sh tests/test_install.zsh
git commit -m "feat: configure Oh My Zsh installations"
```

---

### Task 3: Safe fast-forward updates

**Files:**

- Modify: `tests/test_install.zsh`
- Modify: `install.sh`

**Interfaces:**

- Consumes `_powerlens_install_or_update(dir, repo_url)` from Task 1.
- Extends it to update an existing valid installation.
- Produces `_powerlens_validate_existing_repo(dir, repo_url)`.

- [ ] **Step 1: Add failing update and repository-safety tests**

After a first installation, add a new committed file to the local origin,
execute the same installer command, and assert the installed `HEAD` exactly
equals the origin's `main` commit:

```zsh
assert_eq "update fast-forwards to origin/main" \
  "$(git -C "$install_dir" rev-parse HEAD)" \
  "$(git -C "$origin_dir" rev-parse main)"
```

Add independent cases asserting non-zero exit and unchanged installed `HEAD`
for:

- a modified tracked file;
- an untracked file;
- an existing non-Git target directory;
- an origin URL different from `POWERLENS_REPO_URL`;
- a local commit that is not an ancestor of `origin/main`.

Capture stderr and assert only stable recovery phrases such as
`local changes`, `not a PowerLens Git repository`, `unexpected origin`, and
`cannot fast-forward`.

- [ ] **Step 2: Run the focused suite and verify update failures**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: first-install cases pass; fast-forward update and rejection cases
fail because existing targets are not yet handled.

- [ ] **Step 3: Implement update validation and fast-forward**

For an existing target:

1. require `dir/.git`;
2. require `git -C "$dir" status --porcelain` to be empty;
3. normalize the configured and actual origins by stripping one trailing
   slash and an optional `.git`, then compare them;
4. run `git -C "$dir" fetch -- origin main`;
5. require:

   ```zsh
   git -C "$dir" merge-base --is-ancestor HEAD origin/main
   ```

6. run:

   ```zsh
   git -C "$dir" merge --ff-only origin/main
   ```

7. rerun `_powerlens_validate_install`.

Never delete, clean, reset, stash, or rewrite the existing repository.

- [ ] **Step 4: Run the suite and verify safe update behavior**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: fast-forward update passes; every unsafe repository case exits
non-zero and preserves the pre-run commit and files.

- [ ] **Step 5: Commit update support**

```zsh
git add install.sh tests/test_install.zsh
git commit -m "feat: safely update PowerLens from main"
```

---

### Task 4: Preconditions, ambiguity handling, and failure cleanup

**Files:**

- Modify: `tests/test_install.zsh`
- Modify: `install.sh`

**Interfaces:**

- Consumes all prior installer functions.
- Produces `_powerlens_check_preconditions(zshrc)`,
  `_powerlens_choose_mode_from_tty()`, and cleanup traps scoped to installer
  temporary files.
- `POWERLENS_SHELL_MODE` remains the non-interactive override.

- [ ] **Step 1: Add failing validation and cleanup tests**

Add black-box cases for:

- non-macOS output from a test-local `uname` executable placed first in
  `PATH`;
- invalid `POWERLENS_SHELL_MODE=fish`;
- non-zsh login shell with no Oh My Zsh evidence and stdin from `/dev/null`;
- missing startup-file parent;
- architecture validation by placing only the opposite-architecture binary in
  the fixture;
- clone validation failure leaving no final target or temporary sibling;
- plain-zsh install with a pre-existing equivalent manual `source` line;
- a source path containing spaces, proving the inserted line can be evaluated
  by zsh.

For non-interactive ambiguity, assert stderr contains:

```text
set POWERLENS_SHELL_MODE=omz or POWERLENS_SHELL_MODE=zsh
```

For cleanup, snapshot the target's parent directory before and after and assert
that no `.powerlens-install-*` entry remains.

- [ ] **Step 2: Run the suite and verify the new guards fail**

Run:

```zsh
zsh tests/test_install.zsh
```

Expected: the new cases fail for their missing guard or cleanup behavior, not
because the fixtures cannot execute.

- [ ] **Step 3: Implement minimal preflight, TTY fallback, and cleanup**

Check:

```zsh
[[ "$(uname -s)" == "Darwin" ]]
command -v git >/dev/null
command -v zsh >/dev/null
command -v curl >/dev/null
```

Resolve the startup file as:

```zsh
${POWERLENS_ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}
```

Require either the file to be writable or its existing parent directory to be
writable.

When automatic mode detection has insufficient evidence:

- if `/dev/tty` is readable and writable, print a two-option prompt there and
  accept only `1`/`omz` or `2`/`zsh`;
- otherwise exit with the exact environment-variable guidance from Step 1.

Register cleanup only for the concrete temporary paths created by this
process. Clear those path variables immediately after successful rename. Do
not use a wildcard cleanup.

- [ ] **Step 4: Run installer tests and syntax validation**

Run:

```zsh
zsh -n install.sh
zsh -n tests/test_install.zsh
zsh tests/test_install.zsh
```

Expected: syntax checks exit zero; every installer behavior test passes with
zero failures and no temporary artifacts.

- [ ] **Step 5: Commit installer hardening**

```zsh
git add install.sh tests/test_install.zsh
git commit -m "test: cover installer safety and shell detection"
```

---

### Task 5: README installation and update documentation

**Files:**

- Modify: `README.md`

**Interfaces:**

- Documents the production interface implemented by Tasks 1–4.
- Does not introduce behavior absent from `install.sh`.

- [ ] **Step 1: Record the documentation behavior checklist**

Before editing, verify the README change must contain all of these
human-visible items:

```text
one command used for both install and update
automatic Oh My Zsh and plain-zsh detection
exec zsh activation step
explicit POWERLENS_SHELL_MODE override
dirty-repository update failure guidance
review-first download instructions
manual Oh My Zsh fallback
manual plain-zsh fallback
main-branch update and supply-chain caveat
```

This is a requirements checklist, not a source-text unit test.

- [ ] **Step 2: Rewrite the Installation section**

Place the one-line command first:

```zsh
curl -fsSL https://raw.githubusercontent.com/luyangkk/powerlens/main/install.sh | zsh
```

Explain that the first run installs, later runs update from `main`, and the
script detects the framework and avoids duplicate `.zshrc` entries. Document:

```zsh
POWERLENS_SHELL_MODE=omz \
  zsh /tmp/powerlens-install.sh
```

and the equivalent `zsh` mode. Add the review-first download flow from the
design and preserve manual instructions for both framework types.

Document that users with local changes in the installation directory must
commit, revert, or move those changes themselves before updating; do not
recommend destructive reset commands.

- [ ] **Step 3: Review rendered structure and links**

Run:

```zsh
rg -n '^## Installation|^### |install\\.sh|POWERLENS_SHELL_MODE|exec zsh' README.md
```

Then read the complete Installation and Requirements sections. Confirm every
Step 1 checklist item is present, code fences are balanced, manual commands
use the correct two installation directories, and existing relative links
still resolve.

- [ ] **Step 4: Run the full project verification**

Run:

```zsh
zsh -n install.sh
zsh -n tests/test_install.zsh
zsh tests/test_install.zsh
zsh tests/test_plugin.zsh
(cd src && go test ./...)
(cd src && go vet ./...)
git diff --check
```

Expected: every command exits zero, installer and plugin test summaries report
zero failures, Go tests pass, `go vet` emits no diagnostics, and
`git diff --check` emits no output.

- [ ] **Step 5: Commit documentation**

```zsh
git add README.md
git commit -m "docs: add one-line install and update"
```

---

### Task 6: Final requirement audit

**Files:**

- Verify: `install.sh`
- Verify: `tests/test_install.zsh`
- Verify: `README.md`
- Verify:
  `docs/superpowers/specs/2026-07-30-one-line-install-update-design.md`

**Interfaces:**

- Consumes the approved design and all implementation tasks.
- Produces fresh verification evidence and a clean, reviewable diff.

- [ ] **Step 1: Compare implementation against every design section**

Check each design heading in order: goal, scope, interface, preconditions,
detection, locations, install/update flow, configuration, backup/atomic
write, output/errors, testing, and known trade-offs. Record and fix any gap
before continuing.

- [ ] **Step 2: Run mutation-oriented spot checks**

Temporarily confirm the test suite would fail for each realistic regression,
restoring the implementation after every check:

- change the managed-block duplicate check so it always appends;
- move the Oh My Zsh block after its loader;
- remove the dirty-worktree rejection;
- make update skip the fast-forward merge.

Run `zsh tests/test_install.zsh` after each temporary mutation and require a
failure naming the affected behavior. Restore the correct implementation and
rerun the suite successfully.

- [ ] **Step 3: Run the complete verification once more**

Run:

```zsh
zsh -n install.sh
zsh -n tests/test_install.zsh
zsh tests/test_install.zsh
zsh tests/test_plugin.zsh
(cd src && go test ./...)
(cd src && go vet ./...)
git diff --check
git status --short
```

Expected: all validation commands exit zero; the only unrelated status entry
may be the pre-existing untracked `AGENTS.md`.

- [ ] **Step 4: Inspect the final commits and diff**

Run:

```zsh
git log --oneline --decorate -8
git diff 986f729..HEAD -- install.sh tests/test_install.zsh README.md \
  docs/superpowers/specs/2026-07-30-one-line-install-update-design.md
```

Confirm only the requested installer, tests, README, and approved internal
design clarification changed.
