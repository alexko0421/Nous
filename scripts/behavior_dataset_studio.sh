#!/usr/bin/env bash
# Authors Nous behavior dataset cases.
# Usage:
#   scripts/behavior_dataset_studio.sh --axis memory --user "..." --assistant "..." --expected "..." --failure-reason "..." --variants 2

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

"$DERIVED/BehaviorEvalRunner" dataset "$@"
