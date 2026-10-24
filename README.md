# grimoire-agent

`grim-agent` is a small CLI for AI agents: find credentials, inject `grim://` or `op://` references into commands and env files, create API credentials, and manage a local service-account token—without printing secrets by default.

It wraps `grim` from the [**grimoire**](https://github.com/aboisvert/grimoire) project. `grim` implements the 1Password `op`-compatible command lines this tool expects.

## Typical use

Store real secrets in your grimoire vault. In your project, keep a `.env` file that names those secrets with **`grim://`** references—not plaintext values. The file tells your app *which* secret each variable needs; grimoire still holds the actual value.

```dotenv
# .env — safe to treat as a template (no real secrets in the file)
API_TOKEN=grim://my-vault/my-secret
```

When you run a program that reads the environment (a dev server, a deploy script, a one-off CLI), use **`env run`** so `grim-agent` resolves the references and starts the command with the real values injected. Nothing is written to a resolved `.env` on disk unless you ask for that separately.

```bash
grim-agent env run .env -- other-command
```

Everything after `--` is the command to run. `other-command` (and its children) see `API_TOKEN` set to the value from vault `my-vault`, item `my-secret`. `grim-agent` itself does not print the secret to your terminal.

You need `grim` on your `PATH` (or set `GRIM_BIN`) and a working grimoire session—desktop sign-in or a service account. See [Configuration](#configuration) below.

More detail: `USAGE.md` and `grim-agent env run --help`.

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
