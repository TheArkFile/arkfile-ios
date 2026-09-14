#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTABLE_VERIFIER="$ROOT_DIR/scripts/arkfile-verify-corekiwix-relink.mjs"
EVIDENCE_DIR="${ARKFILE_COREKIWIX_EVIDENCE_DIR:-$ROOT_DIR/Dependencies}"
FRAMEWORK=""
SOURCE_ARCHIVE="${ARKFILE_COREKIWIX_SOURCE_ARCHIVE_PATH:-}"
SOURCE_ARCHIVE_SHA256="${ARKFILE_COREKIWIX_SOURCE_ARCHIVE_SHA256:-}"
EXCEPTIONS_PATH="${ARKFILE_COREKIWIX_EXCEPTIONS_PATH:-$ROOT_DIR/Dependencies/CoreKiwixNativeExceptions.json}"
RECIPE_LOCK_PATH="${ARKFILE_COREKIWIX_RECIPE_LOCK_PATH:-}"
NOTICES_PATH="${ARKFILE_COREKIWIX_NOTICES_PATH:-}"
SECRET_SCAN_POLICY_PATH="${ARKFILE_COREKIWIX_SECRET_SCAN_POLICY_PATH:-}"
MODULEMAP_PATH="${ARKFILE_COREKIWIX_MODULEMAP_PATH:-$ROOT_DIR/Support/CoreKiwix.modulemap}"
GITLEAKS_PATH="${ARKFILE_GITLEAKS_PATH:-}"
TRUFFLEHOG_PATH="${ARKFILE_TRUFFLEHOG_PATH:-}"

readonly CONTROLLED_BUILD_IDENTITY="14.2.0+arkfile.1"
readonly OLD_IOS_DEVICE_SHA256="54c061cc77a5c293e249356b0b99f45bc60931fad97f90d9b2c0a39489746a49"
readonly OLD_IOS_SIMULATOR_SHA256="6a7b90da01771039fc30e3ba01099bf4d4d689c050b1c69c9251eda56824a414"
readonly OLD_MACOS_SHA256="66324fa8a07e65cbbf2bd033f638c4b9002f6c89f5c4954b220e6ed20a00162f"

usage() {
  cat <<'USAGE'
Usage:
  scripts/arkfile-verify-corekiwix.sh \
    --framework <CoreKiwix.xcframework> \
    --source-archive <CoreKiwix-source-and-relink.tar.gz> \
    --source-archive-sha256 <lowercase SHA-256> \
    [--evidence-dir <directory>] [--exceptions <policy.json>] \
    [--recipe-lock <lock.json>] [--notices <directory>] \
    [--secret-scan-policy <policy.json>] [--modulemap <CoreKiwix.modulemap>] \
    [--gitleaks <executable>] \
    [--trufflehog <executable>]

The source archive must be the deterministic 14.2.0+arkfile.1 corresponding-
source package. The verifier pins its exact SHA-256, validates every checked
input and deterministic package member, recomputes normalized public evidence,
matches the exact reviewed Gitleaks/TruffleHog finding baseline, and actually
relinks all five thin targets. It does not require private BUILD_* trees, raw
logs, a recipe checkout, or a private build-tool input directory.
Pre-normalization source file digests remain bound by the pinned archive but
cannot be independently recomputed without private build-work.

Environment alternatives:
  ARKFILE_COREKIWIX_SOURCE_ARCHIVE_PATH
  ARKFILE_COREKIWIX_SOURCE_ARCHIVE_SHA256
  ARKFILE_COREKIWIX_EVIDENCE_DIR
  ARKFILE_COREKIWIX_EXCEPTIONS_PATH
  ARKFILE_COREKIWIX_RECIPE_LOCK_PATH
  ARKFILE_COREKIWIX_NOTICES_PATH
  ARKFILE_COREKIWIX_SECRET_SCAN_POLICY_PATH
  ARKFILE_COREKIWIX_MODULEMAP_PATH
  ARKFILE_GITLEAKS_PATH
  ARKFILE_TRUFFLEHOG_PATH
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_regular_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a regular, non-symlink file: $path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework)
      FRAMEWORK="${2:-}"
      shift 2
      ;;
    --source-archive)
      SOURCE_ARCHIVE="${2:-}"
      shift 2
      ;;
    --source-archive-sha256)
      SOURCE_ARCHIVE_SHA256="${2:-}"
      shift 2
      ;;
    --evidence-dir)
      EVIDENCE_DIR="${2:-}"
      shift 2
      ;;
    --exceptions)
      EXCEPTIONS_PATH="${2:-}"
      shift 2
      ;;
    --recipe-lock)
      RECIPE_LOCK_PATH="${2:-}"
      shift 2
      ;;
    --notices)
      NOTICES_PATH="${2:-}"
      shift 2
      ;;
    --secret-scan-policy)
      SECRET_SCAN_POLICY_PATH="${2:-}"
      shift 2
      ;;
    --modulemap)
      MODULEMAP_PATH="${2:-}"
      shift 2
      ;;
    --gitleaks)
      GITLEAKS_PATH="${2:-}"
      shift 2
      ;;
    --trufflehog)
      TRUFFLEHOG_PATH="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$FRAMEWORK" && -d "$FRAMEWORK" && ! -L "$FRAMEWORK" ]] \
  || fail "CoreKiwix XCFramework must be a real directory: ${FRAMEWORK:-'(not set)'}"
[[ -n "$SOURCE_ARCHIVE" ]] || fail "Set the exact controlled CoreKiwix source/relink archive path."
[[ "$SOURCE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || fail "Controlled CoreKiwix source archive SHA-256 must be a lowercase 64-character digest."
if [[ -z "$RECIPE_LOCK_PATH" ]]; then
  RECIPE_LOCK_PATH="$EVIDENCE_DIR/CoreKiwixNativeBuildRecipe.lock.json"
fi
if [[ -z "$NOTICES_PATH" ]]; then
  NOTICES_PATH="$EVIDENCE_DIR/CoreKiwixNativeNotices"
fi
if [[ -z "$SECRET_SCAN_POLICY_PATH" ]]; then
  SECRET_SCAN_POLICY_PATH="$EVIDENCE_DIR/CoreKiwixNativeSecretScanPolicy.json"
fi
if [[ -z "$GITLEAKS_PATH" ]]; then
  GITLEAKS_PATH="$(command -v gitleaks || true)"
fi
if [[ -z "$TRUFFLEHOG_PATH" ]]; then
  TRUFFLEHOG_PATH="$(command -v trufflehog || true)"
fi

require_regular_file "$SOURCE_ARCHIVE" "Controlled CoreKiwix source/relink archive"
require_regular_file "$PORTABLE_VERIFIER" "CoreKiwix portable source-package verifier"
for evidence_file in \
  CoreKiwixNativeBuildManifest.json \
  CoreKiwixNativeSource.lock.json \
  CoreKiwixNativeSBOM.spdx.json \
  CoreKiwixNativeObjectMap.jsonl; do
  require_regular_file "$EVIDENCE_DIR/$evidence_file" "CoreKiwix evidence file"
done
require_regular_file "$EXCEPTIONS_PATH" "CoreKiwix exception policy"
require_regular_file "$RECIPE_LOCK_PATH" "CoreKiwix build recipe lock"
require_regular_file "$SECRET_SCAN_POLICY_PATH" "CoreKiwix native secret-scan policy"
require_regular_file "$MODULEMAP_PATH" "Reviewed CoreKiwix module map"
[[ -n "$GITLEAKS_PATH" ]] \
  || fail "Missing required Gitleaks 8.30.1. Run scripts/arkfile-install-secret-scanners.sh or set ARKFILE_GITLEAKS_PATH."
[[ -n "$TRUFFLEHOG_PATH" ]] \
  || fail "Missing required TruffleHog 3.95.9. Run scripts/arkfile-install-secret-scanners.sh or set ARKFILE_TRUFFLEHOG_PATH."
require_regular_file "$GITLEAKS_PATH" "Gitleaks executable"
require_regular_file "$TRUFFLEHOG_PATH" "TruffleHog executable"
[[ -d "$NOTICES_PATH" && ! -L "$NOTICES_PATH" ]] \
  || fail "CoreKiwix notice directory must be a real directory: $NOTICES_PATH"

actual_source_sha256="$(sha256_file "$SOURCE_ARCHIVE")"
[[ "$actual_source_sha256" == "$SOURCE_ARCHIVE_SHA256" ]] \
  || fail "Controlled CoreKiwix source archive SHA-256 mismatch."

for slice_and_stale_hash in \
  "ios-arm64:$OLD_IOS_DEVICE_SHA256" \
  "ios-arm64_x86_64-simulator:$OLD_IOS_SIMULATOR_SHA256" \
  "macos-arm64_x86_64:$OLD_MACOS_SHA256"; do
  slice="${slice_and_stale_hash%%:*}"
  stale_hash="${slice_and_stale_hash#*:}"
  binary="$FRAMEWORK/$slice/merged.a"
  require_regular_file "$binary" "CoreKiwix $slice merged archive"
  [[ "$(sha256_file "$binary")" != "$stale_hash" ]] \
    || fail "Refusing the superseded unbound CoreKiwix 14.2.0-1 $slice binary."
  slice_modulemap="$FRAMEWORK/$slice/Headers/module.modulemap"
  require_regular_file "$slice_modulemap" "CoreKiwix $slice module map"
  cmp -s "$MODULEMAP_PATH" "$slice_modulemap" \
    || fail "CoreKiwix $slice module map differs from the reviewed app module map."
done

portable_args=(
  portable
  --archive "$SOURCE_ARCHIVE"
  --framework "$FRAMEWORK"
  --recipe-lock "$RECIPE_LOCK_PATH"
  --exceptions "$EXCEPTIONS_PATH"
  --notices "$NOTICES_PATH"
  --evidence "$EVIDENCE_DIR"
  --secret-scan-policy "$SECRET_SCAN_POLICY_PATH"
  --gitleaks "$GITLEAKS_PATH"
  --trufflehog "$TRUFFLEHOG_PATH"
)
node "$PORTABLE_VERIFIER" "${portable_args[@]}"

build_manifest="$EVIDENCE_DIR/CoreKiwixNativeBuildManifest.json"
[[ "$(/usr/bin/plutil -extract format raw -o - "$build_manifest")" == "1" ]] \
  || fail "CoreKiwix native build manifest format is unsupported."
[[ "$(/usr/bin/plutil -extract policy raw -o - "$build_manifest")" == "arkfile-corekiwix-native-evidence-v1" ]] \
  || fail "CoreKiwix native build manifest policy is unsupported."
[[ "$(/usr/bin/plutil -extract product.buildIdentity raw -o - "$build_manifest")" == "$CONTROLLED_BUILD_IDENTITY" ]] \
  || fail "CoreKiwix native build identity is not $CONTROLLED_BUILD_IDENTITY."
[[ "$(/usr/bin/plutil -extract distributedIOSCoverage.exactArchiveIdentity raw -o - "$build_manifest")" == "true" \
    && "$(/usr/bin/plutil -extract distributedIOSCoverage.fullObjectCoverage raw -o - "$build_manifest")" == "true" \
    && "$(/usr/bin/plutil -extract distributedIOSCoverage.fullArchiveMemberCoverage raw -o - "$build_manifest")" == "true" ]] \
  || fail "CoreKiwix native object inventory does not cover the complete distributed iOS archive."

echo "Controlled CoreKiwix $CONTROLLED_BUILD_IDENTITY evidence and source archive verified."
