#!/usr/bin/env bash
# Summarizes the local Skill Fold dogfood JSONL log.
# Usage:
#   scripts/skill_dogfood_summary.sh --days 30
#   NOUS_SKILL_DOGFOOD_LOG=/tmp/log.jsonl scripts/skill_dogfood_summary.sh --days 7

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
INPUT="${NOUS_SKILL_DOGFOOD_LOG:-$HOME/Library/Application Support/Nous/skill-fold-dogfood.jsonl}"

cd "$ROOT_DIR"

echo "Building BehaviorEvalRunner..."
xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -quiet build

DERIVED="$(xcodebuild -project Nous.xcodeproj -scheme BehaviorEvalRunner \
  -destination "$DESTINATION" -showBuildSettings -quiet \
  | grep -E "^[[:space:]]*BUILT_PRODUCTS_DIR" | sed -E 's/.*= //')"

"$DERIVED/BehaviorEvalRunner" dogfood-summary --input "$INPUT" "$@"
