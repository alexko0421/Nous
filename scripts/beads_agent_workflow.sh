#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/beads_agent_workflow.sh start
  scripts/beads_agent_workflow.sh status
  scripts/beads_agent_workflow.sh claim <bead-id>
  scripts/beads_agent_workflow.sh create "<title>" "<description>" [priority]
  scripts/beads_agent_workflow.sh discovered <current-id> "<title>" "<description>" [priority]
  scripts/beads_agent_workflow.sh finish <bead-id> "<verification summary>"
  scripts/beads_agent_workflow.sh no-bead "<reason>"

Enforces the Nous Beads agent workflow for coding agents.
USAGE
}

require_arg() {
  name="$1"
  value="${2:-}"
  if [ -z "$value" ]; then
    echo "Missing required argument: $name" >&2
    usage >&2
    exit 2
  fi
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

scripts/setup_beads_agent_memory.sh >/dev/null

command_name="${1:-}"
if [ -z "$command_name" ]; then
  usage
  exit 2
fi
shift || true

case "$command_name" in
  start)
    echo "== bd prime =="
    bd prime
    echo
    echo "== ready work =="
    bd ready --json
    echo
    echo "== in progress =="
    bd list --status=in_progress --json
    cat <<'EOF'

Agent gate:
- Non-trivial code/docs work must claim or create a bead before edits.
- Final answer must include either "Bead: <id> <status>" or "No bead: <reason>".
EOF
    ;;

  status)
    echo "== ready work =="
    bd ready --json
    echo
    echo "== in progress =="
    bd list --status=in_progress --json
    echo
    echo "== git status =="
    git status --short
    ;;

  claim)
    bead_id="${1:-}"
    require_arg "bead-id" "$bead_id"
    bd update "$bead_id" --claim --json
    ;;

  create)
    title="${1:-}"
    description="${2:-}"
    priority="${3:-2}"
    require_arg "title" "$title"
    require_arg "description" "$description"
    bd create "$title" \
      --description "$description" \
      --type task \
      --priority "$priority" \
      --json
    ;;

  discovered)
    current_id="${1:-}"
    title="${2:-}"
    description="${3:-}"
    priority="${4:-2}"
    require_arg "current-id" "$current_id"
    require_arg "title" "$title"
    require_arg "description" "$description"
    bd create "$title" \
      --description "$description" \
      --type task \
      --priority "$priority" \
      --deps "discovered-from:$current_id" \
      --json
    ;;

  finish)
    bead_id="${1:-}"
    summary="${2:-}"
    require_arg "bead-id" "$bead_id"
    require_arg "verification summary" "$summary"
    bd close "$bead_id" --reason "$summary" --json
    echo
    echo "== ready work after close =="
    bd ready --json
    echo
    echo "== git status =="
    git status --short
    ;;

  no-bead)
    reason="${1:-}"
    require_arg "reason" "$reason"
    cat <<EOF
No bead: $reason

Use this only for tiny direct answers or read-only checks. Non-trivial code/docs
work must use claim/create before edits.
EOF
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    echo "Unknown command: $command_name" >&2
    usage >&2
    exit 2
    ;;
esac
