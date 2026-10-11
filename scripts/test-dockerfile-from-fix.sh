#!/usr/bin/env bash
# Self-check for dockerfile-from-fix.sh: rewrite, keep, idempotence.
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
echo "dockerfile-from-fix: OK"
