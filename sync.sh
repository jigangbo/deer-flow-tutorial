#!/usr/bin/env bash
# Sync tutorial chapters from the authoring repo (deer-flow/docs/tutorials)
# into this standalone publishing repo.
#
# Usage:  ./sync.sh [source-dir]      (default: ../deer-flow/docs/tutorials)
#
# Synced:  chapters 00-20, appendices.md, index.md, .pages, javascripts/
# Kept local (not synced): root README.md, mkdocs.yml, workflow, this script
set -euo pipefail

SRC="${1:-../deer-flow/docs/tutorials}"
DST="$(cd "$(dirname "$0")" && pwd)/docs"

if [ ! -d "$SRC" ]; then
  echo "ERROR: source dir not found: $SRC" >&2
  exit 1
fi

for f in "$SRC"/*.md; do
  base="$(basename "$f")"
  # The authoring repo keeps its own README.md for in-repo navigation; skip it.
  if [ "$base" = "README.md" ]; then continue; fi
  cp "$f" "$DST/"
done

cp "$SRC/.pages" "$DST/.pages"
mkdir -p "$DST/javascripts"
cp "$SRC/javascripts/mathjax.js" "$DST/javascripts/mathjax.js"

echo "Synced from: $SRC"
echo "Next: review 'git diff', commit & push (GitHub Actions will redeploy)."
