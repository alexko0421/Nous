#!/usr/bin/env bash
# Stable test entry point for the Nous macOS app.
# Usage:
#   ./scripts/test_nous.sh
#   ./scripts/test_nous.sh -only-testing:NousTests/VectorStoreTests

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"

cd "$ROOT_DIR"

BUILD_ARGS=()
TEST_ARGS=()
for arg in "$@"; do
  case "$arg" in
    -only-testing:*|-skip-testing:*)
      TEST_ARGS+=("$arg")
      ;;
    *)
      BUILD_ARGS+=("$arg")
      TEST_ARGS+=("$arg")
      ;;
  esac
done

stop_running_nous() {
  local pids parent_pid parent_comm
  pids="$(pgrep -x Nous || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "Stopping running Nous.app before rebuilding test artifacts..."
  pkill -TERM -x Nous || true
  sleep 1

  pids="$(pgrep -x Nous || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    parent_pid="$(ps -o ppid= -p "$pid" | tr -d '[:space:]')"
    parent_comm="$(ps -o comm= -p "$parent_pid" 2>/dev/null || true)"
    if [[ "$parent_comm" == *debugserver* ]]; then
      kill -9 "$parent_pid" 2>/dev/null || true
    fi
    kill -9 "$pid" 2>/dev/null || true
  done <<< "$pids"

  sleep 1
  if pgrep -x Nous >/dev/null; then
    echo "Nous.app is still running; quit it before tests so Xcode can rebuild cleanly." >&2
    exit 1
  fi
}

trap stop_running_nous EXIT
stop_running_nous

echo "Building test artifacts..."
build_command=(
  xcodebuild build-for-testing
  -project Nous.xcodeproj
  -scheme NousTests
  -destination "$DESTINATION"
  CODE_SIGNING_ALLOWED=NO
)
if ((${#BUILD_ARGS[@]} > 0)); then
  build_command+=("${BUILD_ARGS[@]}")
fi
"${build_command[@]}"

echo
echo "Running tests..."
test_command=(
  xcodebuild test-without-building
  -project Nous.xcodeproj
  -scheme NousTests
  -destination "$DESTINATION"
  CODE_SIGNING_ALLOWED=NO
)
if ((${#TEST_ARGS[@]} > 0)); then
  test_command+=("${TEST_ARGS[@]}")
fi
"${test_command[@]}"
