#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEGEN_VERSION="2.45.4"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
XCODEGEN_CHECKSUM_FILE="$ROOT_DIR/Dependencies/XcodeGen-2.45.4.sha256"
XCODEGEN_ARCHIVE=""
COREKIWIX_SOURCE_ARCHIVE="${ARKFILE_COREKIWIX_SOURCE_ARCHIVE_PATH:-}"
COREKIWIX_SOURCE_ARCHIVE_SHA256="${ARKFILE_COREKIWIX_SOURCE_ARCHIVE_SHA256:-}"
COREKIWIX_SOURCE_ARCHIVE_URL="${ARKFILE_COREKIWIX_SOURCE_ARCHIVE_URL:-}"
DESTINATION="generic/platform=iOS Simulator"
PREPARE_ONLY=0
TEMP_DIR=""
SOURCE_STATE_BEFORE=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/arkfile-public-build.sh [--xcodegen-archive PATH]
      [--corekiwix-source-archive PATH] [--corekiwix-source-archive-sha256 SHA256]
      [--destination DESTINATION] [--prepare-only]

Performs the public, unsigned ArkFile iOS build from the sanitized source tree.
It uses only XcodeGen 2.45.4, controlled CoreKiwix 14.2.0+arkfile.1, its complete
source/relink archive and generated evidence, and the checked-in SwiftPM lock.
For a distribution source tree, the exact archive hash and published URL are
read from SOURCE_RELEASE_MANIFEST.json. A review tree without that binding must supply
the source/relink archive and its SHA-256 explicitly; there are no fallback URLs.
The source/relink archive also contains the exact CoreKiwix XCFramework used by
the build, so no separate framework download is required.

--prepare-only verifies and installs build inputs, generates LocalString.swift
and Kiwix.xcodeproj, and restores the reviewed SwiftPM lock without resolving or
compiling packages.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcodegen-archive)
      XCODEGEN_ARCHIVE="${2:-}"
      shift 2
      ;;
    --corekiwix-source-archive)
      COREKIWIX_SOURCE_ARCHIVE="${2:-}"
      shift 2
      ;;
    --corekiwix-source-archive-sha256)
      COREKIWIX_SOURCE_ARCHIVE_SHA256="${2:-}"
      shift 2
      ;;
    --destination)
      DESTINATION="${2:-}"
      shift 2
      ;;
    --prepare-only)
      PREPARE_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

for tool in curl git node perl plutil python3 shasum tar unzip xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required public-build tool: $tool" >&2
    exit 1
  }
done

[[ -f "$ROOT_DIR/project.yml" ]] || {
  echo "Missing public XcodeGen project specification: $ROOT_DIR/project.yml" >&2
  exit 1
}
[[ -f "$ROOT_DIR/Dependencies/Package.resolved" ]] || {
  echo "Missing reviewed SwiftPM lock: $ROOT_DIR/Dependencies/Package.resolved" >&2
  exit 1
}
[[ -f "$XCODEGEN_CHECKSUM_FILE" ]] || {
  echo "Missing reviewed XcodeGen archive checksum: $XCODEGEN_CHECKSUM_FILE" >&2
  exit 1
}
XCODEGEN_ARCHIVE_SHA256="$(awk 'NR == 1 {print $1}' "$XCODEGEN_CHECKSUM_FILE")"
[[ "$XCODEGEN_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Reviewed XcodeGen archive checksum is malformed." >&2
  exit 1
}

manifest_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

SOURCE_RELEASE_MANIFEST="$ROOT_DIR/SOURCE_RELEASE_MANIFEST.json"
if [[ -f "$SOURCE_RELEASE_MANIFEST" ]]; then
  [[ "$(manifest_value "$SOURCE_RELEASE_MANIFEST" manifestFormat)" == "4" ]] || {
    echo "Public source manifest format is unsupported." >&2
    exit 1
  }
  node -e '
    const manifest = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const native = manifest.nativeCorrespondingSource;
    const reviewOnly = native?.mode === "review-only-unbound"
      && native?.distributionEligible === false
      && native?.completeControlledBuild === false
      && native?.reviewOnlyUnbound === true
      && native?.distributedIOSObjectInventoryComplete === false
      && native?.distributedIOSCandidateSourceCoverageComplete === false
      && native?.distributedIOSUniqueSourceAttributionComplete === false
      && native?.unattributedObjectCount === null
      && native?.ambiguousSourceAttributionCount === null;
    const distribution = native?.mode === "complete-controlled-build"
      && native?.distributionEligible === true
      && native?.completeControlledBuild === true
      && native?.reviewOnlyUnbound === false;
    if (!reviewOnly && !distribution) process.exit(1);
  ' "$SOURCE_RELEASE_MANIFEST" || {
    echo "Public source manifest does not record one exact review-only or complete-controlled native-source mode." >&2
    exit 1
  }
  if [[ "$(manifest_value "$SOURCE_RELEASE_MANIFEST" nativeCorrespondingSource.completeControlledBuild)" == "true" ]]; then
    node -e '
      const crypto = require("crypto");
      const fs = require("fs");
      const path = require("path");
      const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const native = manifest.nativeCorrespondingSource;
      const build = String(manifest.build ?? "");
      const policyRelativePath = "Dependencies/CoreKiwixNativeSecretScanPolicy.json";
      const policyPath = path.join(process.argv[2], policyRelativePath);
      let policySHA256 = null;
      try {
        const stat = fs.lstatSync(policyPath);
        if (stat.isFile() && !stat.isSymbolicLink()) {
          policySHA256 = crypto.createHash("sha256").update(fs.readFileSync(policyPath)).digest("hex");
        }
      } catch {}
      const valid = /^[1-9][0-9]*$/.test(build)
        && Number(build) >= 360
        && manifest.binaryReleaseIdentity?.boundToExportedBinary === true
        && manifest.binaryReleaseIdentity?.releaseIdentityFormat === 6
        && native?.mode === "complete-controlled-build"
        && native?.distributionEligible === true
        && native?.completeControlledBuild === true
        && native?.reviewOnlyUnbound === false
        && native?.distributedIOSObjectInventoryComplete === true
        && native?.distributedIOSCandidateSourceCoverageComplete === false
        && native?.distributedIOSUniqueSourceAttributionComplete === false
        && native?.unattributedObjectCount === 1
        && native?.ambiguousSourceAttributionCount === 14
        && native?.secretScanPolicy?.path === policyRelativePath
        && native?.secretScanPolicy?.sha256 === policySHA256;
      if (!valid) process.exit(1);
    ' "$SOURCE_RELEASE_MANIFEST" "$ROOT_DIR" || {
      echo "Distribution public builds require a binary-bound Build 360+ manifest with exact controlled native-source scope and attribution limits." >&2
      exit 1
    }
    manifest_source_sha256="$(manifest_value "$SOURCE_RELEASE_MANIFEST" nativeCorrespondingSource.sourceAndRelinkArchive.sha256)"
    manifest_source_url="$(manifest_value "$SOURCE_RELEASE_MANIFEST" nativeCorrespondingSource.sourceAndRelinkArchive.url)"
    [[ -z "$COREKIWIX_SOURCE_ARCHIVE_SHA256" || "$COREKIWIX_SOURCE_ARCHIVE_SHA256" == "$manifest_source_sha256" ]] || {
      echo "Explicit CoreKiwix source archive SHA-256 contradicts SOURCE_RELEASE_MANIFEST.json." >&2
      exit 1
    }
    [[ -z "$COREKIWIX_SOURCE_ARCHIVE_URL" || "$COREKIWIX_SOURCE_ARCHIVE_URL" == "$manifest_source_url" ]] || {
      echo "Configured CoreKiwix source URL contradicts SOURCE_RELEASE_MANIFEST.json." >&2
      exit 1
    }
    COREKIWIX_SOURCE_ARCHIVE_SHA256="$manifest_source_sha256"
    COREKIWIX_SOURCE_ARCHIVE_URL="$manifest_source_url"
  fi
fi

[[ "$COREKIWIX_SOURCE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "An exact controlled CoreKiwix source/relink archive SHA-256 is required." >&2
  exit 1
}
if grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*"?[A-Za-z0-9]' "$ROOT_DIR/project.yml"; then
  echo "Public project.yml still contains a signing team; use a sanitized public export." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arkfile-public-build.XXXXXX")"
SOURCE_STATE_BEFORE="$TEMP_DIR/source-before.sha256"

cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_hash() {
  local file="$1"
  local expected="$2"
  local label="$3"
  [[ -f "$file" ]] || {
    echo "Missing $label: $file" >&2
    exit 1
  }
  local actual
  actual="$(hash_file "$file")"
  [[ "$actual" == "$expected" ]] || {
    echo "$label SHA-256 mismatch." >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  }
}

download_public_artifact() {
  local url="$1"
  local destination="$2"
  local label="$3"
  echo "Downloading $label from its pinned public URL..."
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --output "$destination.download" "$url"
  mv "$destination.download" "$destination"
}

assert_safe_archive_paths() {
  local label="$1"
  shift
  local entries
  entries="$("$@")"
  if printf '%s\n' "$entries" | awk -F/ '
    /^\// { bad = 1 }
    /\\/ { bad = 1 }
    { for (part = 1; part <= NF; part += 1) if ($part == "..") bad = 1 }
    END { exit bad ? 0 : 1 }
  '; then
    echo "$label contains an unsafe path." >&2
    exit 1
  fi
}

extract_corekiwix_framework() {
  local archive="$1"
  local destination="$2"
  local framework_info_count
  framework_info_count="$(
    tar -tzf "$archive" \
      | awk '$0 ~ /(^|\/)CoreKiwix\.xcframework\/Info\.plist$/ { count += 1 } END { print count + 0 }'
  )"
  [[ "$framework_info_count" == "1" ]] || {
    echo "CoreKiwix source/relink archive must contain one literal framework/CoreKiwix.xcframework tree." >&2
    exit 1
  }
  tar -tzf "$archive" \
    | awk '$0 == "framework/CoreKiwix.xcframework/Info.plist" { found = 1 } END { exit found ? 0 : 1 }' || {
      echo "CoreKiwix source/relink archive is missing framework/CoreKiwix.xcframework/Info.plist." >&2
      exit 1
    }
  tar -xzf "$archive" -C "$destination" framework/CoreKiwix.xcframework
}

assert_tar_has_no_links() {
  local archive="$1"
  local label="$2"
  if tar -tvzf "$archive" \
    | awk '$1 ~ /^[lh]/ { unsafe = 1 } END { exit unsafe ? 0 : 1 }'; then
    echo "$label contains a symlink or hard link." >&2
    exit 1
  fi
}

snapshot_source() {
  local output="$1"
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
      echo "Refusing to build from a Git checkout with tracked changes." >&2
      exit 1
    fi
    local unexpected_untracked
    unexpected_untracked="$(
      git -C "$ROOT_DIR" status --porcelain --untracked-files=all \
        | sed -n 's/^?? //p' \
        | grep -Ev '^(CoreKiwix\.xcframework/|Kiwix\.xcodeproj/|Support/LocalString\.swift$|Support/Kiwix(-unitTest)?\.entitlements$)' \
        || true
    )"
    if [[ -n "$unexpected_untracked" ]]; then
      echo "Refusing to build with untracked files that could affect the generated project:" >&2
      printf '%s\n' "$unexpected_untracked" >&2
      exit 1
    fi
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      printf '%s  %s\n' "$(hash_file "$ROOT_DIR/$file")" "$file"
    done < <(git -C "$ROOT_DIR" ls-files | LC_ALL=C sort) > "$output"
    return
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    local relative="${file#"$ROOT_DIR/"}"
    printf '%s  %s\n' "$(hash_file "$file")" "$relative"
  done < <(
    find "$ROOT_DIR" -type f \
      ! -path "$ROOT_DIR/Kiwix.xcodeproj/*" \
      ! -path "$ROOT_DIR/CoreKiwix.xcframework/*" \
      ! -path "$ROOT_DIR/Support/LocalString.swift" \
      ! -path "$ROOT_DIR/Support/Kiwix.entitlements" \
      ! -path "$ROOT_DIR/Support/Kiwix-unitTest.entitlements" \
      ! -name '.DS_Store' \
      | LC_ALL=C sort
  ) > "$output"
}

snapshot_source "$SOURCE_STATE_BEFORE"

if [[ -z "$XCODEGEN_ARCHIVE" ]]; then
  XCODEGEN_ARCHIVE="$TEMP_DIR/xcodegen-${XCODEGEN_VERSION}.zip"
  download_public_artifact "$XCODEGEN_URL" "$XCODEGEN_ARCHIVE" "XcodeGen ${XCODEGEN_VERSION}"
fi
require_hash "$XCODEGEN_ARCHIVE" "$XCODEGEN_ARCHIVE_SHA256" "XcodeGen ${XCODEGEN_VERSION} archive"
assert_safe_archive_paths "XcodeGen archive" unzip -Z1 "$XCODEGEN_ARCHIVE"
mkdir -p "$TEMP_DIR/xcodegen"
unzip -q "$XCODEGEN_ARCHIVE" -d "$TEMP_DIR/xcodegen"
XCODEGEN_BIN="$TEMP_DIR/xcodegen/xcodegen/bin/xcodegen"
[[ -x "$XCODEGEN_BIN" ]] || {
  echo "Pinned XcodeGen archive did not contain xcodegen/bin/xcodegen." >&2
  exit 1
}
[[ "$("$XCODEGEN_BIN" --version)" == "Version: $XCODEGEN_VERSION" ]] || {
  echo "Extracted XcodeGen executable is not version $XCODEGEN_VERSION." >&2
  exit 1
}

if [[ -z "$COREKIWIX_SOURCE_ARCHIVE" ]]; then
  [[ "$COREKIWIX_SOURCE_ARCHIVE_URL" =~ ^https://github\.com/TheArkFile/arkfile-ios/releases/download/[^\"\\[:space:]]+/[^\"\\[:space:]]+$ ]] || {
    echo "No local CoreKiwix source/relink archive was supplied and no published source/relink URL is bound." >&2
    exit 1
  }
  COREKIWIX_SOURCE_ARCHIVE="$TEMP_DIR/CoreKiwix-14.2.0+arkfile.1-source-and-relink.tar.gz"
  download_public_artifact "$COREKIWIX_SOURCE_ARCHIVE_URL" "$COREKIWIX_SOURCE_ARCHIVE" "controlled CoreKiwix source/relink material"
fi
require_hash "$COREKIWIX_SOURCE_ARCHIVE" "$COREKIWIX_SOURCE_ARCHIVE_SHA256" "controlled CoreKiwix source/relink archive"
CERTIFIED_COREKIWIX_SOURCE_SHA256="$(/usr/bin/plutil -extract sourceArchive.sha256 raw -o - "$ROOT_DIR/Dependencies/CoreKiwixNativeCertification.json")"
[[ "$COREKIWIX_SOURCE_ARCHIVE_SHA256" == "$CERTIFIED_COREKIWIX_SOURCE_SHA256" ]] || {
  echo "Controlled CoreKiwix archive differs from the certified native build." >&2
  exit 1
}
assert_safe_archive_paths "CoreKiwix source/relink archive" tar -tzf "$COREKIWIX_SOURCE_ARCHIVE"
assert_tar_has_no_links "$COREKIWIX_SOURCE_ARCHIVE" "CoreKiwix source/relink archive"
mkdir -p "$TEMP_DIR/corekiwix"
extract_corekiwix_framework "$COREKIWIX_SOURCE_ARCHIVE" "$TEMP_DIR/corekiwix"
EXTRACTED_FRAMEWORK="$TEMP_DIR/corekiwix/framework/CoreKiwix.xcframework"
[[ -d "$EXTRACTED_FRAMEWORK" && ! -L "$EXTRACTED_FRAMEWORK" ]] || {
  echo "Controlled CoreKiwix source/relink archive is missing literal framework/CoreKiwix.xcframework." >&2
  exit 1
}

ARKFILE_COREKIWIX_FRAMEWORK="$EXTRACTED_FRAMEWORK" \
  node "$ROOT_DIR/scripts/arkfile-corekiwix-certification.mjs" check

if [[ ! -e "$ROOT_DIR/CoreKiwix.xcframework" ]]; then
  cp -R "$EXTRACTED_FRAMEWORK" "$ROOT_DIR/CoreKiwix.xcframework"
fi
node "$ROOT_DIR/scripts/arkfile-corekiwix-certification.mjs" check

(
  cd "$ROOT_DIR"
  python3 localizations.py generate
  "$XCODEGEN_BIN"
  scripts/arkfile-swiftpm-lock.sh restore
  scripts/arkfile-swiftpm-lock.sh verify
)

if [[ "$PREPARE_ONLY" == "0" ]]; then
  DERIVED_DATA="$TEMP_DIR/DerivedData"
  xcodebuild \
    -quiet \
    -project "$ROOT_DIR/Kiwix.xcodeproj" \
    -scheme Kiwix \
    -resolvePackageDependencies \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile
  "$ROOT_DIR/scripts/arkfile-swiftpm-lock.sh" verify
  xcodebuild \
    -quiet \
    -project "$ROOT_DIR/Kiwix.xcodeproj" \
    -scheme Kiwix \
    -configuration Release \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    build
  "$ROOT_DIR/scripts/arkfile-swiftpm-lock.sh" verify
fi

SOURCE_STATE_AFTER="$TEMP_DIR/source-after.sha256"
snapshot_source "$SOURCE_STATE_AFTER"
if ! cmp -s "$SOURCE_STATE_BEFORE" "$SOURCE_STATE_AFTER"; then
  echo "Public build changed source files; refusing to report success." >&2
  diff -u "$SOURCE_STATE_BEFORE" "$SOURCE_STATE_AFTER" >&2 || true
  exit 1
fi

if [[ "$PREPARE_ONLY" == "1" ]]; then
  echo "Public source preparation passed; generated project and reviewed lock are ready."
else
  echo "Public unsigned iOS Simulator build passed with the reviewed dependency lock."
fi
