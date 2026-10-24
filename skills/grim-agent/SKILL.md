---
name: grim-agent
description: Use for passwords, API keys, tokens, credentials, and secrets—find references, inject into commands or env files, save API keys, check or update login passwords, audit vaults, and set up unattended access. Prefer grim-agent over raw grim when it covers the task.
---

# grim-agent

`grim-agent` wraps the `grim` CLI (grimoire) so you can work with secrets without seeing them. Discovery and receipts are JSON; `read` is explicit.

## Rules

- Never print, log, summarize, or repeat secret values. Pass `op://` references around instead.
- Batch work into as few `grim` calls as possible: many queries in one `find`, many references in one `env run`.
- Never run `grim whoami` or other preflights. Run the operation you need.
- Never retry a write that failed or reported "unverified". Run `find` first.

## Find credentials

```bash
grim-agent find openai anthropic "github actions"
grim-agent find stripe --vault Work --account grimoire
```

Matches are `{ ref, title, kind }` with optional `queries`. Misses return `suggestions`. No values.

## Use credentials

```bash
grim-agent run --env "OPENAI_API_KEY=op://Automation/OpenAI API Key/credential" -- bun run dev
grim-agent env write .env.tpl "OPENAI_API_KEY=op://Automation/OpenAI API Key/credential"
grim-agent env run .env.tpl -- bun run dev
grim-agent env resolve .env.tpl --output .env
grim-agent read "op://Automation/OpenAI API Key/credential"
```

Prefer `env run` over resolving to disk. The child process receives plaintext; treat it as trusted.

## Save a new API key

```bash
grim-agent create api-credential --title "OpenAI API Key" --vault Automation --clipboard
cmd-that-prints-key | grim-agent create api-credential --title "OpenAI API Key" --vault Automation --stdin
```

`--vault` is required. Success includes `"verified": true` and a `ref`.

## Service account (macOS)

```bash
grim-agent service-account setup --vault Automation --create-vault --write --save-vault Personal
```

Settings live in `~/.config/grimoire-agent/service-account.json`; the token is in macOS Keychain. Use `grim-agent --desktop` for owner GPG access outside the automation vault.

## Diagnostics

```bash
grim-agent doctor
```

Safe to paste publicly: versions and counts only.
