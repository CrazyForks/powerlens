# One-Line Install and Update Design

## Goal

Provide one copy-paste command that installs PowerLens on first use and
updates it on later runs. The installer must support both Oh My Zsh and plain
zsh, configure the correct startup file without duplicate entries, and never
discard user changes.

The documented command will be:

```zsh
curl -fsSL https://raw.githubusercontent.com/luyangkk/powerlens/main/install.sh | zsh
```

Updates intentionally follow the repository's `main` branch rather than a
release tag.

## Scope

The change adds:

- a repository-root `install.sh`;
- automated installer tests;
- one-line installation and update instructions in `README.md`;
- retained manual installation instructions as a fallback.

The change does not add an uninstaller, migrate installations between shell
frameworks, create GitHub release assets, or support non-macOS platforms and
non-zsh shells.

## Installer Interface

`install.sh` is executable with zsh and uses one entry point for both actions.
It accepts these optional environment variables:

| Variable | Purpose |
|---|---|
| `POWERLENS_SHELL_MODE` | Force `omz` or `zsh` when automatic detection is ambiguous. |
| `POWERLENS_ZSHRC` | Override the startup file, primarily for unusual layouts and tests. |
| `POWERLENS_REPO_URL` | Override the Git repository, primarily for tests. |
| `POWERLENS_INSTALL_DIR` | Override the installation directory, primarily for tests. |

Normal users do not need to set any variable.

## Preconditions and Detection

Before writing anything, the installer verifies:

1. the operating system is macOS;
2. `zsh`, `git`, and `curl` are available;
3. the selected startup file is writable, or its parent is writable if the
   file does not exist.

The startup file defaults to `${ZDOTDIR:-$HOME}/.zshrc`.

Framework detection uses the following order:

1. a valid `POWERLENS_SHELL_MODE` override;
2. Oh My Zsh indicators in the startup file, `$ZSH`, or
   `$HOME/.oh-my-zsh`;
3. plain zsh when the user's login shell or current interpreter is zsh.

An explicit but unsupported mode fails. Conflicting or insufficient evidence
does not cause a guessed configuration change. With a controlling terminal,
the installer asks the user to choose Oh My Zsh or plain zsh by reading
`/dev/tty`. Without a controlling terminal, it exits with instructions to set
`POWERLENS_SHELL_MODE`.

## Installation Locations

For Oh My Zsh, the default directory is:

```text
${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/powerlens
```

For plain zsh, the default directory is:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/powerlens
```

`POWERLENS_INSTALL_DIR` overrides either default.

## Install and Update Flow

If the target does not exist, the installer clones the repository's `main`
branch into a temporary sibling directory, validates the required plugin files
and architecture-specific binary, and then renames the directory into place.
This prevents a failed clone from leaving a partial installation.

If the target exists, it must be a Git worktree whose `origin` points to the
PowerLens repository. The installer then:

1. rejects tracked or untracked local changes;
2. fetches `origin/main`;
3. verifies the current commit is an ancestor of `origin/main`;
4. fast-forwards to `origin/main`;
5. validates the required plugin files and binary again.

The installer never runs `git reset --hard`, removes an unexpected directory,
or overwrites local modifications. A non-PowerLens directory, dirty worktree,
or non-fast-forward history produces an actionable error.

After installation or update, the script verifies that the binary matching
`uname -m` exists and is executable. Only `arm64` and `x86_64` are accepted.

## Startup Configuration

Configuration changes happen only after a valid installation is present.

### Oh My Zsh

The installer first detects whether `powerlens` is already present in an
existing `plugins` assignment or append operation. If present, it makes no
change.

Otherwise it inserts this managed block immediately before the unambiguous
Oh My Zsh loader line:

```zsh
# >>> PowerLens installer >>>
plugins+=(powerlens)
# <<< PowerLens installer <<<
```

If no unique loader line can be found, the installer stops and prints the
manual line to add. It does not append a block that would run after Oh My Zsh
has already loaded.

### Plain zsh

The installer detects an existing source command that resolves to the
installed `powerlens.plugin.zsh`, including the installer's own managed block.
If present, it makes no change.

Otherwise it appends:

```zsh
# >>> PowerLens installer >>>
source "<absolute-install-directory>/powerlens.plugin.zsh"
# <<< PowerLens installer <<<
```

The absolute path is shell-quoted before insertion.

### Backup and Atomic Write

Immediately before a real configuration change, the installer creates a
timestamped sibling backup such as `.zshrc.powerlens-backup-20260730-153000`.
It writes the new content to a temporary file in the same directory and
renames it over the startup file.

No backup is created when the correct configuration already exists.

## Output and Errors

Output clearly distinguishes `Installing PowerLens` from `Updating
PowerLens`, reports the detected framework and paths, and ends with the command
needed to activate the plugin in the current shell:

```zsh
exec zsh
```

Errors are non-zero and describe a recovery action. The script does not use
`source ~/.zshrc` itself because doing so inside the installer process cannot
modify the parent shell and may trigger unrelated user startup commands.

The README notes that piping a mutable `main` script into a shell has a
supply-chain risk and provides a review-first alternative:

```zsh
curl -fsSLo /tmp/powerlens-install.sh \
  https://raw.githubusercontent.com/luyangkk/powerlens/main/install.sh
less /tmp/powerlens-install.sh
zsh /tmp/powerlens-install.sh
```

## Testing

Installer tests run against temporary homes, startup files, install
directories, and local Git repositories. External network access and the
user's real configuration are not used.

Tests cover:

- automatic Oh My Zsh and plain-zsh detection;
- explicit mode override and invalid mode rejection;
- first install and subsequent fast-forward update;
- architecture-specific binary validation;
- Oh My Zsh insertion before the loader;
- plain-zsh source insertion;
- existing manual configuration and repeated-run idempotency;
- backup creation only when configuration changes;
- ambiguous non-interactive detection;
- unexpected target directories, dirty repositories, wrong origins, and
  non-fast-forward updates.

The existing Go and zsh plugin suites remain unchanged and must also pass.

## Known Trade-offs

- The bootstrap script and updates track mutable `main`, so this favors
  convenience over reproducible stable releases.
- Git is required and may prompt a fresh macOS installation to install Command
  Line Tools.
- Static inspection of arbitrary `.zshrc` programs cannot be perfect; the
  installer modifies only confidently recognized layouts and otherwise falls
  back to manual instructions.
- Switching later between Oh My Zsh and plain zsh is not automatically
  migrated and may leave an old installation directory.
