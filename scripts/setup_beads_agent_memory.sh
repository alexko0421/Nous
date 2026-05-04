#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/setup_beads_agent_memory.sh [--install]

Sets up Beads as the shared engineering memory for Nous coding agents.

Options:
  --install   Install beads with Homebrew if the bd CLI is missing.
  -h, --help  Show this help.

Environment:
  NOUS_BEADS_DIR  Shared Beads directory. Defaults to ~/.local/share/nous/beads.
USAGE
}

install=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install)
      install=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

shared_dir="${NOUS_BEADS_DIR:-$HOME/.local/share/nous/beads}"

if ! command -v bd >/dev/null 2>&1; then
  if [ "$install" = true ]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "bd is missing and Homebrew is not available." >&2
      echo "Install Beads manually, then rerun this script." >&2
      exit 1
    fi
    brew install beads
  else
    cat >&2 <<EOF
bd is not installed.

Install it explicitly, then rerun this script:
  brew install beads

Or allow this script to install it:
  scripts/setup_beads_agent_memory.sh --install
EOF
    exit 1
  fi
fi

if ! command -v bd >/dev/null 2>&1; then
  echo "bd is still unavailable after installation attempt." >&2
  exit 1
fi

mkdir -p "$shared_dir"
chmod 700 "$shared_dir"

if [ ! -f "$shared_dir/metadata.json" ]; then
  BEADS_DIR="$shared_dir" bd init --quiet --stealth
fi

# Keep the shared database in local-only mode. The first version uses a shared
# local Beads directory; Dolt remotes are a later upgrade if cross-machine sync
# becomes painful.
BEADS_DIR="$shared_dir" bd config set no-git-ops true >/dev/null 2>&1 || true
BEADS_DIR="$shared_dir" bd config set export.auto false >/dev/null 2>&1 || true

if [ -e ".beads" ] && [ ! -d ".beads" ]; then
  echo ".beads exists but is not a directory. Move it before running setup." >&2
  exit 1
fi

if [ -d ".beads" ] && [ ! -f ".beads/redirect" ]; then
  if find ".beads" -mindepth 1 -maxdepth 1 | grep -q .; then
    cat >&2 <<EOF
.beads already contains local state and has no redirect.

This script will not overwrite existing Beads data. Move or back up .beads,
then rerun setup if you want this workspace to use the shared Nous Beads store:
  $shared_dir
EOF
    exit 1
  fi
fi

mkdir -p ".beads"
printf '%s\n' "$shared_dir" > ".beads/redirect.tmp"
mv ".beads/redirect.tmp" ".beads/redirect"

seed_memory() {
  key="$1"
  value="$2"
  BEADS_DIR="$shared_dir" bd remember "$value" --key "$key" >/dev/null
}

seed_memory "anchor-frozen" "Sources/Nous/Resources/anchor.md is frozen. Do not modify it; put behavior or prompt changes elsewhere."
seed_memory "raw-sqlite-owned-layer" "Nous intentionally uses raw SQLite C APIs for full data-layer control. Do not introduce SwiftData, Core Data, or an ORM."
seed_memory "swift-files-subdirectories" "Swift files belong in Sources/Nous subdirectories such as App, Views, ViewModels, Services, Models, and Theme; never add Swift files at Sources/Nous root."
seed_memory "project-yml-xcodegen" "project.yml is the Xcode project source of truth. After changing it, run xcodegen generate before building."
seed_memory "canonical-build-command" "Canonical build: xcodegen generate, then xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build."
seed_memory "canonical-test-command" "Canonical tests: xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'. NodeStore tests use NodeStore(path: ':memory:')."
seed_memory "icloud-drive-orphans" "This repo lives in iCloud Drive. After moving or deleting Swift files, verify no root orphans with find Sources/Nous -maxdepth 1 -name '*.swift'."
seed_memory "beads-engineering-boundary" "Beads is for coding-agent engineering memory and task graph only. Alex/product/thinking memory belongs in Nous, not bd remember."
seed_memory "beads-cli-first" "Use Beads through the bd CLI in Conductor/Codex sessions. MCP is deferred for no-shell environments."
seed_memory "beads-workflow-helper" "Start coding sessions with scripts/beads_agent_workflow.sh start. For non-trivial code/docs work, claim or create a bead before editing and finish with scripts/beads_agent_workflow.sh finish."
seed_memory "agent-discovered-work" "When coding reveals follow-up work, create a bead linked with discovered-from instead of silently expanding scope."

if [ -f "$shared_dir/issues.jsonl" ] && ! grep -q '"_type":"issue"' "$shared_dir/issues.jsonl"; then
  rm -f "$shared_dir/issues.jsonl"
fi

echo "Beads agent memory is ready."
echo "Shared Beads dir: $shared_dir"
echo "Workspace redirect: $repo_root/.beads/redirect"
echo
echo "Next:"
echo "  bd prime"
echo "  bd ready --json"
