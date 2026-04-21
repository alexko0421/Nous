#!/usr/bin/env bash
# Stable test entry point for the Nous macOS app.
# Usage:
#   ./scripts/test_nous.sh
#   ./scripts/test_nous.sh -only-testing:NousTests/VectorStoreTests

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"

cd "$ROOT_DIR"

echo "Building test artifacts..."
xcodebuild build-for-testing \
  -project Nous.xcodeproj \
  -scheme NousTests \
  -destination "$DESTINATION" \
  "$@"

echo
echo "Running tests..."
xcodebuild test-without-building \
  -project Nous.xcodeproj \
  -scheme NousTests \
  -destination "$DESTINATION" \
  "$@"
