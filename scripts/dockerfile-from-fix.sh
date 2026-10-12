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
# Idempotent: a second run changes nothing. Edits go through a temp file in the
# file's own directory + mv (mode and CRLF kept); no `<file>.bak` is ever
# written or removed, and committed `*.bak` files are not discovered.
#
# Usage: dockerfile-from-fix.sh [file...]   (default: every Dockerfile* in the tree)
set -euo pipefail

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find . -path ./.git -prune -o -type f \( -name 'Dockerfile*' -o -name '*.Dockerfile' \) ! -name '*.bak' -print0)
fi

tmp=""
trap 'rm -f "$tmp"' EXIT
for f in "${files[@]}"; do
  tmp="$(mktemp "$(dirname "$f")/.dockerfile-from-fix.XXXXXX")"
  cp -p "$f" "$tmp" # mode/owner of the original; content is overwritten below
  # FROM [--platform=...] cr.yandex/crp2cvbrp76d7dmfegco/<image> -> FROM ... <image>
  sed -E 's#^([[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*)cr\.yandex/crp2cvbrp76d7dmfegco/#\1#I' "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then
    echo "unchanged: $f"; rm -f "$tmp"
  else
    mv -f "$tmp" "$f"; echo "fixed:     $f"
  fi
  tmp=""
  grep -nE 'cr\.yandex/' "$f" | sed "s#^#still on cr.yandex (fix by hand): $f:#" || true
done
