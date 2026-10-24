#!/usr/bin/env bash
# Install skills/grim-agent into Cursor user or project skills.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-skill.sh <user|project> [options]

  user     Install to ~/.cursor/skills/grim-agent (all workspaces)
  project  Install to .cursor/skills/grim-agent in this repo

Options:
  -c, --copy    Copy files instead of symlinking (default: symlink)
  -f, --force   Replace an existing install at the destination
  -h, --help    Show this help

Examples:
  ./scripts/install-skill.sh user
  ./scripts/install-skill.sh project --copy
EOF
}

die() {
  echo "install-skill.sh: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
skill_name="grim-agent"
skill_src="$repo_root/skills/$skill_name"

target=""
mode="link"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    user | --user)
      target="user"
      ;;
    project | --project)
      target="project"
      ;;
    -c | --copy)
      mode="copy"
      ;;
    -f | --force)
      force=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (run with --help)"
      ;;
  esac
  shift
done

if [[ -z "$target" ]]; then
  usage >&2
  exit 1
fi

[[ -f "$skill_src/SKILL.md" ]] || die "missing $skill_src/SKILL.md (run from grimoire-agent repo)"

case "$target" in
  user)
    skill_dest="$HOME/.cursor/skills/$skill_name"
    ;;
  project)
    skill_dest="$repo_root/.cursor/skills/$skill_name"
    ;;
esac

mkdir -p "$(dirname "$skill_dest")"

if [[ -e "$skill_dest" || -L "$skill_dest" ]]; then
  if [[ $force -eq 0 ]]; then
    die "already exists: $skill_dest (use --force to replace)"
  fi
  rm -rf "$skill_dest"
fi

if [[ "$mode" == "link" ]]; then
  ln -s "$skill_src" "$skill_dest"
  echo "Linked $skill_dest -> $skill_src"
else
  cp -R "$skill_src" "$skill_dest"
  echo "Copied $skill_src -> $skill_dest"
fi
