set shell := ["bash", "-euo", "pipefail", "-c"]

nim_flags := "-d:release -d:strip --opt:speed"
nim_image := "nimlang/nim:2.2.12"

default:
    @just --list

# Version string from grimoireagent.nimble (e.g. 0.1.0)
version:
    @grep -E '^version' grimoireagent.nimble | head -1 | sed -E 's/.*= *"([^"]+)".*/\1/'

# Build release binaries for macOS arm64 and Linux amd64 into dist/
build:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(just version)"
    just build-darwin "$v"
    just build-linux "$v"
    echo "Built dist/grim-agent-${v}-darwin-arm64 and dist/grim-agent-${v}-linux-amd64"

build-darwin version:
    mkdir -p dist
    nim c {{nim_flags}} --path:src -o:"dist/grim-agent-{{version}}-darwin-arm64" src/grim_agent.nim

build-linux version:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{version}}"
    out="grim-agent-${v}-linux-amd64"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    rsync -a \
        --exclude .git \
        --exclude dist \
        --exclude grim-agent \
        --exclude nimble.paths \
        --exclude nimcache \
        --exclude .cursor \
        ./ "$tmp/"
    mkdir -p "$tmp/dist"
    docker run --rm --platform linux/amd64 \
        -v "$tmp:/work" \
        -w /work \
        -u "$(id -u):$(id -g)" \
        -e HOME=/tmp/nimhome \
        -e NIMBLE_DIR=/tmp/nimhome/.nimble \
        {{nim_image}} \
        bash -c 'mkdir -p /tmp/nimhome/.nimble && nim c {{nim_flags}} --path:src -o:"dist/'"$out"'" src/grim_agent.nim'
    mkdir -p dist
    cp "$tmp/dist/$out" "dist/$out"

# Run tests, build, tag, and publish a GitHub release for the nimble version
release:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(just version)"
    just preflight "$v"
    nimble test
    just build-darwin "$v"
    just build-linux "$v"
    (
        cd dist
        shasum -a 256 "grim-agent-${v}-darwin-arm64" "grim-agent-${v}-linux-amd64" > SHA256SUMS
    )
    git tag "v${v}"
    git push origin "v${v}"
    notes="$(mktemp)"
    trap 'rm -f "$notes"' EXIT
    {
        echo "## Binaries"
        echo ""
        echo "- \`grim-agent-${v}-darwin-arm64\` — macOS Apple Silicon"
        echo "- \`grim-agent-${v}-linux-amd64\` — Linux x86_64 (glibc, dynamic; built in \`nimlang/nim:2.2.12\`)"
        echo ""
        echo "Verify with \`SHA256SUMS\` in this release."
    } > "$notes"
    gh release create "v${v}" \
        --title "v${v}" \
        --notes-file "$notes" \
        "dist/grim-agent-${v}-darwin-arm64" \
        "dist/grim-agent-${v}-linux-amd64" \
        "dist/SHA256SUMS"
    echo "Published https://github.com/aboisvert/grimoire-agent/releases/tag/v${v}"
    next="$(just next-patch "$v")"
    just bump-version "$next"
    git add grimoireagent.nimble src/version.nim
    git commit -m "Bump version to ${next}"
    git push origin main
    echo "Development version is now ${next} (commit and push to main)"

# Print semver with patch incremented (e.g. 0.1.0 -> 0.1.1)
next-patch version:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{version}}"
    IFS='.' read -r major minor patch <<< "$v"
    if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]]; then
        echo "invalid semver: $v" >&2
        exit 1
    fi
    echo "${major}.${minor}.$((patch + 1))"

# Update version strings for the next development cycle
bump-version to:
    #!/usr/bin/env bash
    set -euo pipefail
    from="$(just version)"
    to="{{to}}"
    if [[ "$from" == "$to" ]]; then
        exit 0
    fi
    sed -i '' "s/^version       = \"${from}\"/version       = \"${to}\"/" grimoireagent.nimble
    sed -i '' "s/const grimAgentVersion\* = \"${from}\"/const grimAgentVersion* = \"${to}\"/" src/version.nim

preflight version:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{version}}"
    command -v nim >/dev/null || { echo "nim not found"; exit 1; }
    command -v docker >/dev/null || { echo "docker not found"; exit 1; }
    command -v gh >/dev/null || { echo "gh not found"; exit 1; }
    if [[ -z "$v" ]]; then
        echo "empty version from grimoireagent.nimble"
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "working tree is not clean"
        exit 1
    fi
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "main" ]]; then
        echo "expected branch main, got $branch"
        exit 1
    fi
    git fetch origin main
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        echo "HEAD is not origin/main"
        exit 1
    fi
    if git rev-parse "v${v}" >/dev/null 2>&1; then
        echo "tag v${v} already exists locally"
        exit 1
    fi
    if git ls-remote --tags origin "refs/tags/v${v}" | grep -q .; then
        echo "tag v${v} already exists on origin"
        exit 1
    fi
    if gh release view "v${v}" >/dev/null 2>&1; then
        echo "GitHub release v${v} already exists"
        exit 1
    fi
