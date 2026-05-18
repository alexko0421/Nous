#!/usr/bin/env bash
# Summarizes the local human-judgment handoff A/B dogfood JSONL log.
# Usage:
#   scripts/handoff_ab_summary.sh --days 30
#   NOUS_HANDOFF_AB_LOG=/tmp/log.jsonl scripts/handoff_ab_summary.sh --days 7

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
INPUT="${NOUS_HANDOFF_AB_LOG:-$HOME/Library/Application Support/Nous/quick-action-experiment-dogfood.jsonl}"

cd "$ROOT_DIR"

echo "Building BehaviorEvalRunner..."
xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -quiet build

DERIVED="$(xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -showBuildSettings -quiet \
  | grep -E "^[[:space:]]*BUILT_PRODUCTS_DIR" | sed -E 's/.*= //')"

"$DERIVED/BehaviorEvalRunner" handoff-ab-summary --input "$INPUT" "$@"
