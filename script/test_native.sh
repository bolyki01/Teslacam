#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

resolve_build_env() {
  if [[ -n "${TESLACAM_BUILD_ENV:-}" ]]; then
    if [[ -f "$TESLACAM_BUILD_ENV" ]]; then
      printf '%s\n' "$TESLACAM_BUILD_ENV"
      return 0
    fi
    echo "TESLACAM_BUILD_ENV is set but does not exist: $TESLACAM_BUILD_ENV" >&2
    return 1
  fi

  local default_env="/Users/bolyki/dev/source/build-env.sh"
  if [[ -f "$default_env" ]]; then
    printf '%s\n' "$default_env"
    return 0
  fi

  cat >&2 <<'EOM'
Missing build environment script.
Set TESLACAM_BUILD_ENV to a valid build-env.sh, or create /Users/bolyki/dev/source/build-env.sh.
EOM
  return 1
}

BUILD_ENV_SCRIPT="$(resolve_build_env)"
# shellcheck disable=SC1090
source "$BUILD_ENV_SCRIPT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild was not found. Run this script on macOS with Xcode command line tools installed." >&2
  exit 1
fi

DERIVED_DATA="${TESLACAM_DERIVED_DATA:-${XCODE_DERIVED_DATA_PATH:-/Users/bolyki/dev/library/derived-data}/Teslacam-tests}"

xcodebuild \
  -project TeslaCam.xcodeproj \
  -scheme TeslaCam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  build-for-testing

xcodebuild \
  -project TeslaCam.xcodeproj \
  -scheme TeslaCam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:TeslaCamTests \
  test-without-building

xcodebuild \
  -project TeslaCam.xcodeproj \
  -scheme TeslaCam \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:TeslaCamUITests \
  test-without-building
