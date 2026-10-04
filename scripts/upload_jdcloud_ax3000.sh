#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Defaults
# ============================================================

IMMORTALWRT_DIR="/build/source"
UPLOAD_DIR="/upload"

PROFILE="jdcloud_ax3000"

REPO_PUBLIC_BASE="https://repo.kamino.eu.org"
REPO_PREFIX="immortalwrt"

# ============================================================
# Helpers
# ============================================================

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

usage() {
    cat <<'EOF'
Usage:
  upload_jdcloud_ax3000.sh [options]

Options:
  -h, --help
      Show this help.

Environment (Required):
  REPO_BUCKET_NAME
  REPO_ACCOUNT_ID
  REPO_ACCESS_KEY_ID
  REPO_SECRET_ACCESS_KEY
EOF
}

setup_repo_upload() {
    command -v aws >/dev/null 2>&1 || \
        die "AWS CLI is required for R2 upload"

    : "${REPO_BUCKET_NAME:?REPO_BUCKET_NAME is required}"
    : "${REPO_ACCOUNT_ID:?REPO_ACCOUNT_ID is required}"
    : "${REPO_ACCESS_KEY_ID:?REPO_ACCESS_KEY_ID is required}"
    : "${REPO_SECRET_ACCESS_KEY:?REPO_SECRET_ACCESS_KEY is required}"

    REPO_ENDPOINT_URL="https://${REPO_ACCOUNT_ID}.r2.cloudflarestorage.com"
}

repo_sync() {
    local source_dir="$1"
    local object_prefix="$2"
    local description="$3"

    [[ -d "$source_dir" ]] || \
        die "$description directory not found: $source_dir"

    local destination
    destination="s3://${REPO_BUCKET_NAME}/${object_prefix}/"

    echo
    echo "$description"
    echo "Source:      $source_dir/"
    echo "Destination: $destination"
    echo

    AWS_ACCESS_KEY_ID="$REPO_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$REPO_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws s3 sync \
            "$source_dir/" \
            "$destination" \
            --endpoint-url "$REPO_ENDPOINT_URL" \
            --only-show-errors \
            --no-progress
}

upload_build_artifacts() {
    local source_dir="$1"
    local object_prefix="$2"

    [[ -d "$source_dir" ]] || \
        die "Upload directory not found: $source_dir"

    local destination
    destination="s3://${REPO_BUCKET_NAME}/${object_prefix}/"

    echo
    echo "Build artifacts"
    echo "Source:      $source_dir/"
    echo "Destination: $destination"
    echo

    AWS_ACCESS_KEY_ID="$REPO_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$REPO_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws s3 sync \
            "$source_dir/" \
            "$destination" \
            --endpoint-url "$REPO_ENDPOINT_URL" \
            --exclude "*" \
            --include "*.bin" \
            --include "*.itb" \
            --include "*.manifest" \
            --include "*imagebuilder*.tar.zst" \
            --include "sha256sums" \
            --only-show-errors \
            --no-progress
}

# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;

        *)
            die "Unknown option: $1"
            ;;
    esac
done

# ============================================================
# Resolve directories
# ============================================================

[[ -d "$IMMORTALWRT_DIR" ]] || \
    die "ImmortalWrt directory not found: $IMMORTALWRT_DIR"

IMMORTALWRT_DIR="$(cd "$IMMORTALWRT_DIR" && pwd)"

[[ -d "$UPLOAD_DIR" ]] || \
    die "Upload directory not found: $UPLOAD_DIR"

UPLOAD_DIR="$(cd "$UPLOAD_DIR" && pwd)"

# ============================================================
# Read target metadata
# ============================================================

log "Reading target metadata"

build_values="$(
    make \
        -C "$IMMORTALWRT_DIR" \
        --no-print-directory \
        -s \
        val.BOARD \
        val.SUBTARGET \
        val.STAGING_DIR \
        val.ARCH_PACKAGES
)"

mapfile -t build_value_array <<< "$build_values"

if (( ${#build_value_array[@]} != 4 )); then
    die "Failed to read BOARD, SUBTARGET, STAGING_DIR and ARCH_PACKAGES"
fi

BOARD="${build_value_array[0]}"
SUBTARGET="${build_value_array[1]}"
STAGING_DIR="${build_value_array[2]}"
ARCH_PACKAGES="${build_value_array[3]}"

if [[ "$STAGING_DIR" != /* ]]; then
    STAGING_DIR="$IMMORTALWRT_DIR/$STAGING_DIR"
fi

VERSION_NUMBER="$(
    make \
        --no-print-directory \
        -s \
        -f /dev/null \
        --eval "TOPDIR:=$IMMORTALWRT_DIR" \
        --eval 'include $(TOPDIR)/rules.mk' \
        --eval 'include $(INCLUDE_DIR)/version.mk' \
        --eval 'print-version:;@printf "%s\n" "$(VERSION_NUMBER)"' \
        print-version
)"

[[ -n "$BOARD" ]] || die "BOARD is empty"
[[ -n "$SUBTARGET" ]] || die "SUBTARGET is empty"
[[ -n "$ARCH_PACKAGES" ]] || die "ARCH_PACKAGES is empty"
[[ -n "$VERSION_NUMBER" ]] || die "VERSION_NUMBER is empty"

echo "Version      : $VERSION_NUMBER"
echo "Board        : $BOARD"
echo "Subtarget    : $SUBTARGET"
echo "Architecture : $ARCH_PACKAGES"
echo "Staging dir  : $STAGING_DIR"

# ============================================================
# Upload everything to R2
# ============================================================

log "Preparing R2 upload"

setup_repo_upload

echo "Bucket   : $REPO_BUCKET_NAME"
echo "Endpoint : $REPO_ENDPOINT_URL"

# ============================================================
# A. Upload firmware / ImageBuilder / manifests
#
# Remote:
#   immortalwrt/<version>/targets/<board>/<subtarget>/
# ============================================================

log "Uploading build artifacts to R2"

TARGET_OBJECT_PREFIX="$REPO_PREFIX/$VERSION_NUMBER/targets/$BOARD/$SUBTARGET"

upload_build_artifacts \
    "$UPLOAD_DIR" \
    "$TARGET_OBJECT_PREFIX"

echo "Public target directory:"
echo "  $REPO_PUBLIC_BASE/$TARGET_OBJECT_PREFIX/"

# ============================================================
# B. Upload kmods
#
# Local:
#   bin/targets/<board>/<subtarget>/packages/
#
# Remote:
#   immortalwrt/<version>/
#     targets/<board>/<subtarget>/
#       kmods/<kernel-abi>/
# ============================================================

log "Uploading kmods to R2"

KERNEL_VERSION_FILE="$STAGING_DIR/kernel.version"

[[ -f "$KERNEL_VERSION_FILE" ]] || \
    die "Kernel version file not found: $KERNEL_VERSION_FILE"

KERNEL_PACKAGE_VERSION="$(<"$KERNEL_VERSION_FILE")"

if [[ ! "$KERNEL_PACKAGE_VERSION" =~ ^([^~]+)~(.+)-r([0-9]+)$ ]]; then
    die "Unsupported kernel version format: $KERNEL_PACKAGE_VERSION"
fi

LINUX_VERSION="${BASH_REMATCH[1]}"
LINUX_VERMAGIC="${BASH_REMATCH[2]}"
LINUX_RELEASE="${BASH_REMATCH[3]}"

KERNEL_ABI="${LINUX_VERSION}-${LINUX_RELEASE}-${LINUX_VERMAGIC}"

KMOD_DIR="$IMMORTALWRT_DIR/bin/targets/$BOARD/$SUBTARGET/packages"

[[ -d "$KMOD_DIR" ]] || \
    die "kmod directory not found: $KMOD_DIR"

[[ -f "$KMOD_DIR/packages.adb" ]] || \
    die "kmod packages.adb not found: $KMOD_DIR/packages.adb"

KMOD_OBJECT_PREFIX="$TARGET_OBJECT_PREFIX/kmods/$KERNEL_ABI"

echo "Kernel package version: $KERNEL_PACKAGE_VERSION"
echo "Kernel ABI            : $KERNEL_ABI"

repo_sync \
    "$KMOD_DIR" \
    "$KMOD_OBJECT_PREFIX" \
    "KMOD repository"

echo "KMOD repository:"
echo "  $REPO_PUBLIC_BASE/$KMOD_OBJECT_PREFIX/packages.adb"

# ============================================================
# C. Upload extra package feed
#
# Local:
#   bin/packages/<arch>/extra/
#
# Remote:
#   immortalwrt/<version>/packages/<arch>/extra/
# ============================================================

log "Uploading extra packages to R2"

EXTRA_PACKAGE_DIR="$IMMORTALWRT_DIR/bin/packages/$ARCH_PACKAGES/extra"

if [[ -d "$EXTRA_PACKAGE_DIR" && -f "$EXTRA_PACKAGE_DIR/packages.adb" ]]; then
    EXTRA_OBJECT_PREFIX="$REPO_PREFIX/$VERSION_NUMBER/packages/$ARCH_PACKAGES/extra"

    repo_sync \
        "$EXTRA_PACKAGE_DIR" \
        "$EXTRA_OBJECT_PREFIX" \
        "Extra package repository"

    echo "Extra package repository:"
    echo "  $REPO_PUBLIC_BASE/$EXTRA_OBJECT_PREFIX/packages.adb"
else
    echo "Notice: extra package directory or packages.adb not found, skipping extra package sync."
fi

# ============================================================
# Done
# ============================================================

log "Upload completed"

echo "R2 build artifacts:"
echo "  $REPO_PUBLIC_BASE/$TARGET_OBJECT_PREFIX/"

echo "R2 kmods:"
echo "  $REPO_PUBLIC_BASE/$KMOD_OBJECT_PREFIX/packages.adb"

if [[ -d "$EXTRA_PACKAGE_DIR" && -f "$EXTRA_PACKAGE_DIR/packages.adb" ]]; then
    echo "R2 extra packages:"
    echo "  $REPO_PUBLIC_BASE/$EXTRA_OBJECT_PREFIX/packages.adb"
fi
