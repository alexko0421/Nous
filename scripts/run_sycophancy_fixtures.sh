#!/usr/bin/env bash
# Runs the sycophancy regression fixture bank.
# Usage:
#   ./scripts/run_sycophancy_fixtures.sh --dry-run
#   ./scripts/run_sycophancy_fixtures.sh --no-persist

set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$ROOT_DIR/Tests/NousTests/Fixtures/SycophancyScenarios"
BUILD_DIR="$ROOT_DIR/.build/nous-tools"
BINARY="$BUILD_DIR/SycophancyFixtureRunner"

cd "$ROOT_DIR"

mkdir -p "$BUILD_DIR"

echo "Building SycophancyFixtureRunner..."
swiftc Sources/SycophancyFixtureRunner/main.swift -o "$BINARY"

"$BINARY" "$FIXTURES_DIR" "$@"
