#!/usr/bin/env bash
# Download and unpack augmem/cortext release assets for offline / CI use.
set -euo pipefail

VERSION="${CORTEXT_ASSETS_VERSION:-1.2.4}"
VERSION="${VERSION#v}"
DEST="${1:-${CORTEXT_ASSETS_DIR:-}}"
if [[ -z "${DEST}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    DEST="${HOME}/Library/Caches/augmem/cortext/assets/${VERSION}"
  else
    DEST="${XDG_CACHE_HOME:-$HOME/.cache}/augmem/cortext/assets/${VERSION}"
  fi
fi
BASE_URL="${CORTEXT_ASSETS_URL:-https://github.com/augmem/cortext/releases/download/v${VERSION}/cortext-assets-${VERSION}.tar.gz}"
SUM_URL="${BASE_URL}.sha256"

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE_NAME="cortext-assets-${VERSION}.tar.gz"
echo "Fetching $BASE_URL"
curl -fsSL -o "$TMP/$ARCHIVE_NAME" "$BASE_URL"
curl -fsSL -o "$TMP/$ARCHIVE_NAME.sha256" "$SUM_URL"

EXPECTED="$(awk '{print $1}' "$TMP/$ARCHIVE_NAME.sha256" | tr '[:upper:]' '[:lower:]')"
if command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$TMP/$ARCHIVE_NAME" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/$ARCHIVE_NAME" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
else
  echo "need shasum or sha256sum" >&2
  exit 1
fi

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "checksum mismatch: got $ACTUAL want $EXPECTED" >&2
  exit 1
fi

# Unpack into DEST (idempotent: clear partial trees first when marker missing)
if [[ ! -f "$DEST/.cortext-assets-ok" ]]; then
  find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
tar -xzf "$TMP/$ARCHIVE_NAME" -C "$DEST"
echo "$VERSION" >"$DEST/.cortext-assets-ok"
echo "Unpacked assets into $DEST"
echo "export CORTEXT_ASSETS_DIR=$DEST"
