#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/openwrt-common.sh
source "$SCRIPT_DIR/openwrt-common.sh"
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR=$(realpath -e "${SOURCE_DIR:-/build/source}")
PATCHES_NAME=${PATCHES_NAME:-}
[[ -n "$PATCHES_NAME" ]] || { echo 'No source patch set selected'; exit 0; }
[[ "$PATCHES_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'patches must be a folder name under ./patches'
PATCH_DIR="$PROJECT_DIR/patches/$PATCHES_NAME"
[[ -d "$PATCH_DIR" ]] || die "Patch set not found: $PATCH_DIR"
mapfile -d '' -t patches < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
(( ${#patches[@]} > 0 )) || die "No .patch files in $PATCH_DIR"
for patch in "${patches[@]}"; do
    log "Applying $(basename "$patch")"
    git -C "$SOURCE_DIR" apply --check --binary "$patch"
    git -C "$SOURCE_DIR" apply --binary "$patch"
done
