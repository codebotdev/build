#!/usr/bin/env bash
set -Eeuo pipefail
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add projects.json README.md
if git diff --cached --quiet; then
    exit 0
fi
git commit -m "docs: update ${PROJECT} download catalog [skip ci]"
git push origin "HEAD:refs/heads/${CATALOG_BRANCH}"
