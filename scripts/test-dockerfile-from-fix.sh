#!/usr/bin/env bash
# Self-check for dockerfile-from-fix.sh: rewrite, keep, idempotence, and a
# committed Dockerfile.bak left byte-identical (it used to be overwritten by
# `sed -i.bak` and then deleted).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cat > "$d/Dockerfile" <<'DF'
FROM cr.yandex/crp2cvbrp76d7dmfegco/mcr.microsoft.com/dotnet/sdk:10.0 as build
from --platform=linux/amd64 cr.yandex/crp2cvbrp76d7dmfegco/docker.io/library/node:22-slim AS web
FROM cr.yandex/crpcl8cpek7o88jk1vg7/dind-dotnet-sdk-10
FROM build AS tests
RUN echo cr.yandex/crp2cvbrp76d7dmfegco/keep-me-in-run
DF
cat > "$d/want" <<'DF'
FROM mcr.microsoft.com/dotnet/sdk:10.0 as build
from --platform=linux/amd64 docker.io/library/node:22-slim AS web
FROM cr.yandex/crpcl8cpek7o88jk1vg7/dind-dotnet-sdk-10
FROM build AS tests
RUN echo cr.yandex/crp2cvbrp76d7dmfegco/keep-me-in-run
DF
"$here/dockerfile-from-fix.sh" "$d/Dockerfile" >/dev/null
diff -u "$d/want" "$d/Dockerfile"
"$here/dockerfile-from-fix.sh" "$d/Dockerfile" | grep -q '^unchanged:'
diff -u "$d/want" "$d/Dockerfile"

# Regression: committed Dockerfile.bak next to Dockerfile, default discovery.
r="$d/repo"; mkdir "$r"
printf 'FROM cr.yandex/crp2cvbrp76d7dmfegco/mcr.microsoft.com/dotnet/aspnet:8.0\r\nRUN true\r\n' > "$r/Dockerfile"
chmod 0755 "$r/Dockerfile"
printf 'FROM cr.yandex/crp2cvbrp76d7dmfegco/old-base:1\nRUN echo committed backup\n' > "$r/Dockerfile.bak"
cp -p "$r/Dockerfile.bak" "$d/bak.orig"
(cd "$r" && "$here/dockerfile-from-fix.sh" >/dev/null)
cmp "$d/bak.orig" "$r/Dockerfile.bak"
printf 'FROM mcr.microsoft.com/dotnet/aspnet:8.0\r\nRUN true\r\n' | cmp - "$r/Dockerfile"
[ -x "$r/Dockerfile" ] || { echo "mode lost on Dockerfile" >&2; exit 1; }
[ "$(ls -A "$r" | sort | tr '\n' ' ')" = "Dockerfile Dockerfile.bak " ] || { ls -A "$r" >&2; exit 1; }
echo "dockerfile-from-fix: OK"
