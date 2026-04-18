#!/usr/bin/env bash
# Runs the provocation fixture bank against the real judge via a dedicated
# ad-hoc Swift entry point. Usage:
#   ANTHROPIC_API_KEY=... ./scripts/run_provocation_fixtures.sh
#
# Requires the app to have been built at least once so dependencies resolve.

set -euo pipefail
FIXTURES_DIR="$(dirname "$0")/../Tests/NousTests/Fixtures/ProvocationScenarios"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Set ANTHROPIC_API_KEY before running." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# Runs ProvocationFixtureRunner, a small executable target added alongside the main target.
# It iterates the directory, runs each fixture through ProvocationJudge, and prints diff rows.
xcodebuild -project Nous.xcodeproj -scheme ProvocationFixtureRunner \
  -destination 'platform=macOS' -quiet build

DERIVED=$(xcodebuild -project Nous.xcodeproj -scheme ProvocationFixtureRunner \
  -destination 'platform=macOS' -showBuildSettings -quiet \
  | grep -E "^[[:space:]]*BUILT_PRODUCTS_DIR" | sed -E 's/.*= //')

"$DERIVED/ProvocationFixtureRunner" "$FIXTURES_DIR"
