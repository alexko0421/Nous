#!/usr/bin/env bash
# Runs the Nous behavior eval suite.
# Usage:
#   scripts/run_behavior_evals.sh --mode quick --live never
#   scripts/run_behavior_evals.sh --mode full --live never

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

"$DERIVED/BehaviorEvalRunner" "$@"
