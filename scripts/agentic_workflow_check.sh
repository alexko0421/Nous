#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/agentic_workflow_check.sh [--bead <id>] [--path <file-or-dir>]...

Runs a lightweight Nous agentic workflow guard for coding agents.

This is advisory by default. It exits non-zero only for hard safety violations,
such as tracked or untracked changes to the frozen anchor prompt, and for an
explicit --bead check that fails.

Use repeated --path arguments to narrow changed-file, staging, and verification
hints to the current task. Frozen-anchor safety still scans the full worktree.
Passing . or the repo root uses the full dirty worktree.
USAGE
}

bead_id=""
scope_paths_raw=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bead)
      shift
      if [ "${1:-}" = "" ]; then
        echo "Missing value for --bead" >&2
        usage >&2
        exit 2
      fi
      bead_id="$1"
      ;;
    --path)
      shift
      if [ "${1:-}" = "" ]; then
        echo "Missing value for --path" >&2
        usage >&2
        exit 2
      fi
      scope_paths_raw+=("$1")
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

workflow_doc="docs/agentic-engineering-workflow.md"
anchor_path="Sources/Nous/Resources/anchor.md"
hard_fail=false
scope_paths=()
explicit_full_worktree_scope=false

print_section() {
  echo
  echo "== $1 =="
}

normalize_scope_path() {
  path="$1"
  case "$path" in
    .|./|"$repo_root"|"$repo_root"/)
      printf '.\n'
      return
      ;;
    "$repo_root"/*)
      path="${path#"$repo_root"/}"
      ;;
    ./*)
      path="${path#./}"
      ;;
  esac
  printf '%s\n' "${path%/}"
}

path_is_in_scope() {
  candidate="$1"
  for scope_path in "${scope_paths[@]}"; do
    if [ "$candidate" = "$scope_path" ] || [[ "$candidate" == "$scope_path/"* ]]; then
      return 0
    fi
  done
  return 1
}

filter_to_scope() {
  while IFS= read -r candidate; do
    if [ -n "$candidate" ] && path_is_in_scope "$candidate"; then
      printf '%s\n' "$candidate"
    fi
  done
}

scope_path_has_changed_file() {
  scope_path="$1"
  while IFS= read -r candidate; do
    if [ -n "$candidate" ] &&
      { [ "$candidate" = "$scope_path" ] || [[ "$candidate" == "$scope_path/"* ]]; }; then
      return 0
    fi
  done <<EOF
$all_changed_files
EOF
  return 1
}

if [ "${#scope_paths_raw[@]}" -gt 0 ]; then
  for raw_scope_path in "${scope_paths_raw[@]}"; do
    normalized_scope_path="$(normalize_scope_path "$raw_scope_path")"
    if [ "$normalized_scope_path" = "." ]; then
      explicit_full_worktree_scope=true
      scope_paths=()
      break
    fi
    scope_paths+=("$normalized_scope_path")
  done
fi

all_changed_files="$(
  {
    git diff --cached --name-only
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
)"

all_staged_files="$(git diff --cached --name-only | sed '/^$/d' | sort -u)"

if [ "${#scope_paths[@]}" -gt 0 ]; then
  changed_files="$(printf '%s\n' "$all_changed_files" | filter_to_scope | sort -u)"
  staged_files="$(printf '%s\n' "$all_staged_files" | filter_to_scope | sort -u)"
else
  changed_files="$all_changed_files"
  staged_files="$all_staged_files"
fi

print_section "Agentic workflow"
echo "Default: one lead agent. Use explorers for noisy read-heavy work."
echo "Use the Context Boundary Card before delegating."
echo "Do not split planner / implementer / tester roles when context overlaps."
echo "Workers need explicit ownership and disjoint write sets."
echo "Agent teams remain deferred unless explicitly requested."
echo "Playbook: $workflow_doc"
if [ -n "$bead_id" ]; then
  echo "Expected bead: $bead_id"
fi
if [ "$explicit_full_worktree_scope" = true ]; then
  echo "Scope: full dirty worktree (explicit . or repo root)"
elif [ "${#scope_paths[@]}" -gt 0 ]; then
  echo "Scope: explicit path filter"
  printf '  - %s\n' "${scope_paths[@]}"
else
  echo "Scope: full dirty worktree"
fi

print_section "Changed files"
if [ -z "$changed_files" ]; then
  if [ "${#scope_paths[@]}" -gt 0 ]; then
    echo "No changed files detected in scope."
    if [ -n "$all_changed_files" ]; then
      echo "ERROR: explicit --path scope matched no changed files while the worktree has changes."
      echo "Check the path spelling, or use --path . for the full dirty worktree."
      hard_fail=true
    fi
  else
    echo "No changed files detected."
  fi
else
  printf '%s\n' "$changed_files"
fi

if [ "${#scope_paths[@]}" -gt 0 ]; then
  for scope_path in "${scope_paths[@]}"; do
    if ! scope_path_has_changed_file "$scope_path"; then
      echo "WARN: --path $scope_path matched no changed files."
    fi
  done
fi

print_section "Safety checks"
if printf '%s\n' "$all_changed_files" | grep -qx "$anchor_path"; then
  echo "ERROR: $anchor_path is frozen and must not be modified."
  hard_fail=true
else
  echo "OK: frozen anchor is unchanged."
fi

if printf '%s\n' "$all_changed_files" | grep -q '^\.codex/'; then
  echo "WARN: .codex agent/config changes detected. Confirm the user explicitly requested new agent surfaces."
else
  echo "OK: no .codex agent/config changes detected."
fi

if find Sources/Nous -maxdepth 1 -name "*.swift" -print -quit | grep -q .; then
  echo "WARN: Swift files exist at Sources/Nous root. AGENTS.md says Swift files belong in subdirectories."
else
  echo "OK: no Swift files at Sources/Nous root."
fi

print_section "Verification hints"
if printf '%s\n' "$changed_files" | grep -qx 'project.yml'; then
  echo "VERIFY: project.yml changed -> run xcodegen generate, then macOS build."
fi

if printf '%s\n' "$changed_files" | grep -q '^Nous\.xcodeproj/' &&
  ! printf '%s\n' "$changed_files" | grep -qx 'project.yml'; then
  echo "WARN: xcodeproj changed without project.yml. Confirm this is generated state, not project config drift."
fi

if printf '%s\n' "$changed_files" | grep -q '\.swift$'; then
  echo "VERIFY: Swift changed -> run focused tests or full NousTests; run macOS build when shared behavior changed."
fi

if printf '%s\n' "$changed_files" | grep -q '^scripts/.*\.sh$'; then
  echo "VERIFY: shell scripts changed -> run bash -n on changed scripts and execute their relevant help/check path."
fi

if [ -n "$changed_files" ] &&
  ! printf '%s\n' "$changed_files" | grep -q '\.swift$' &&
  ! printf '%s\n' "$changed_files" | grep -qx 'project.yml' &&
  ! printf '%s\n' "$changed_files" | grep -q '^scripts/.*\.sh$'; then
  echo "VERIFY: docs/config-only change -> targeted rg checks plus git diff review are usually enough."
fi

print_section "Staging checks"
if [ -z "$staged_files" ]; then
  if [ "${#scope_paths[@]}" -gt 0 ]; then
    echo "OK: no staged files in scope."
  else
    echo "OK: no staged files."
  fi
else
  if [ "${#scope_paths[@]}" -gt 0 ]; then
    echo "WARN: staged files are present in scope:"
  else
    echo "WARN: staged files are present. Use a path-limited commit if this task scope is narrower:"
  fi
  printf '%s\n' "$staged_files"
fi

print_section "Beads"
if command -v bd >/dev/null 2>&1; then
  if [ -n "$bead_id" ]; then
    bead_json="$(bd show "$bead_id" --json 2>/dev/null || true)"
    if [ -z "$bead_json" ] || printf '%s\n' "$bead_json" | grep -q '"error"[[:space:]]*:'; then
      echo "ERROR: requested bead $bead_id was not found."
      hard_fail=true
    elif printf '%s\n' "$bead_json" | grep -q '"status"[[:space:]]*:[[:space:]]*"in_progress"'; then
      echo "OK: requested bead $bead_id is in progress."
    else
      status="$(printf '%s\n' "$bead_json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      echo "ERROR: requested bead $bead_id status is ${status:-unknown}; expected in_progress."
      hard_fail=true
    fi
  else
    in_progress="$(bd list --status=in_progress --json 2>/dev/null || true)"
    if [ "$in_progress" = "[]" ] || [ -z "$in_progress" ]; then
      echo "WARN: no in-progress bead found. Non-trivial code/docs work should claim or create one before edits."
    else
      echo "INFO: in-progress bead(s) exist; confirm one belongs to this task or rerun with --bead <id>."
      printf '%s\n' "$in_progress" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/- \1/p'
    fi
  fi
else
  echo "WARN: bd CLI not found. Run scripts/beads_agent_workflow.sh start to initialize/check Beads."
fi

print_section "Result"
if [ "$hard_fail" = true ]; then
  echo "FAIL: resolve hard safety violations before handoff."
  exit 1
fi

echo "PASS: no hard workflow violations detected."
