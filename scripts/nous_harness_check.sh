#!/usr/bin/env bash
# Unified Harness OS gate for Nous.
# Usage:
#   scripts/nous_harness_check.sh quick
#   scripts/nous_harness_check.sh full

set -eo pipefail

MODE="${1:-quick}"
if [[ "$MODE" != "quick" && "$MODE" != "full" ]]; then
  echo "usage: scripts/nous_harness_check.sh [quick|full]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${XCODE_DESTINATION:-platform=macOS}"
DEFAULT_BEHAVIOR_EVAL_LIVE_MODE="never"
BEHAVIOR_EVAL_LIVE_MODE="${NOUS_BEHAVIOR_EVAL_LIVE_MODE:-$DEFAULT_BEHAVIOR_EVAL_LIVE_MODE}"
RESULTS_DIR="$ROOT_DIR/results/harness"
RESULTS_LOG="$RESULTS_DIR/runs.jsonl"
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
STATUS="passed"
FINDINGS=()
DETAILS=()

if [[ "$BEHAVIOR_EVAL_LIVE_MODE" != "never" && "$BEHAVIOR_EVAL_LIVE_MODE" != "auto" && "$BEHAVIOR_EVAL_LIVE_MODE" != "required" ]]; then
  echo "NOUS_BEHAVIOR_EVAL_LIVE_MODE must be never, auto, or required." >&2
  exit 2
fi

cd "$ROOT_DIR"

add_detail() {
  DETAILS+=("$1")
}

add_finding() {
  local finding="$1"
  case " ${FINDINGS[*]} " in
    *" $finding "*) ;;
    *) FINDINGS+=("$finding") ;;
  esac
}

mark_failed() {
  STATUS="failed"
  add_detail "$1"
}

json_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

json_findings() {
  local first=1
  printf '['
  for finding in "${FINDINGS[@]}"; do
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    first=0
    printf '"%s"' "$(json_escape "$finding")"
  done
  printf ']'
}

joined_details() {
  local IFS=' '
  printf '%s' "${DETAILS[*]}"
}

write_result() {
  mkdir -p "$RESULTS_DIR"
  local ended_at detail signature
  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  detail="$(joined_details)"
  signature="$(change_signature)"
  printf '{"id":"%s","mode":"%s","status":"%s","startedAt":"%s","endedAt":"%s","findings":%s,"detail":"%s","changeSignature":"%s"}\n' \
    "$RUN_ID" \
    "$MODE" \
    "$STATUS" \
    "$STARTED_AT" \
    "$ended_at" \
    "$(json_findings)" \
    "$(json_escape "$detail")" \
    "$(json_escape "$signature")" >> "$RESULTS_LOG"
}

run_step() {
  local label="$1"
  shift
  echo
  echo "==> $label"
  if "$@"; then
    add_detail "$label passed."
  else
    mark_failed "$label failed."
  fi
}

changed_paths() {
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | sed '/^[[:space:]]*$/d' | sort -u
}

change_signature() {
  if ! command -v shasum >/dev/null 2>&1; then
    printf ''
    return
  fi

  {
    git diff --binary --no-ext-diff
    printf '\n--STAGED--\n'
    git diff --cached --binary --no-ext-diff
    printf '\n--UNTRACKED--\n'
    git ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r path; do
      printf 'untracked:%s\n' "$path"
      if [[ -f "$path" ]]; then
        shasum -a 256 "$path"
      fi
    done
    printf '\n--ROOT-SWIFT--\n'
    find Sources/Nous -maxdepth 1 -name "*.swift" -type f -print | LC_ALL=C sort | while IFS= read -r path; do
      printf 'root-swift:%s\n' "$path"
      shasum -a 256 "$path"
    done
  } | shasum -a 256 | awk '{print $1}'
}

needs_xcodegen() {
  local path
  while IFS= read -r path; do
    case "$path" in
      project.yml|Tests/NousTests/Fixtures/*|Sources/*.swift|Sources/*/*.swift|Sources/*/*/*.swift|Sources/*/*/*/*.swift|Tests/*.swift|Tests/*/*.swift|Tests/*/*/*.swift|Tests/*/*/*/*.swift)
        return 0
        ;;
    esac
  done < <(changed_paths)
  return 1
}

classify_changed_paths() {
  local path
  while IFS= read -r path; do
    case "$path" in
      Sources/Nous/Resources/anchor.md)
        add_finding "protected_anchor_changed"
        mark_failed "Protected anchor.md changed."
        ;;
      *PromptContextAssembler*|*PromptGovernanceTrace*|*TurnPlanner*|*TurnSteward*|*ChatTurnRunner*|*CognitionArtifactAdapters*)
        add_finding "prompt_surface_changed"
        ;;
      *LLMService*|*LocalLLMService*|*Gemini*|*Claude*|*OpenAI*|*OpenRouter*)
        add_finding "model_surface_changed"
        ;;
      *Memory*|*VectorStore*|*Embedding*|*NodeStore*|*Reflection*|*ShadowLearning*|*UserModel*|*Contradiction*)
        add_finding "memory_surface_changed"
        ;;
      project.yml|Nous.xcodeproj/*)
        add_finding "project_config_changed"
        ;;
      *FixtureRunner*|*Sycophancy*|*BehaviorDataset*|*BehaviorExperiment*|*BehaviorEval*|*BehaviorFineTune*|*BehaviorLocalModel*|Tests/NousTests/PromptGovernance*|Tests/NousTests/RuntimeQuality*)
        add_finding "fixture_surface_changed"
        ;;
      Sources/*.swift|Sources/*/*.swift|Sources/*/*/*.swift|Sources/*/*/*/*.swift|Tests/*.swift|Tests/*/*.swift|Tests/*/*/*.swift|Tests/*/*/*/*.swift)
        add_finding "source_set_changed"
        ;;
    esac
  done < <(changed_paths)
}

check_root_swift_orphans() {
  local root_swift
  root_swift="$(find Sources/Nous -maxdepth 1 -name "*.swift" -type f -print)"
  if [[ -n "$root_swift" ]]; then
    add_finding "root_swift_orphan"
    mark_failed "Swift files found directly under Sources/Nous."
    printf '%s\n' "$root_swift" >&2
  fi
}

check_beads() {
  if ! command -v bd >/dev/null 2>&1; then
    mark_failed "bd is unavailable; run scripts/setup_beads_agent_memory.sh --install."
    return
  fi

  run_step "Beads ready list" bd ready --json >/dev/null
  run_step "Beads in-progress list" bd list --status=in_progress --json >/dev/null
}

run_targeted_tests() {
  run_step "Targeted harness tests" ./scripts/test_nous.sh \
    -only-testing:NousTests/HarnessHealthTests \
    -only-testing:NousTests/BehaviorEvalTests \
    -only-testing:NousTests/CognitionContractsTests \
    -only-testing:NousTests/CognitionDirectorTests \
    -only-testing:NousTests/ContextManifestFactoryTests \
    -only-testing:NousTests/MemoryCuratorTests \
    -only-testing:NousTests/ReflectionValidatorTests \
    -only-testing:NousTests/WeeklyReflectionServiceTests \
    -only-testing:NousTests/ReflectionCascadeOrphanTests \
    -only-testing:NousTests/PromptContextAssemblerShadowLearningTests \
    -only-testing:NousTests/PromptContextAssemblerSlowCognitionTests \
    -only-testing:NousTests/PromptContextAssemblerTeachingExplanationTests \
    -only-testing:NousTests/PromptContextAssemblerSoftHardCalibrationTests \
    -only-testing:NousTests/RuntimeQualityReviewerTests \
    -only-testing:NousTests/PromptGovernanceTraceTests \
    -only-testing:NousTests/SourceURLDetectorTests \
    -only-testing:NousTests/SourceFetchServiceTests \
    -only-testing:NousTests/SourceIngestionServiceTests \
    -only-testing:NousTests/TemporaryBranchViewModelTests \
    -only-testing:NousTests/TurnMemoryContextBuilderTests \
    -only-testing:NousTests/TurnCognitionInspectorFeedTests \
    -only-testing:NousTests/SafetyGuardrailsTests
}

run_behavior_evals() {
  local mode="$1"
  local live="$2"
  ./scripts/run_behavior_evals.sh \
    --mode "$mode" \
    --live "$live" \
    --change-signature "$(change_signature)"
}

run_full_checks() {
  if needs_xcodegen; then
    if command -v xcodegen >/dev/null 2>&1; then
      run_step "xcodegen generate" xcodegen generate
    else
      mark_failed "Project membership changed but xcodegen is unavailable."
    fi
  fi

  run_step "Nous build" xcodebuild \
    -project Nous.xcodeproj \
    -scheme Nous \
    -destination "$DESTINATION" \
    build

  run_step "Nous main window runtime smoke" ./scripts/smoke_nous_window.sh

  run_step "Full Nous tests" ./scripts/test_nous.sh

  run_step "Behavior eval full" run_behavior_evals full "$BEHAVIOR_EVAL_LIVE_MODE"

  if [[ -x "./scripts/run_provocation_fixtures.sh" ]]; then
    run_step "Provocation fixture dry-run" ./scripts/run_provocation_fixtures.sh --dry-run
  fi

  if [[ -x "./scripts/run_sycophancy_fixtures.sh" ]]; then
    run_step "Sycophancy fixture dry-run" ./scripts/run_sycophancy_fixtures.sh --dry-run --no-persist
    run_step "Sycophancy fixtures" ./scripts/run_sycophancy_fixtures.sh
    if [[ -z "${OPENROUTER_API_KEY:-}" && -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" && -z "${GEMINI_API_KEY:-}" ]]; then
      add_detail "LLM fixture calls skipped because no API key was present."
    else
      add_detail "V1 sycophancy runner used deterministic local scoring; cloud judge wiring remains behind this stable entry point."
    fi
  else
    add_detail "Sycophancy fixture runner is not present yet; skipped."
  fi
}

echo "Nous Harness OS: $MODE"

classify_changed_paths
check_root_swift_orphans
check_beads

if [[ "$STATUS" == "failed" ]]; then
  write_result
  echo
  echo "Harness $MODE failed before test execution."
  exit 1
fi

if [[ "$MODE" == "quick" ]]; then
  if printf '%s\n' "${FINDINGS[@]}" | grep -Eq '^(prompt_surface_changed|model_surface_changed|memory_surface_changed|project_config_changed|source_set_changed|fixture_surface_changed)$'; then
    add_detail "Risky prompt/model/memory/config/eval surface changed; full gate required before close."
  fi
  run_targeted_tests
  run_step "Behavior eval quick" run_behavior_evals quick never
else
  run_full_checks
fi

write_result

if [[ "$STATUS" == "passed" ]]; then
  echo
  echo "Harness $MODE passed."
  exit 0
fi

echo
echo "Harness $MODE failed."
exit 1
