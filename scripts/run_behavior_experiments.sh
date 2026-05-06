#!/usr/bin/env bash
# Runs a named behavior experiment against the latest trusted baseline.
# Usage:
#   scripts/run_behavior_experiments.sh --id prompt-tightening-v1 --mode quick --live never

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"

cd "$ROOT_DIR"

echo "Building BehaviorEvalRunner..."
xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -quiet build

DERIVED="$(xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -showBuildSettings -quiet \
  | grep -E "^[[:space:]]*BUILT_PRODUCTS_DIR" | sed -E 's/.*= //')"

"$DERIVED/BehaviorEvalRunner" experiment "$@"
