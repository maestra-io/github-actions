#!/usr/bin/env bash
#
# Point npm lockfiles at nora (packages.maestra.io) for the move off Artifactory
# (issues-maestra#1442):
#   https://artifactory.mindbox.ru/artifactory/api/npm/<repo>/@s/p/-/@s/p-1.0.0.tgz
#   -> https://packages.maestra.io/npm/@s/p/-/p-1.0.0.tgz
# Artifactory locals serve scoped tarballs as /-/@scope/name-ver.tgz, nora (like
# npmjs) as /-/name-ver.tgz, so both the prefix and that segment change. npm's
# `replace-registry-host` cannot do this: it keeps the old path. registry.npmjs.org
# URLs go to nora too: npm 11's `replace-registry-host=npmjs` drops nora's /npm/ for
# names starting with `npm` (npm-run-path -> packages.maestra.io/npm-run-path/..., 404).
# `integrity` is untouched: the imported tarballs are byte-identical. Idempotent.
#
# Usage: npm-lockfile-to-nora.sh [lockfile...]
#   default: every package-lock.json / npm-shrinkwrap.json outside node_modules.
#   NORA_NPM_URL overrides the target (default https://packages.maestra.io/npm/).
set -euo pipefail

nora="${NORA_NPM_URL:-https://packages.maestra.io/npm/}"
nora="${nora%/}/"
nora_re=$(printf '%s' "$nora" | sed 's/[.[\*^$/]/\\&/g')

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find . \( -path ./.git -o -name node_modules \) -prune -o -type f \
          \( -name package-lock.json -o -name npm-shrinkwrap.json \) -print0)
fi

for f in "${files[@]}"; do
  sed -i.bak -E \
    -e "s#(\"resolved\": *\")https://artifactory\.mindbox\.ru/artifactory/api/npm/[^/\"]+/#\1${nora}#g" \
    -e "s#(\"resolved\": *\"${nora_re}@[^/\"]+/[^/\"]+/-/)@[^/\"]+/#\1#g" \
    -e "s#(\"resolved\": *\")https://registry\.npmjs\.org/#\1${nora}#g" \
    "$f"
  if cmp -s "$f" "$f.bak"; then echo "unchanged: $f"; else echo "fixed:     $f"; fi
  rm -f "$f.bak"
  grep -n 'artifactory\.mindbox\.ru' "$f" | sed "s#^#still on Artifactory (fix by hand): $f:#" || true
done
