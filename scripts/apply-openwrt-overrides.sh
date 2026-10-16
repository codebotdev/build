#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/openwrt-common.sh
source "$SCRIPT_DIR/openwrt-common.sh"
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR=$(realpath -e "${SOURCE_DIR:-/build/source}")
OVERRIDES_NAME=${OVERRIDES_NAME:-}
[[ -n "$OVERRIDES_NAME" ]] || { echo 'No source overrides selected'; exit 0; }
[[ "$OVERRIDES_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'overrides must be a folder name under ./overrides'
OVERRIDES_DIR="$PROJECT_DIR/overrides/$OVERRIDES_NAME"
[[ -d "$OVERRIDES_DIR" ]] || die "Overrides not found: $OVERRIDES_DIR"
log "Copying overrides from $OVERRIDES_DIR"
# Merge contents into the source root, preserving modes and binary files.
# Files outside the override set remain in place.
rsync -a --checksum -- "$OVERRIDES_DIR/" "$SOURCE_DIR/"
