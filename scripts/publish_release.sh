#!/usr/bin/env bash
set -Eeuo pipefail
: "${PROJECT:?}" "${SOURCE_BRANCH:?}" "${SOURCE_DIR:?}" "${GITHUB_SHA:?}"
UPLOAD_DIR="${UPLOAD_DIR:-/upload}"
source_sha=$(git -C "$SOURCE_DIR" rev-parse HEAD)
branch_tag=$(printf '%s' "$SOURCE_BRANCH" | sed 's/[^A-Za-z0-9._-]/-/g')
# Immutable run-specific tags prevent mixed assets and ambiguous source metadata.
tag="${PROJECT}-${branch_tag}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mapfile -d '' upload_files < <(find "$UPLOAD_DIR" -maxdepth 1 -type f -print0)
if (( ${#upload_files[@]} == 0 )); then
    echo "No files to publish in $UPLOAD_DIR" >&2
    exit 1
fi
options=()
if [[ "${TEST_RELEASE:-false}" == true ]]; then
    options+=(--prerelease --latest=false)
fi
gh release create "$tag" "${upload_files[@]}" --target "$GITHUB_SHA" \
    --title "$tag" --notes "${PROJECT}: ${SOURCE_BRANCH}@${source_sha}" "${options[@]}"
printf 'tag=%s\ncommit=%s\n' "$tag" "$source_sha" >> "$GITHUB_OUTPUT"
