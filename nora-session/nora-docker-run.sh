#!/usr/bin/env bash
# `docker run` of a packages.maestra.io image over the workspace, as a `runs: using: docker`
# action runs its image, but pulled through nora (issues-maestra#1649): the runner pulls a
# docker action's image in "Set up job", before any step could log in to nora.
# Usage: nora-docker-run.sh <image> [args...]; `-e NAME` style options go in IMAGE_ENV
# (names exported in the step's env). Needs `permissions: id-token: write`.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/nora-session.sh"
nora="${NORA_URL:-https://packages.maestra.io}" aud="${NORA_AUDIENCE:-packages.maestra.io}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
# A throwaway docker config: the caller's ~/.docker/config.json (cred helpers, ECR) stays as it was.
DOCKER_CONFIG=$(mktemp -d); export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
token=$(nora_token "$nora" "$aud")
echo "::add-mask::$token"
host="${nora#*://}"; host="${host%%/*}"
printf '%s' "$token" | docker login "$host" -u token --password-stdin >/dev/null
docker pull "$1"
env_args=()
for n in ${IMAGE_ENV:-}; do env_args+=(-e "$n"); done
docker run --rm -v "${GITHUB_WORKSPACE:-$PWD}:/github/workspace" -w /github/workspace "${env_args[@]}" "$@"
