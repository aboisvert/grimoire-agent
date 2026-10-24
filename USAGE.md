# grim-agent usage

`grim-agent` is a CLI for finding, creating, and using secrets through [grimoire](https://github.com/)’s `grim` binary (1Password-compatible `op` surface). By default it works with **references** (`grim://…` or `op://…`) and JSON receipts—not plaintext secrets.

Build:

```bash
nim c --path:src -o:grim-agent src/grim_agent.nim
```

---

## Global options

These flags may appear **before** the subcommand.

| Flag | Description |
|------|-------------|
| `--desktop` | Authenticate with the desktop app (owner GPG / interactive approvals). Clears service-account env vars for this process. Use when you need vaults or items outside the automation service account. |
| `--version`, `-v` | Print `grim-agent` version and exit. |
| `--help`, `-h` | Print usage summary (commands, flags, examples) and exit. |

If no subcommand is given, the CLI exits with an error.

---

## Authentication

Except for `doctor`, every command resolves credentials once at startup:

1. **`--desktop`** — desktop / owner session (no `OP_SERVICE_ACCOUNT_TOKEN` in the child environment).
2. **`OP_SERVICE_ACCOUNT_TOKEN`** in the environment — explicit service account.
3. **Saved service account** — token in macOS Keychain (`grimoire-agent` / `service-account`) plus `~/.config/grimoire-agent/service-account.json`.
4. **Otherwise** — `grim` uses its normal desktop/default auth (may prompt per shell session).

### Environment variables

| Variable | Purpose |
|----------|---------|
| `GRIM_BIN` | Path to the `grim` executable (default: `grim` on `PATH`). |
| `OP_SERVICE_ACCOUNT_TOKEN` | Service-account token; takes precedence over Keychain when not using `--desktop`. |
| `OP_ACCOUNT` | Optional account shorthand for `grim` (`--account` on individual commands overrides). |

### Configuration files

| Path | Purpose |
|------|---------|
| `~/.config/grimoire-agent/service-account.json` | Service account display name, allowed vaults, optional `tokenRef` for the backed-up token item. |
| macOS Keychain | Stores the raw service-account token (not in the JSON file). |

---

## Secret references

Assignments and env templates use **grimoire secret references**. The value side must start with `grim://` or `op://` (both are accepted by `grim`):

| Scheme | Form |
|--------|------|
| `op://` | `op://VaultOrVaultId/ItemTitleOrItemId/field` — 1Password-style field path |
| `grim://` | `grim://vault/secret` or `grim://vault/secret/value` — native grimoire vault + secret title |

Examples:

```text
OPENAI_API_KEY=op://Automation/OpenAI API Key/credential
DB_PASSWORD=grim://Work/Production DB/value
```

`find` and `create` usually return `op://` refs from the 1Password-compatible item API; hand-authored templates and direct `grim` usage may use `grim://` instead.

Environment variable names must look like shell identifiers: `[A-Za-z_][A-Za-z0-9_]*`.

---

## Exit status

| Code | Meaning |
|------|---------|
| `0` | Success (JSON printed to stdout for most commands). |
| `1` | Error; message on stderr as `grim-agent: …`. |
| Child exit code | `run` and `env run` forward the wrapped command’s exit code. |

---

## Commands

### `find` — search vault items by title

Resolve one or more search strings to concealed fields (API credentials, passwords, etc.) without returning secret values.

```text
grim-agent find QUERY [QUERY ...] [--vault VAULT] [--account ACCOUNT]
```

| Argument / flag | Required | Description |
|-----------------|----------|-------------|
| `QUERY` | Yes (≥1) | Whitespace-separated terms; an item title must contain **all** terms (case-insensitive). |
| `--vault` | No | Limit listing to one vault (name or ID). |
| `--account` | No | Pass through to `grim --account`. |

**Stdout (JSON):**

- `matches` — array of `{ "ref", "title", "kind" }`. If you passed multiple queries, each match may include `"queries": ["…"]` listing which queries hit it.
- `suggestions` — present when a query had **no** title match; fuzzy near-misses with `{ "query", "ref", "title", "kind" }`.

**Examples:**

```bash
grim-agent find openai anthropic
grim-agent find stripe --vault Work --account grimoire
```

---

### `inventory` — list items and field metadata

Full vault inventory: titles, kinds, tags, URLs (query strings stripped), and field labels/types/references—still no secret values.

```text
grim-agent inventory [--vault VAULT] [--account ACCOUNT]
```

**Stdout (JSON):** `{ "items": [ … ] }` where each item includes `id`, `title`, `vault`, `kind`, `tags`, `urls`, `fields` (with optional `ref`), and timestamps when available.

**Example:**

```bash
grim-agent inventory --vault Automation
```

---

### `audit` — hygiene report

Runs `inventory` and aggregates common cleanup signals: duplicate titles, untagged machine-oriented items, stale logins, and URLs that look transient (OAuth callbacks, reset links, etc.).

```text
grim-agent audit [--vault VAULT] [--account ACCOUNT]
```

**Stdout (JSON):** `summary`, `duplicateTitles`, `untaggedMachineCredentials`, `oldLogins` (not updated in 5+ years), `urlsToReview`.

**Example:**

```bash
grim-agent audit
```

---

### `read` — resolve one reference to stdout

**Warning:** prints the **plaintext** secret to stdout. Use only when you explicitly need the value in the shell; prefer `run` / `env run` for subprocesses.

```text
grim-agent read REFERENCE
```

| Argument | Description |
|----------|-------------|
| `REFERENCE` | Full `grim://…` or `op://…` path. |

**Stdout:** raw secret bytes (no JSON wrapper). **Stderr:** none on success.

**Example:**

```bash
grim-agent read "op://Automation/OpenAI API Key/credential"
grim-agent read "grim://Automation/OpenAI API Key/value"
```

---

### `run` — inject env vars and run a command

Sets environment variables to secret references, then runs a child through `grim run` (references resolved inside the child). The child process receives **plaintext** values.

```text
grim-agent run --env NAME=REF [--env NAME=REF ...] -- COMMAND [ARGS ...]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--env` | Yes (≥1) | `VAR=grim://…` or `VAR=op://…` assignment; repeat for multiple vars. |
| `--` | Yes | Separates `grim-agent` flags from the command to execute. |
| `COMMAND` | Yes | Executable and arguments. Arguments after `--` are passed through unchanged (including flags like `--verbose`). |

**Stdout/stderr:** whatever the child prints. **Exit code:** child’s exit code.

**Examples:**

```bash
grim-agent run --env "OPENAI_API_KEY=op://Automation/OpenAI API Key/credential" -- bun run dev
grim-agent run --env "API_KEY=op://Work/Service/credential" -- mytool --flag value
```

---

### `env` — template files with secret-reference placeholders

#### `env write` — create or overwrite a reference template

```text
grim-agent env write FILE NAME=REF [NAME=REF ...]
```

Writes `NAME=grim://…` or `NAME=op://…` lines (one per assignment) plus a trailing newline. **Stderr:** `Wrote N secret references to FILE`.

**Example:**

```bash
grim-agent env write .env.tpl "OPENAI_API_KEY=op://Automation/OpenAI API Key/credential"
```

#### `env resolve` — materialize plaintext `.env`

Reads a template (from `env write` or hand-authored). Lines that are comments, blank, non-reference literals, or `export VAR=grim://…` / `export VAR=op://…` are handled; reference lines are resolved in **one** batched `grim` call.

```text
grim-agent env resolve FILE (--output PATH | --in-place)
```

| Flag | Description |
|------|-------------|
| `--output PATH` | Write resolved content to `PATH` (file mode `600` on Unix). |
| `--in-place` | Replace `FILE` atomically (same permissions behavior). |

Exactly one of `--output` or `--in-place` is required.

**Stderr:** warns that the output file contains plaintext secrets.

**Example:**

```bash
grim-agent env resolve .env.tpl --output .env
```

#### `env run` — run a command with an env file

Equivalent to `grim run --env-file=FILE` with reference resolution deferred to `grim`.

```text
grim-agent env run FILE -- COMMAND [ARGS ...]
```

**Example:**

```bash
grim-agent env run .env.tpl -- bun run dev
```

---

### `create api-credential` — store a new API key

Creates a verified `API_CREDENTIAL` item. The secret is read from clipboard or stdin—never from argv.

```text
grim-agent create api-credential \
  --title TITLE \
  --vault VAULT \
  (--clipboard | --stdin) \
  [--account ACCOUNT] \
  [--url URL] \
  [--notes NOTES]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--title` | Yes | Item title; must not already exist in the vault. |
| `--vault` | Yes | Target vault name or ID. |
| `--clipboard` | One of clipboard/stdin | Read credential from the system clipboard (macOS: `pbpaste`). |
| `--stdin` | One of clipboard/stdin | Read credential from piped stdin (not interactive TTY). |
| `--account` | No | `grim --account`. |
| `--url` | No | Primary URL on the item. |
| `--notes` | No | Notes field. |

**Stdout (JSON):** on success, `{ "id", "title", "vault", "kind", "field", "ref", "verified": true }`.

On ambiguous or unverified creation, the command **fails** with guidance to run `find` first—**do not retry** blindly.

**Examples:**

```bash
grim-agent create api-credential --title "OpenAI API Key" --vault Automation --clipboard
cmd-that-prints-key | grim-agent create api-credential --title "OpenAI API Key" --vault Automation --stdin
```

---

### `password` — check or update a login password

Targets a **Login** item with exactly one built-in password field. Secret input via `--clipboard` or `--stdin` only.

```text
grim-agent password ITEM \
  --vault VAULT \
  (--clipboard | --stdin) \
  [--account ACCOUNT] \
  [--apply] \
  [--repair-imported-fields]
```

| Flag | Description |
|------|-------------|
| `ITEM` | Item ID or title (passed to `grim item get`). |
| `--vault` | Vault name or ID (required). |
| `--clipboard` / `--stdin` | Source of the password (exactly one required). |
| `--apply` | If omitted, **dry run**: JSON includes `"matches": true/false` comparing to the vault value; nothing is written. |
| `--apply` present | Updates the password when different; read-back verified. |
| `--repair-imported-fields` | When applying, assign synthetic IDs to unnamed imported fields (use only when you understand the item template). |

**Stdout (JSON):** `id`, `title`, `vault`, `ref`; with `--apply`, `changed` and `verified`; without `--apply`, `matches`.

Items with passkeys or unsafe templates are rejected without changes.

**Examples:**

```bash
# Compare only
grim-agent password "My Login" --vault Personal --stdin <<<"$NEW"

# Update
grim-agent password "My Login" --vault Personal --stdin --apply <<<"$NEW"
```

---

### `service-account` — unattended macOS automation

Manages a local 1Password service account for agents. **Setup and Keychain storage require macOS.** On other platforms, set `OP_SERVICE_ACCOUNT_TOKEN` manually.

#### `service-account setup`

Creates a service account, saves the token to Keychain, writes settings, and backs up the token as an API credential in a separate vault (using desktop auth for admin steps).

```text
grim-agent service-account setup \
  --save-vault BACKUP_VAULT \
  [--name NAME] \
  [--vault AUTOMATION_VAULT] \
  [--account ACCOUNT] \
  [--create-vault] \
  [--write] \
  [--expires-in DURATION]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--save-vault` | *(required)* | Existing vault where the token is stored as an item (must not be the automation vault). |
| `--name` | `grimoire-agent Automation` | Service account name in 1Password. |
| `--vault` | `Automation` | Dedicated automation vault (not Personal/Private/Employee/Shared). |
| `--create-vault` | off | Create `--vault` if it does not exist. |
| `--write` | off | Grant `write_items` on the automation vault (default is read-only). |
| `--expires-in` | none | Token lifetime, e.g. `90d`, `12h`, `30m` (positive number + `s|m|h|d|w`). |
| `--account` | none | Admin `grim --account` during setup. |

Fails if a service account is already configured (`status` / `forget` first). On partial failure, messages tell you to inspect 1Password—not repeat setup.

**Example:**

```bash
grim-agent service-account setup --vault Automation --create-vault --write --save-vault Personal
```

#### `service-account connect`

Save an existing `ops_…` token without creating a new service account.

```text
grim-agent service-account connect (--clipboard | --stdin) [--name NAME]
```

Default `--name`: `grimoire-agent Automation`.

#### `service-account status`

**Stdout (JSON):** `configured`, `name`, `vaults`, `storage`, `verified`, `manageUrl`; optional `tokenRef` if backed up.

#### `service-account recover`

Reconcile `service-account.json` with vaults visible to the Keychain token (after restore or drift).

```text
grim-agent service-account recover [--name NAME]
```

#### `service-account forget`

Remove Keychain token and delete local settings. Does **not** revoke the remote service account.

```text
grim-agent service-account forget
```

---

### `doctor` — safe diagnostics

Does **not** load service-account credentials. Probes `grim` locally.

```text
grim-agent doctor
```

**Stdout (JSON):** `grim-agent` version, `platform`, `nim`, `auth` mode, `grim` version (or `null`), `accounts` count (or `null`), optional `notes` (install hints, desktop approval behavior).

Safe to share publicly—no secrets or vault contents.

**Example:**

```bash
grim-agent doctor
```

---

## Security notes

- **Default posture:** use `find`, `inventory`, and `audit` for discovery; pass `grim://` or `op://` refs into `run` / `env run` instead of `read` or `env resolve`.
- **Plaintext on disk:** `env resolve` and `--in-place` create files with real secrets (`chmod 600` on Unix). Prefer `env run` when possible.
- **Failed writes:** if `create`, `password --apply`, or `service-account setup` reports unverified state, run `find` or inspect 1Password before retrying—retries can duplicate items or leave ambiguous state.
- **Child processes:** `run` and `env run` expose secrets to the invoked program; only run trusted commands.

---

## Related docs

- Agent-oriented quick reference: [`skills/grim-agent/SKILL.md`](skills/grim-agent/SKILL.md)
- Build and test: [`README.md`](README.md)
