#!/usr/bin/env bash
# Records a local-model behavior eval run against the existing deterministic trust suite.
# Usage:
#   scripts/run_local_model_behavior_eval.sh --model llama-3.2-3b-4bit --mode quick --live never

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

"$DERIVED/BehaviorEvalRunner" local-eval "$@"
