#!/usr/bin/env bash

set -euo pipefail

readonly GITLEAKS_VERSION="8.30.1"
readonly TRUFFLEHOG_VERSION="3.95.9"

usage() {
  echo "Usage: scripts/arkfile-install-secret-scanners.sh <dedicated-output-directory>" >&2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 && -n "$1" ]] || {
  usage
  exit 2
}

OUTPUT_DIR="$1"
[[ ! -L "$OUTPUT_DIR" ]] || fail "Output directory must not be a symlink: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" ]] || fail "Could not create output directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

case "$(uname -s)" in
  Darwin) scanner_os="darwin" ;;
  *) fail "Pinned CoreKiwix secret scanners currently support macOS release hosts only." ;;
esac

case "$(uname -m)" in
  arm64)
    gitleaks_arch="arm64"
    trufflehog_arch="arm64"
    gitleaks_sha256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
    trufflehog_sha256="944c6ea3a2993a9f808d08107b40e03ba92bc75972876a1ee47d567bfd6fa1b5"
    ;;
  x86_64)
    gitleaks_arch="x64"
    trufflehog_arch="amd64"
    gitleaks_sha256="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
    trufflehog_sha256="4306a58d25b85aad7b5fb6f5732df77c50a9161db2746b56e196649072218691"
    ;;
  *) fail "Unsupported macOS architecture: $(uname -m)" ;;
esac

INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/arkfile-secret-scanners.XXXXXX")"
trap 'rm -rf "$INSTALL_TMP"' EXIT

download_and_install() {
  local name="$1"
  local url="$2"
  local expected_sha256="$3"
  local archive="$INSTALL_TMP/$name.tar.gz"
  local extracted="$INSTALL_TMP/$name"

  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors \
    --output "$archive" \
    "$url"
  printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c -
  if tar -tzf "$archive" | awk -F/ '
    /^\// { bad = 1 }
    /\\/ { bad = 1 }
    { for (part = 1; part <= NF; part += 1) if ($part == "..") bad = 1 }
    END { exit bad ? 0 : 1 }
  '; then
    fail "$name release archive contains an unsafe path."
  fi
  if tar -tvzf "$archive" | awk '$1 ~ /^[lh]/ { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "$name release archive contains a link."
  fi
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted"
  [[ -f "$extracted/$name" && ! -L "$extracted/$name" ]] \
    || fail "$name release archive did not contain exactly the expected executable."
  install -m 0755 "$extracted/$name" "$OUTPUT_DIR/$name"
}

download_and_install \
  gitleaks \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${scanner_os}_${gitleaks_arch}.tar.gz" \
  "$gitleaks_sha256"

download_and_install \
  trufflehog \
  "https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_${scanner_os}_${trufflehog_arch}.tar.gz" \
  "$trufflehog_sha256"

[[ "$($OUTPUT_DIR/gitleaks version)" == "$GITLEAKS_VERSION" ]] \
  || fail "Installed Gitleaks version does not match $GITLEAKS_VERSION."
[[ "$($OUTPUT_DIR/trufflehog --version)" == "trufflehog $TRUFFLEHOG_VERSION" ]] \
  || fail "Installed TruffleHog version does not match $TRUFFLEHOG_VERSION."

echo "Installed pinned Gitleaks $GITLEAKS_VERSION and TruffleHog $TRUFFLEHOG_VERSION in $OUTPUT_DIR."
