#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/openwrt-common.sh
source "$SCRIPT_DIR/openwrt-common.sh"
SOURCE_DIR=$(realpath -e "${SOURCE_DIR:-/build/source}")
UPLOAD_DIR=$(realpath -e "${UPLOAD_DIR:-/upload}")
REPO_PUBLIC_BASE=${REPO_PUBLIC_BASE:-https://repo.kamino.eu.org}

command -v aws >/dev/null || die 'AWS CLI is required'
: "${REPO_BUCKET_NAME:?REPO_BUCKET_NAME is required}"
: "${REPO_ACCOUNT_ID:?REPO_ACCOUNT_ID is required}"
: "${REPO_ACCESS_KEY_ID:?REPO_ACCESS_KEY_ID is required}"
: "${REPO_SECRET_ACCESS_KEY:?REPO_SECRET_ACCESS_KEY is required}"
export AWS_ACCESS_KEY_ID="$REPO_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$REPO_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
REPO_ENDPOINT_URL="https://${REPO_ACCOUNT_ID}.r2.cloudflarestorage.com"
read_build_metadata
TARGET_PREFIX="$REPO_PREFIX/$VERSION_NUMBER/targets/$BOARD/$SUBTARGET"

repo_sync() {
    local source=$1 prefix=$2
    shift 2
    log "Uploading $source → $prefix"
    aws s3 sync "$source/" "s3://$REPO_BUCKET_NAME/$prefix/" \
        --endpoint-url "$REPO_ENDPOINT_URL" --only-show-errors --no-progress "$@"
    echo "$REPO_PUBLIC_BASE/$prefix/"
}

repo_sync "$UPLOAD_DIR" "$TARGET_PREFIX" \
    --exclude '*' --include '*.bin' --include '*.itb' --include '*.img' \
    --include '*.img.gz' --include '*.img.zst' --include '*.ubi' --include '*.ubifs' \
    --include '*sysupgrade*.tar' --include '*.manifest' \
    --include '*imagebuilder*.tar.zst' --include '*imagebuilder*.tar.xz' \
    --include '*imagebuilder*.tar.gz' --include sha256sums

KMOD_DIR="$TARGET_OUTPUT_DIR/packages"
[[ -d "$KMOD_DIR" ]] || die "Missing kmod repository: $KMOD_DIR"
if [[ -f "$KMOD_DIR/packages.adb" ]]; then
    [[ -f "$STAGING_DIR/kernel.version" ]] || die 'Missing kernel.version'
    KERNEL_PACKAGE_VERSION=$(< "$STAGING_DIR/kernel.version")
    if [[ "$KERNEL_PACKAGE_VERSION" =~ ^([^~]+)~(.+)-r([0-9]+)$ ]]; then
        KERNEL_ABI="${BASH_REMATCH[1]}-${BASH_REMATCH[3]}-${BASH_REMATCH[2]}"
    else
        die "Unsupported APK kernel version: $KERNEL_PACKAGE_VERSION"
    fi
    repo_sync "$KMOD_DIR" "$TARGET_PREFIX/kmods/$KERNEL_ABI"
elif [[ -f "$KMOD_DIR/Packages" || -f "$KMOD_DIR/Packages.gz" ]]; then
    # OPKG source trees embed their target package URL under /packages/.
    repo_sync "$KMOD_DIR" "$TARGET_PREFIX/packages"
else
    die "Missing package repository index in $KMOD_DIR"
fi

EXTRA_PACKAGE_DIR="$SOURCE_DIR/bin/packages/$ARCH_PACKAGES/extra"
if [[ -f "$EXTRA_PACKAGE_DIR/packages.adb" || -f "$EXTRA_PACKAGE_DIR/Packages" || -f "$EXTRA_PACKAGE_DIR/Packages.gz" ]]; then
    repo_sync "$EXTRA_PACKAGE_DIR" "$REPO_PREFIX/$VERSION_NUMBER/packages/$ARCH_PACKAGES/extra"
else
    echo 'No indexed extra feed repository; skipping'
fi
