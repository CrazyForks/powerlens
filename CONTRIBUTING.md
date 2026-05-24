# Contributing to PowerLens

Thank you for your interest in contributing!

## Prerequisites

- macOS 12 (Monterey) or later
- Go 1.21+
- Zsh 5.8+ with Oh-My-Zsh
- The plugin installed at `~/.oh-my-zsh/custom/plugins/powerlens`

## Development Setup

```bash
git clone https://github.com/luyangkk/powerlens.git
cd powerlens
```

Build the daemon binary:

```bash
make arm64    # Apple Silicon
make amd64    # Intel
```

Reload the plugin to pick up changes:

```bash
source ~/.zshrc
```

## Running Tests

```bash
cd src
go test ./...
go vet ./...
```

The test suite requires macOS — platform-specific collectors (`IOKit`, `SMC`) are not available on Linux.

## Project Structure

```
powerlens.zsh            # Main plugin entry point (sourced by zsh)
powerlens.plugin.zsh     # Oh-My-Zsh plugin wrapper
src/
  main.go                # Daemon entry point
  collect/               # Metric collectors (CPU, memory, battery, network, temp)
  go.mod / go.sum
bin/                     # Pre-compiled daemon binaries (not committed to git)
assets/                  # Demo and reference SVGs
tests/                   # Integration tests
```

## Submitting a Pull Request

1. Fork the repository and create a feature branch from `main`.
2. Make your changes and ensure `go test ./...` passes.
3. Keep commits focused — one logical change per commit.
4. Open a PR against `main` and fill in the PR template.

## Reporting Bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) when opening an issue. Including your macOS version, chip, and the output of `powerlens_status` (if available) greatly speeds up triage.

## Code Style

- Go code: standard `gofmt` formatting, enforced by CI.
- Zsh code: follow the existing style in `powerlens.zsh`.
- No new dependencies without discussion — the daemon binary size matters for install time.
