# grimoire-agent

`grim-agent` is a small CLI for AI agents: find credentials, inject `grim://` or `op://` references into commands and env files, create API credentials, and manage a local service-account token—without printing secrets by default.

It wraps `grim` from the **grimoire** repo (for example `~/nim/grimoire`; build with `nim c -o:grim src/grim.nim`). `grim` implements the `op`-compatible command lines this tool expects.

## Build

```bash
nim c --path:src -o:grim-agent src/grim_agent.nim
```

## Release

From a clean `main` at `origin/main`, with `nim`, `docker`, and `gh` installed:

```bash
just release
```

This runs tests, builds macOS arm64 and Linux amd64 binaries into `dist/`, tags `v` plus the version from `grimoireagent.nimble`, publishes a GitHub release with `SHA256SUMS`, then bumps the patch version on `main` for the next development cycle.

## Test

```bash
nim c --path:src -o:grim-agent src/grim_agent.nim
nim c -r --path:src --path:tests tests/all_tests.nim
```

Integration tests use a fake `grim` on an isolated `PATH`. Opt-in end-to-end tests against a real `grim` binary:

```bash
GRIM_E2E=1 GRIM_BIN=~/nim/grimoire/grim nim c -r --path:src --path:tests tests/e2e_tests.nim
```

## Configuration

- Service account settings: `~/.config/grimoire-agent/service-account.json`
- macOS token storage: Keychain service `grimoire-agent`, account `service-account`
- Environment: `OP_SERVICE_ACCOUNT_TOKEN`, `OP_ACCOUNT`, `GRIM_BIN` (optional path to `grim`)

## Commands

See `skills/grim-agent/SKILL.md` for agent-oriented usage, or run `grim-agent --help`.

Install the Cursor skill (symlink by default):

```bash
chmod +x scripts/install-skill.sh
./scripts/install-skill.sh user      # ~/.cursor/skills/grim-agent
./scripts/install-skill.sh project   # .cursor/skills/grim-agent in this repo
```
