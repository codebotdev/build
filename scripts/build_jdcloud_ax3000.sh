#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Defaults
# ============================================================

IMMORTALWRT_DIR="/build/source"
IMAGEBUILDER_DIR="/build/imagebuilder"
UPLOAD_DIR="/upload"

PROFILE="jdcloud_ax3000"

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
  build_jdcloud_ax3000.sh [options]

Options:
  -h, --help
      Show this help.

Environment:
  JOBS=N
      Override parallel job count.
      Default: number of available CPUs.
EOF
}

cleanup_tmp_files() {
    if [[ -n "${EXTRACT_TMP:-}" && -d "${EXTRACT_TMP:-}" ]]; then
        rm -rf "$EXTRACT_TMP"
    fi

    for f in \
        "${MODULE_CANDIDATES:-}" \
        "${AVAILABLE_PACKAGES:-}" \
        "${FULL_EXTRA_PACKAGES:-}" \
        "${INVALID_MODULES:-}" \
        "${I18N_CANDIDATES:-}"
    do
        if [[ -n "$f" && -f "$f" ]]; then
            rm -f "$f"
        fi
    done
}

trap cleanup_tmp_files EXIT

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
# Parallel jobs
# ============================================================

if [[ -n "${JOBS:-}" ]]; then
    :
elif command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
elif command -v getconf >/dev/null 2>&1; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
else
    JOBS=1
fi

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || \
    die "Invalid JOBS value: $JOBS"

# ============================================================
# Resolve directories
# ============================================================

[[ -d "$IMMORTALWRT_DIR" ]] || \
    die "ImmortalWrt directory not found: $IMMORTALWRT_DIR"

IMMORTALWRT_DIR="$(cd "$IMMORTALWRT_DIR" && pwd)"

mkdir -p "$IMAGEBUILDER_DIR"
IMAGEBUILDER_DIR="$(cd "$IMAGEBUILDER_DIR" && pwd)"

mkdir -p "$UPLOAD_DIR"
UPLOAD_DIR="$(cd "$UPLOAD_DIR" && pwd)"

case "$IMAGEBUILDER_DIR" in
    ""|"/"|"/build")
        die "Unsafe ImageBuilder directory: $IMAGEBUILDER_DIR"
        ;;
esac

# ============================================================
# Source paths
# ============================================================

CONFIG_FILE="$IMMORTALWRT_DIR/jdcloud_ax3000.config"
KMODS_CONFIG="$IMMORTALWRT_DIR/kmods.config"

[[ -f "$CONFIG_FILE" ]] || \
    die "Missing: $CONFIG_FILE"

[[ -f "$KMODS_CONFIG" ]] || \
    die "Missing: $KMODS_CONFIG"

[[ -x "$IMMORTALWRT_DIR/scripts/feeds" ]] || \
    die "Missing: $IMMORTALWRT_DIR/scripts/feeds"

[[ -x "$IMMORTALWRT_DIR/scripts/apply-feed-patches.sh" ]] || \
    die "Missing: $IMMORTALWRT_DIR/scripts/apply-feed-patches.sh"

# ============================================================
# Summary
# ============================================================

log "Build configuration"

echo "ImmortalWrt : $IMMORTALWRT_DIR"
echo "ImageBuilder: $IMAGEBUILDER_DIR"
echo "Upload dir  : $UPLOAD_DIR"
echo "Jobs        : $JOBS"
echo "Profile     : $PROFILE"

cd "$IMMORTALWRT_DIR"

# ============================================================
# 1. Update feeds
# ============================================================

log "Updating feeds"

./scripts/feeds update -a

# ============================================================
# 2. Apply feed patches
# ============================================================

log "Applying feed patches"

./scripts/apply-feed-patches.sh

# ============================================================
# 3. Install feeds
# ============================================================

log "Installing feeds"

./scripts/feeds install -a

# ============================================================
# 4. Generate .config
# ============================================================

log "Generating .config"

cat \
    "$KMODS_CONFIG" \
    "$CONFIG_FILE" \
    > "$IMMORTALWRT_DIR/.config"

make defconfig

echo
echo "ImageBuilder configuration:"
grep -E '^CONFIG_IB(=|_)' .config || true

grep -q '^CONFIG_IB=y$' .config || \
    die "CONFIG_IB=y is not enabled after make defconfig"

grep -q '^CONFIG_IB_STANDALONE=y$' .config || \
    die "CONFIG_IB_STANDALONE=y is not enabled after make defconfig"

# ============================================================
# 5. Read target metadata
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

TARGET_OUTPUT_DIR="$IMMORTALWRT_DIR/bin/targets/$BOARD/$SUBTARGET"

echo "Version      : $VERSION_NUMBER"
echo "Board        : $BOARD"
echo "Subtarget    : $SUBTARGET"
echo "Architecture : $ARCH_PACKAGES"
echo "Staging dir  : $STAGING_DIR"

# ============================================================
# 6. Download
# ============================================================

log "Downloading sources with -j$JOBS"

make download -j"$JOBS"

# ============================================================
# 7. Build
# ============================================================

log "Building ImmortalWrt with -j$JOBS"

make -j"$JOBS" world

# ============================================================
# 8. Rebuild Standalone ImageBuilder
# ============================================================

log "Rebuilding Standalone ImageBuilder with complete APK repository"

make target/imagebuilder/clean
make -j1 target/imagebuilder/compile

# ============================================================
# 9. Locate ImageBuilder
# ============================================================

log "Locating ImageBuilder archive"

[[ -d "$TARGET_OUTPUT_DIR" ]] || \
    die "Target output directory not found: $TARGET_OUTPUT_DIR"

IB_ARCHIVE="$(
    find "$TARGET_OUTPUT_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*imagebuilder*.tar.zst' \
        -printf '%T@\t%p\n' \
        | sort -nr \
        | sed -n '1s/^[^	]*	//p'
)"

[[ -n "$IB_ARCHIVE" ]] || \
    die "ImageBuilder archive not found"

[[ -f "$IB_ARCHIVE" ]] || \
    die "ImageBuilder archive not found: $IB_ARCHIVE"

echo "ImageBuilder archive:"
echo "  $IB_ARCHIVE"

ls -lh "$IB_ARCHIVE"

# ============================================================
# 10. Locate source manifest
# ============================================================

log "Locating source firmware manifest"

SRC_MANIFEST="$(
    find "$TARGET_OUTPUT_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*-${PROFILE}.manifest" \
        -printf '%T@\t%p\n' \
        | sort -nr \
        | sed -n '1s/^[^	]*	//p'
)"

[[ -n "$SRC_MANIFEST" ]] || \
    die "Source firmware manifest not found in: $TARGET_OUTPUT_DIR"

echo "Source manifest:"
echo "  $SRC_MANIFEST"

# ============================================================
# 11. Extract ImageBuilder
# ============================================================

log "Extracting ImageBuilder"

EXTRACT_TMP="$(mktemp -d "${IMAGEBUILDER_DIR}.extract.XXXXXX")"

if tar --help 2>/dev/null | grep -F -- '--zstd' >/dev/null; then

    tar \
        --zstd \
        -xf "$IB_ARCHIVE" \
        -C "$EXTRACT_TMP"

else

    command -v zstd >/dev/null 2>&1 || \
        die "Neither tar --zstd nor zstd is available"

    zstd -dc "$IB_ARCHIVE" | \
        tar -xf - -C "$EXTRACT_TMP"
fi

mapfile -t EXTRACTED_ENTRIES < <(
    find "$EXTRACT_TMP" \
        -mindepth 1 \
        -maxdepth 1 \
        -print
)

if [[ "${#EXTRACTED_ENTRIES[@]}" -eq 1 &&
      -d "${EXTRACTED_ENTRIES[0]}" &&
      -f "${EXTRACTED_ENTRIES[0]}/Makefile" ]]; then

    EXTRACTED_ROOT="${EXTRACTED_ENTRIES[0]}"
else
    EXTRACTED_ROOT="$EXTRACT_TMP"
fi

find "$IMAGEBUILDER_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- {} +

cp -a \
    "$EXTRACTED_ROOT"/. \
    "$IMAGEBUILDER_DIR"/

[[ -f "$IMAGEBUILDER_DIR/Makefile" ]] || \
    die "Invalid ImageBuilder: Makefile not found"

[[ -f "$IMAGEBUILDER_DIR/.packageinfo" ]] || \
    die "Invalid ImageBuilder: .packageinfo not found"

[[ -d "$IMAGEBUILDER_DIR/packages" ]] || \
    die "Invalid Standalone ImageBuilder: packages directory not found"

APK_COUNT="$(
    find "$IMAGEBUILDER_DIR/packages" \
        -maxdepth 1 \
        -type f \
        -name '*.apk' \
        | wc -l
)"

[[ "$APK_COUNT" -gt 0 ]] || \
    die "Standalone ImageBuilder contains no APK packages"

echo "Standalone APK count: $APK_COUNT"

rm -rf "$EXTRACT_TMP"
EXTRACT_TMP=""

# ============================================================
# 12. Generate mini.packages
# ============================================================

log "Generating mini.packages"

MINI_PACKAGES="$IMAGEBUILDER_DIR/mini.packages"
FULL_PACKAGES="$IMAGEBUILDER_DIR/full.packages"

sed 's/ - .*//' "$SRC_MANIFEST" \
    | grep -vE '^(base-files|libc|kernel)$' \
    | sort -u \
    > "$MINI_PACKAGES"

[[ -s "$MINI_PACKAGES" ]] || \
    die "mini.packages is empty"

# ============================================================
# 13. Generate full.packages
# ============================================================

log "Generating full.packages"

MODULE_CANDIDATES="$(mktemp)"
AVAILABLE_PACKAGES="$(mktemp)"
FULL_EXTRA_PACKAGES="$(mktemp)"
INVALID_MODULES="$(mktemp)"
I18N_CANDIDATES="$(mktemp)"

sed -n \
    's/^CONFIG_PACKAGE_\(.*\)=m$/\1/p' \
    "$CONFIG_FILE" \
    | sort -u \
    > "$MODULE_CANDIDATES"

awk '
    /^Package:[[:space:]]+/ {
        print $2
    }
' "$IMAGEBUILDER_DIR/.packageinfo" \
    | sort -u \
    > "$AVAILABLE_PACKAGES"

comm -12 \
    "$MODULE_CANDIDATES" \
    "$AVAILABLE_PACKAGES" \
    > "$FULL_EXTRA_PACKAGES"

comm -23 \
    "$MODULE_CANDIDATES" \
    "$AVAILABLE_PACKAGES" \
    > "$INVALID_MODULES"

if [[ -s "$INVALID_MODULES" ]]; then
    echo
    echo "Ignoring CONFIG_PACKAGE_* entries that are not real packages:"
    cat "$INVALID_MODULES"
fi

# Auto-include corresponding luci-i18n-*-zh-cn for enabled LuCI applications
sed -n 's/^luci-\(app\|theme\|proto\)-\(.*\)/luci-i18n-\2-zh-cn/p' \
    "$FULL_EXTRA_PACKAGES" \
    | sort -u \
    > "$I18N_CANDIDATES"

comm -12 \
    "$I18N_CANDIDATES" \
    "$AVAILABLE_PACKAGES" \
    >> "$FULL_EXTRA_PACKAGES"

sort -u "$FULL_EXTRA_PACKAGES" -o "$FULL_EXTRA_PACKAGES"

cat \
    "$MINI_PACKAGES" \
    "$FULL_EXTRA_PACKAGES" \
    | sort -u \
    > "$FULL_PACKAGES"

[[ -s "$FULL_PACKAGES" ]] || \
    die "full.packages is empty"

rm -f \
    "$MODULE_CANDIDATES" \
    "$AVAILABLE_PACKAGES" \
    "$FULL_EXTRA_PACKAGES" \
    "$INVALID_MODULES" \
    "$I18N_CANDIDATES"

MODULE_CANDIDATES=""
AVAILABLE_PACKAGES=""
FULL_EXTRA_PACKAGES=""
INVALID_MODULES=""
I18N_CANDIDATES=""

# ============================================================
# 14. Package summary
# ============================================================

log "Package lists"

echo "mini.packages: $(wc -l < "$MINI_PACKAGES") packages"
echo "full.packages: $(wc -l < "$FULL_PACKAGES") packages"

echo
echo "Packages explicitly added by full:"

comm -13 \
    "$MINI_PACKAGES" \
    "$FULL_PACKAGES" || true

# ============================================================
# 15. Build MINI
# ============================================================

cd "$IMAGEBUILDER_DIR"

MINI_BIN_DIR="$IMAGEBUILDER_DIR/bin/mini"
FULL_BIN_DIR="$IMAGEBUILDER_DIR/bin/full"

rm -rf "$MINI_BIN_DIR"
mkdir -p "$MINI_BIN_DIR"

log "Building MINI firmware"

make image \
    PROFILE="$PROFILE" \
    PACKAGES="$(tr '\n' ' ' < "$MINI_PACKAGES")" \
    EXTRA_IMAGE_NAME="mini" \
    BIN_DIR="$MINI_BIN_DIR"

# ============================================================
# 16. Build FULL
# ============================================================

rm -rf "$FULL_BIN_DIR"
mkdir -p "$FULL_BIN_DIR"

log "Building FULL firmware"

make image \
    PROFILE="$PROFILE" \
    PACKAGES="$(tr '\n' ' ' < "$FULL_PACKAGES")" \
    BIN_DIR="$FULL_BIN_DIR"

# ============================================================
# 17. Find manifests
# ============================================================

MINI_MANIFEST="$(
    find "$MINI_BIN_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.manifest' \
        -print \
        | sort \
        | sed -n '1p'
)"

FULL_MANIFEST="$(
    find "$FULL_BIN_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.manifest' \
        -print \
        | sort \
        | sed -n '1p'
)"

[[ -n "$MINI_MANIFEST" ]] || \
    die "MINI manifest was not generated"

[[ -n "$FULL_MANIFEST" ]] || \
    die "FULL manifest was not generated"

# ============================================================
# 18. Verify MINI
# ============================================================

log "Verifying MINI package set"

MINI_DIFF="$(
    comm -3 \
        <(
            sed 's/ - .*//' "$SRC_MANIFEST" \
                | sort -u
        ) \
        <(
            sed 's/ - .*//' "$MINI_MANIFEST" \
                | sort -u
        )
)"

if [[ -n "$MINI_DIFF" ]]; then
    echo "WARNING: MINI package set differs from source firmware:"
    echo "$MINI_DIFF"
else
    echo "MINI package set matches source firmware."
fi

# ============================================================
# 19. FULL-only packages
# ============================================================

log "Packages installed only in FULL"

comm -13 \
    <(
        sed 's/ - .*//' "$MINI_MANIFEST" \
            | sort -u
    ) \
    <(
        sed 's/ - .*//' "$FULL_MANIFEST" \
            | sort -u
    ) || true

# ============================================================
# 20. Display firmware
# ============================================================

log "Generated MINI firmware"

find "$MINI_BIN_DIR" \
    -maxdepth 1 \
    -type f \
    \( \
        -name '*.bin' \
        -o -name '*.itb' \
        -o -name '*.manifest' \
    \) \
    -exec ls -lh {} \;

log "Generated FULL firmware"

find "$FULL_BIN_DIR" \
    -maxdepth 1 \
    -type f \
    \( \
        -name '*.bin' \
        -o -name '*.itb' \
        -o -name '*.manifest' \
    \) \
    -exec ls -lh {} \;

# ============================================================
# 21. Copy build artifacts to upload-dir
#
# Copies:
#   - Standalone ImageBuilder
#   - MINI .bin / .itb / .manifest
#   - FULL .bin / .itb / .manifest
# ============================================================

log "Copying build artifacts to $UPLOAD_DIR"

cp -f \
    "$IB_ARCHIVE" \
    "$UPLOAD_DIR/"

while IFS= read -r -d '' artifact; do

    cp -f \
        "$artifact" \
        "$UPLOAD_DIR/"

done < <(
    find \
        "$MINI_BIN_DIR" \
        "$FULL_BIN_DIR" \
        -maxdepth 1 \
        -type f \
        \( \
            -name '*.bin' \
            -o -name '*.itb' \
            -o -name '*.manifest' \
        \) \
        -print0
)

log "Generating sha256 checksums in $UPLOAD_DIR"

(
    cd "$UPLOAD_DIR"
    rm -f sha256sums
    sha256sum * > sha256sums
)

echo
echo "Upload directory contents:"
ls -lh "$UPLOAD_DIR"

# ============================================================
# Done
# ============================================================

log "Build and copy completed"

echo "ImageBuilder archive:"
echo "  $IB_ARCHIVE"

echo
echo "Extracted ImageBuilder:"
echo "  $IMAGEBUILDER_DIR"

echo
echo "MINI package list:"
echo "  $MINI_PACKAGES"

echo
echo "FULL package list:"
echo "  $FULL_PACKAGES"

echo
echo "MINI firmware:"
echo "  $MINI_BIN_DIR"

echo
echo "FULL firmware:"
echo "  $FULL_BIN_DIR"

echo
echo "Local upload directory:"
echo "  $UPLOAD_DIR"
