#!/usr/bin/env bash
# Shared by the generic build and R2 upload scripts.

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n========== %s ==========\n' "$*"; }

config_path() {
    local path
    path=$(realpath -e -- "$SOURCE_DIR/$1") || die "Config not found: $1"
    [[ "$path" == "$SOURCE_DIR/"* && -f "$path" ]] || die "Config must be a file inside the source tree: $1"
    printf '%s\n' "$path"
}

# Last occurrence wins, including '# CONFIG_FOO is not set'. Device choices
# override the optional extra config without duplicate-symbol warnings.
merge_configs() {
    awk '
        {
            lines[NR] = $0
            key = ""
            if ($0 ~ /^CONFIG_[A-Za-z0-9_]+=/) { key = $0; sub(/=.*/, "", key) }
            if ($0 ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) key = $2
            if (key != "") { keys[NR] = key; last[key] = NR }
        }
        END { for (i = 1; i <= NR; i++) if (keys[i] == "" || last[keys[i]] == i) print lines[i] }
    ' "$@"
}

read_build_metadata() {
    local values
    values=$(make -C "$SOURCE_DIR" --no-print-directory -s \
        val.BOARD val.SUBTARGET val.STAGING_DIR val.ARCH_PACKAGES)
    local -a fields
    mapfile -t fields <<< "$values"
    [[ ${#fields[@]} == 4 ]] || die "Cannot read target metadata"
    BOARD=${fields[0]}
    SUBTARGET=${fields[1]}
    STAGING_DIR=${fields[2]}
    ARCH_PACKAGES=${fields[3]}
    [[ "$STAGING_DIR" == /* ]] || STAGING_DIR="$SOURCE_DIR/$STAGING_DIR"

    # VERSION_DIST is the source for DISTRIB_ID in /etc/openwrt_release.
    # Make expands these expressions, not Bash.
    # shellcheck disable=SC2016
    values=$(make -C "$SOURCE_DIR" --no-print-directory -s -f /dev/null \
        --eval "TOPDIR:=$SOURCE_DIR" \
        --eval 'include $(TOPDIR)/rules.mk' \
        --eval 'include $(INCLUDE_DIR)/version.mk' \
        --eval 'print-build-metadata:;@printf "%s\n" "$(VERSION_NUMBER)" "$(VERSION_DIST)"' \
        print-build-metadata)
    mapfile -t fields <<< "$values"
    [[ ${#fields[@]} == 2 ]] || die "Cannot read firmware version/distribution"
    VERSION_NUMBER=${fields[0]}
    DISTRIB_ID=${fields[1]}
    REPO_PREFIX=$(printf '%s' "$DISTRIB_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
    local value
    for value in "$BOARD" "$SUBTARGET" "$ARCH_PACKAGES" "$VERSION_NUMBER" "$REPO_PREFIX"; do
        [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$value" != '..' ]] || die "Invalid repository path component: $value"
    done
    # Public value consumed by the build/upload entrypoints.
    # shellcheck disable=SC2034
    TARGET_OUTPUT_DIR="$SOURCE_DIR/bin/targets/$BOARD/$SUBTARGET"
    log "$DISTRIB_ID $VERSION_NUMBER / $BOARD/$SUBTARGET / $ARCH_PACKAGES"
}

read_profile() {
    local -a devices
    mapfile -t devices < <(sed -n "s/^CONFIG_TARGET_${BOARD}_${SUBTARGET}_DEVICE_\(.*\)=y$/\1/p" "$SOURCE_DIR/.config")
    if [[ ${#devices[@]} == 1 ]]; then
        PROFILE=${devices[0]}
    else
        PROFILE=$(sed -n 's/^CONFIG_TARGET_PROFILE="\(.*\)"$/\1/p' "$SOURCE_DIR/.config")
        PROFILE=${PROFILE#DEVICE_}
        [[ ${#devices[@]} == 0 && -n "$PROFILE" && "$PROFILE" != Default ]] || die "Select exactly one device/profile in the config"
    fi
    [[ "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid device profile: $PROFILE"
}

package_names() {
    sed 's/ - .*//' "$1" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u
}

generate_package_lists() {
    local manifest=$1 config=$2 ib=$3 merged_config=$4
    package_names "$manifest" | sed '/^\(base-files\|libc\|kernel\)$/d' > "$ib/mini.packages"
    [[ -s "$ib/mini.packages" ]] || die "Empty MINI package list"
    awk '/^Package:[[:space:]]+/ {print $2}' "$ib/.packageinfo" | sort -u > "$WORK_TMP/available"
    sed -n 's/^CONFIG_PACKAGE_\(.*\)=m$/\1/p' "$config" | sort -u > "$WORK_TMP/candidates"
    comm -12 "$WORK_TMP/candidates" "$WORK_TMP/available" > "$WORK_TMP/extra"
    comm -23 "$WORK_TMP/candidates" "$WORK_TMP/available" > "$WORK_TMP/unavailable"
    if [[ -s "$WORK_TMP/unavailable" ]]; then
        echo 'Ignoring module options that are not available packages:'
        cat "$WORK_TMP/unavailable"
    fi
    sed -n 's/^luci-\(app\|theme\|proto\)-\(.*\)/luci-i18n-\2-zh-cn/p' "$WORK_TMP/extra" | sort -u > "$WORK_TMP/i18n"
    comm -12 "$WORK_TMP/i18n" "$WORK_TMP/available" >> "$WORK_TMP/extra"
    cat "$ib/mini.packages" "$WORK_TMP/extra" | sed '/^\(base-files\|libc\|kernel\)$/d' | sort -u > "$ib/full.packages"

    # Explicit removals must also reach ImageBuilder (e.g. dnsmasq and wpad).
    sed -n 's/^# CONFIG_PACKAGE_\(.*\) is not set$/\1/p' "$merged_config" | sort -u > "$WORK_TMP/disabled"
    comm -12 "$WORK_TMP/disabled" "$WORK_TMP/available" | sed 's/^/-/' > "$ib/disabled.packages"
}

image_packages() {
    # Put removals first, followed by the requested package set.
    cat "$IMAGEBUILDER_DIR/disabled.packages" "$1" | tr '\n' ' '
}

firmware_files() {
    find "$@" -maxdepth 1 -type f \( \
        -name '*.bin' -o -name '*.itb' -o -name '*.img' -o -name '*.img.gz' \
        -o -name '*.img.zst' -o -name '*.ubi' -o -name '*.ubifs' \
        -o -name '*sysupgrade*.tar' -o -name '*.manifest' \) -print0
}
