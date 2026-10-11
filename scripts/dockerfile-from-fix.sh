#!/usr/bin/env bash
#
# Drop the Yandex mirror prefix from Dockerfile base images for the move to
# GitHub Actions on RunsOn (issues-maestra#1442):
#   FROM cr.yandex/crp2cvbrp76d7dmfegco/mcr.microsoft.com/dotnet/sdk:10.0
#   -> FROM mcr.microsoft.com/dotnet/sdk:10.0
# mcr.microsoft.com is pulled directly; docker.io/... goes through RunsOn's ECR
# pull-through cache transparently, so neither needs a mirror path. Only the
# crp2cvbrp76d7dmfegco (public-registry mirror) prefix is removed; images from
# Mindbox's own crpcl8cpek7o88jk1vg7 registry are reported, not touched.
# Idempotent: a second run changes nothing.
#
# Usage: dockerfile-from-fix.sh [file...]   (default: every Dockerfile* in the tree)
set -euo pipefail

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find . -path ./.git -prune -o -type f \( -name 'Dockerfile*' -o -name '*.Dockerfile' \) -print0)
fi

for f in "${files[@]}"; do
  # FROM [--platform=...] cr.yandex/crp2cvbrp76d7dmfegco/<image> -> FROM ... <image>
  sed -i.bak -E 's#^([[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*)cr\.yandex/crp2cvbrp76d7dmfegco/#\1#I' "$f"
  if cmp -s "$f" "$f.bak"; then echo "unchanged: $f"; else echo "fixed:     $f"; fi
  rm -f "$f.bak"
  grep -nE 'cr\.yandex/' "$f" | sed "s#^#still on cr.yandex (fix by hand): $f:#" || true
done
