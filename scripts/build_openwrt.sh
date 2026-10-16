#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/openwrt-common.sh
source "$SCRIPT_DIR/openwrt-common.sh"

SOURCE_DIR=$(realpath -e "${SOURCE_DIR:-/build/source}")
IMAGEBUILDER_DIR=$(realpath -m "${IMAGEBUILDER_DIR:-/build/imagebuilder}")
UPLOAD_DIR=$(realpath -m "${UPLOAD_DIR:-/upload}")
CONFIG_NAME=${CONFIG_NAME:-jdcloud_ax3000.config}
EXTRA_CONFIG_NAME=${EXTRA_CONFIG_NAME-kmods.config}
JOBS=${JOBS:-$(nproc)}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Invalid JOBS: $JOBS"
[[ "$IMAGEBUILDER_DIR" != / && "$IMAGEBUILDER_DIR" != /build && "$IMAGEBUILDER_DIR" != "$SOURCE_DIR" && "$SOURCE_DIR" != "$IMAGEBUILDER_DIR/"* && "$IMAGEBUILDER_DIR" != "$SOURCE_DIR/"* ]] || die 'Unsafe ImageBuilder directory'
[[ "$UPLOAD_DIR" != "$IMAGEBUILDER_DIR" && "$UPLOAD_DIR" != "$IMAGEBUILDER_DIR/"* ]] || die 'Upload directory must be outside ImageBuilder'
CONFIG_FILE=$(config_path "$CONFIG_NAME")
EXTRA_CONFIG_FILE=''
[[ -z "$EXTRA_CONFIG_NAME" ]] || EXTRA_CONFIG_FILE=$(config_path "$EXTRA_CONFIG_NAME")
WORK_TMP=$(mktemp -d)
trap 'rm -rf -- "$WORK_TMP"' EXIT
mkdir -p "$IMAGEBUILDER_DIR" "$UPLOAD_DIR"
cd "$SOURCE_DIR"

log 'Updating feeds'
./scripts/feeds update -a
# Some source trees use a feed patch helper; others use package.mk hooks.
if [[ -f scripts/apply-feed-patches.sh ]]; then
    bash ./scripts/apply-feed-patches.sh
fi
./scripts/feeds install -a

log 'Merging configs (device config overrides extra config)'
configs=()
[[ -z "$EXTRA_CONFIG_FILE" ]] || configs+=("$EXTRA_CONFIG_FILE")
configs+=("$CONFIG_FILE")
merge_configs "${configs[@]}" > "$WORK_TMP/merged.config"
cp "$WORK_TMP/merged.config" .config
make defconfig
grep -qx 'CONFIG_IB=y' .config || die 'Enable CONFIG_IB=y in the device config'
grep -qx 'CONFIG_IB_STANDALONE=y' .config || die 'Enable CONFIG_IB_STANDALONE=y in the device config'
read_build_metadata
read_profile
echo "Device profile: $PROFILE"

log "Downloading and building firmware/packages (-j$JOBS)"
make download -j"$JOBS"
make -j"$JOBS" world
log 'Rebuilding Standalone ImageBuilder with the complete package repository'
make target/imagebuilder/clean
make -j1 target/imagebuilder/compile

mapfile -t archives < <(find "$TARGET_OUTPUT_DIR" -maxdepth 1 -type f \
    \( -name '*imagebuilder*.tar.zst' -o -name '*imagebuilder*.tar.xz' -o -name '*imagebuilder*.tar.gz' \) | sort)
[[ ${#archives[@]} == 1 ]] || die 'Expected exactly one ImageBuilder archive'
IB_ARCHIVE=${archives[0]}
mapfile -t manifests < <(find "$TARGET_OUTPUT_DIR" -maxdepth 1 -type f -name "*-${PROFILE}.manifest" | sort)
[[ ${#manifests[@]} == 1 ]] || die "Expected exactly one source manifest for $PROFILE"
SRC_MANIFEST=${manifests[0]}

log 'Extracting Standalone ImageBuilder'
mkdir "$WORK_TMP/extract"
tar -xaf "$IB_ARCHIVE" -C "$WORK_TMP/extract"
mapfile -d '' -t entries < <(find "$WORK_TMP/extract" -mindepth 1 -maxdepth 1 -print0)
EXTRACTED_ROOT="$WORK_TMP/extract"
if [[ ${#entries[@]} == 1 && -d "${entries[0]}" && -f "${entries[0]}/Makefile" ]]; then
    EXTRACTED_ROOT=${entries[0]}
fi
[[ -f "$EXTRACTED_ROOT/Makefile" && -f "$EXTRACTED_ROOT/.packageinfo" && -d "$EXTRACTED_ROOT/packages" ]] || die 'Invalid Standalone ImageBuilder'
[[ -n $(find "$EXTRACTED_ROOT/packages" -type f \( -name '*.apk' -o -name '*.ipk' \) -print -quit) ]] || die 'ImageBuilder contains no packages'
find "$IMAGEBUILDER_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$EXTRACTED_ROOT/." "$IMAGEBUILDER_DIR/"
generate_package_lists "$SRC_MANIFEST" "$CONFIG_FILE" "$IMAGEBUILDER_DIR" "$WORK_TMP/merged.config"

cd "$IMAGEBUILDER_DIR"
BUILD_MINI=false
if ! cmp -s mini.packages full.packages; then
    # Resolve dependencies before deciding whether two firmware images are
    # needed. Optional modules can already be dependencies of MINI packages.
    log 'Comparing resolved MINI/FULL package sets'
    make --no-print-directory -s manifest PROFILE="$PROFILE" \
        PACKAGES="$(image_packages mini.packages)" > "$WORK_TMP/mini.resolved"
    make --no-print-directory -s manifest PROFILE="$PROFILE" \
        PACKAGES="$(image_packages full.packages)" > "$WORK_TMP/full.resolved"
    for variant in mini full; do
        # Ignore informational output; retain the package name and version.
        sed -n '/^[A-Za-z0-9][A-Za-z0-9+_.-]* - /p' "$WORK_TMP/$variant.resolved" | sort -u > "$WORK_TMP/$variant.compare"
        [[ -s "$WORK_TMP/$variant.compare" ]] || die "Cannot read resolved $variant manifest"
    done
    cmp -s "$WORK_TMP/mini.compare" "$WORK_TMP/full.compare" || BUILD_MINI=true
fi

BIN_DIRS=()
if [[ "$BUILD_MINI" == true ]]; then
    log 'Building MINI firmware'
    MINI_BIN_DIR="$IMAGEBUILDER_DIR/bin/mini"
    rm -rf "$MINI_BIN_DIR"
    make image PROFILE="$PROFILE" PACKAGES="$(image_packages mini.packages)" \
        EXTRA_IMAGE_NAME=mini BIN_DIR="$MINI_BIN_DIR"
    BIN_DIRS+=("$MINI_BIN_DIR")
else
    log 'MINI and FULL are identical; building one firmware without mini suffix'
fi
log 'Building FULL firmware'
FULL_BIN_DIR="$IMAGEBUILDER_DIR/bin/full"
rm -rf "$FULL_BIN_DIR"
make image PROFILE="$PROFILE" PACKAGES="$(image_packages full.packages)" \
    EXTRA_IMAGE_NAME= BIN_DIR="$FULL_BIN_DIR"
BIN_DIRS+=("$FULL_BIN_DIR")

for dir in "${BIN_DIRS[@]}"; do
    [[ -n $(find "$dir" -maxdepth 1 -type f -name '*.manifest' -print -quit) ]] || die "Missing firmware manifest in $dir"
    has_image=false
    while IFS= read -r -d '' artifact; do
        [[ "$artifact" == *.manifest ]] || has_image=true
    done < <(firmware_files "$dir")
    [[ "$has_image" == true ]] || die "No supported firmware images in $dir"
done

VERIFY_DIR="$FULL_BIN_DIR"
[[ "$BUILD_MINI" != true ]] || VERIFY_DIR="$MINI_BIN_DIR"
mapfile -t verify_manifests < <(find "$VERIFY_DIR" -maxdepth 1 -type f -name '*.manifest' | sort)
[[ ${#verify_manifests[@]} == 1 ]] || die 'Expected one generated manifest for the selected profile'
package_names "$SRC_MANIFEST" > "$WORK_TMP/source.packages"
package_names "${verify_manifests[0]}" > "$WORK_TMP/generated.packages"
if ! cmp -s "$WORK_TMP/source.packages" "$WORK_TMP/generated.packages"; then
    echo 'WARNING: Generated base package set differs from the source firmware:'
    comm -3 "$WORK_TMP/source.packages" "$WORK_TMP/generated.packages"
fi

log 'Collecting build artifacts'
cp -f "$IB_ARCHIVE" "$UPLOAD_DIR/"
while IFS= read -r -d '' artifact; do
    cp -f "$artifact" "$UPLOAD_DIR/"
done < <(firmware_files "${BIN_DIRS[@]}")
(
    cd "$UPLOAD_DIR"
    rm -f sha256sums
    sha256sum -- * > sha256sums
)
ls -lh "$UPLOAD_DIR"

# The workflow reuses exactly the detected distribution and profile in Release.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'distribution=%s\nprofile=%s\nversion=%s\n' "$REPO_PREFIX" "$PROFILE" "$VERSION_NUMBER" >> "$GITHUB_OUTPUT"
fi
