#!/usr/bin/env bash
# Runtime smoke for the Nous main window.
# Verifies the real CoreGraphics window surface instead of AppleScript's
# accessibility window count, which can miss the borderless custom window.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
PROFILE="${NOUS_SMOKE_PROFILE:-codex-smoke-window-$(date +%s)}"
TIMEOUT_SECONDS="${NOUS_SMOKE_TIMEOUT_SECONDS:-12}"
MIN_MAIN_WINDOW_WIDTH="${NOUS_SMOKE_MIN_WINDOW_WIDTH:-700}"
MIN_MAIN_WINDOW_HEIGHT="${NOUS_SMOKE_MIN_WINDOW_HEIGHT:-500}"

cd "$ROOT_DIR"

stop_running_nous() {
  local pids parent_pid parent_comm
  pids="$(pgrep -x Nous || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

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
}

cleanup() {
  launchctl unsetenv NOUS_DATABASE_PROFILE >/dev/null 2>&1 || true
  stop_running_nous
}

trap cleanup EXIT

app_path() {
  xcodebuild \
    -project Nous.xcodeproj \
    -scheme Nous \
    -destination "$DESTINATION" \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '
      / TARGET_BUILD_DIR = / { targetBuildDir = $2 }
      / FULL_PRODUCT_NAME = / { productName = $2 }
      END {
        if (targetBuildDir != "" && productName != "") {
          print targetBuildDir "/" productName
        }
      }
    '
}

main_window_count_for_pid() {
  local pid="$1"
  PID="$pid" \
  MIN_MAIN_WINDOW_WIDTH="$MIN_MAIN_WINDOW_WIDTH" \
  MIN_MAIN_WINDOW_HEIGHT="$MIN_MAIN_WINDOW_HEIGHT" \
    swift -e '
      import CoreGraphics
      import Foundation

      let env = ProcessInfo.processInfo.environment
      let pid = Int32(env["PID"]!)!
      let minWidth = Double(env["MIN_MAIN_WINDOW_WIDTH"]!)!
      let minHeight = Double(env["MIN_MAIN_WINDOW_HEIGHT"]!)!
      let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
      let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      let count = windows.filter { window in
          guard (window[kCGWindowOwnerPID as String] as? Int32) == pid else { return false }
          guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return false }
          guard let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
          return width >= minWidth && height >= minHeight
      }.count
      print(count)
    '
}

wait_for_main_window() {
  local label="$1"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local pid count

  while (( SECONDS < deadline )); do
    pid="$(pgrep -x Nous | head -n 1 || true)"
    if [[ -n "$pid" ]]; then
      count="$(main_window_count_for_pid "$pid")"
      echo "$label: pid=$pid cg_main_windows=$count"
      if [[ "$count" -ge 1 ]]; then
        return 0
      fi
    else
      echo "$label: Nous process not found yet"
    fi
    sleep 1
  done

  echo "$label: no onscreen Nous main window found via CGWindowList within ${TIMEOUT_SECONDS}s" >&2
  return 1
}

echo "Stopping old Nous processes..."
stop_running_nous

echo "Building normal Nous app..."
xcodebuild \
  -project Nous.xcodeproj \
  -scheme Nous \
  -destination "$DESTINATION" \
  build \
  -quiet

APP_PATH="$(app_path)"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app was not found: $APP_PATH" >&2
  exit 1
fi

echo "Launching Nous with isolated profile: $PROFILE"
launchctl setenv NOUS_DATABASE_PROFILE "$PROFILE"
open -n "$APP_PATH"
launchctl unsetenv NOUS_DATABASE_PROFILE

wait_for_main_window "launch"

echo "Checking reopen recovery..."
osascript -e 'tell application "Nous" to close every window' >/dev/null 2>&1 || true
sleep 1
open "$APP_PATH"
wait_for_main_window "reopen"

echo "Nous main window smoke passed."
