# Remove SSH Detection Design

## Context

PowerLens currently treats any shell with `SSH_TTY`, `SSH_CONNECTION`, or
`SSH_CLIENT` set as degraded. `_powerlens_init` sets a placeholder-only
`RPROMPT` and returns before starting the daemon or registering the prompt
refresh hooks. As a result, an SSH session on a supported macOS host never
receives live metrics.

This behavior is a regression: removing the SSH guard previously allowed SSH
sessions to use the same collection and refresh path as local shells.

## Goal

Make PowerLens initialize normally in SSH sessions, so it shows live metrics
for the remote macOS host.

## Scope

The change is intentionally limited to:

- deleting `_powerlens_is_ssh`;
- deleting the SSH-only early return from `_powerlens_init`;
- replacing the SSH degraded-mode test with a regression test for normal SSH
  initialization; and
- updating README statements that claim SSH sessions skip the daemon.

The daemon lifecycle, session counter, installer, configuration, formatting,
and metric collection behavior are out of scope.

## Runtime Behavior

`_powerlens_init` will no longer branch on SSH environment variables. Local
and SSH shells will both:

1. compute the degraded placeholder used while data is unavailable;
2. start or join the PowerLens daemon;
3. register the `precmd`, `zshexit`, and ZLE refresh hooks; and
4. configure periodic refresh through `TMOUT` when needed.

Existing cache-staleness and unavailable-metric behavior remains unchanged.
Metrics shown over SSH describe the remote Mac running PowerLens, including
its network interface, rather than the SSH client machine.

## Tests

The existing test that expects SSH to remain degraded will be replaced by a
regression test that sets an SSH environment variable and verifies that normal
initialization is reached. The test must fail against the current guard and
pass after its removal.

The full Zsh test suite and the existing Go verification commands will be run
after the focused regression test passes.

## Documentation

README entries describing PowerLens as SSH-aware by skipping its daemon will
be removed or rewritten. The behavior reference will state that SSH sessions
behave like local sessions and report metrics from the remote Mac.

## Accepted Side Effects

- An SSH shell will start or join the same lightweight collector used by local
  shells, adding its normal CPU, memory, and power overhead.
- Display quality still depends on the SSH client's font, color, and terminal
  capabilities.
- The existing daemon session-counting behavior is unchanged, including any
  limitations it already has.
