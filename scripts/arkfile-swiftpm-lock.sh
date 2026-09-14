#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REVIEWED_LOCK="$ROOT_DIR/Dependencies/Package.resolved"
GENERATED_LOCK="$ROOT_DIR/Kiwix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

usage() {
  echo "Usage: $0 restore|verify" >&2
}

validate_reviewed_lock() {
  if [ ! -f "$REVIEWED_LOCK" ]; then
    echo "Reviewed SwiftPM lock is missing: $REVIEWED_LOCK" >&2
    exit 1
  fi
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$REVIEWED_LOCK"
}

command_name=${1:-}
case "$command_name" in
  restore)
    validate_reviewed_lock
    if [ ! -d "$ROOT_DIR/Kiwix.xcodeproj" ]; then
      echo "Generate Kiwix.xcodeproj with XcodeGen before restoring the lock." >&2
      exit 1
    fi
    mkdir -p "$(dirname -- "$GENERATED_LOCK")"
    cp "$REVIEWED_LOCK" "$GENERATED_LOCK"
    echo "Restored reviewed SwiftPM lock into the generated project."
    ;;
  verify)
    validate_reviewed_lock
    if [ ! -f "$GENERATED_LOCK" ]; then
      echo "Generated SwiftPM lock is missing. Run restore, then resolve packages." >&2
      exit 1
    fi
    if ! cmp -s "$REVIEWED_LOCK" "$GENERATED_LOCK"; then
      echo "Generated SwiftPM lock differs from Dependencies/Package.resolved." >&2
      echo "Review dependency changes; do not ship an unreviewed resolution." >&2
      exit 1
    fi
    echo "SwiftPM resolution matches Dependencies/Package.resolved."
    ;;
  *)
    usage
    exit 64
    ;;
esac
