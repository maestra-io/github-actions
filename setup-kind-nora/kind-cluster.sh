#!/usr/bin/env bash
# setup-kind-nora's last step (action.yml says why): the node image from nora by digest, then
# `kind create cluster` unless INPUT_INSTALL_ONLY. Env: NORA_URL, NORA_AUDIENCE, KIND_DEFAULT_IMAGE
# (versions.txt column 3, a Docker Hub reference), INPUT_*; the runner's
# ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nora-session/nora-session.sh"
fail() { echo "::error::setup-kind-nora: $*" >&2; exit 1; }

nora="${NORA_URL%/}"; host="${nora#*://}"; host="${host%%/*}"
[[ $nora == https://* ]] || fail "url '$nora' is not https"
image="${INPUT_NODE_IMAGE:-$host/docker-hub/${KIND_DEFAULT_IMAGE:?no default node image for this kind version in versions.txt}}"
# anything else is Docker Hub (or another registry) around nora
[[ $image == "$host/"* ]] || fail "node_image '$image' is not a $host/… reference"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"

# Pulled with a 0600 throwaway copy of the job's docker config plus the nora credential (never
# ~/.docker, argv or env), so kind and the job's later steps find it locally.
token=$(nora_token "$nora" "$NORA_AUDIENCE") || fail "no nora token from $nora"
echo "::add-mask::$token"
cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
src="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
[ -s "$src" ] || src=/dev/null
( umask 077; printf 'token:%s' "$token" | base64 | tr -d '\n' \
  | jq -Rn --arg h "$host" --slurpfile c "$src" \
      '($c[0] // {}) | .auths[$h] = {auth: input} | .credHelpers[$h] = ""' > "$cfg/config.json" )
DOCKER_CONFIG="$cfg" docker pull --quiet "$image" >/dev/null || fail "docker pull $image failed"
echo "setup-kind-nora: node image $image from nora"
echo "KIND_NODE_IMAGE=$image" >> "$GITHUB_ENV"
echo "node-image=$image" >> "$GITHUB_OUTPUT"

[ "${INPUT_INSTALL_ONLY:-false}" != true ] || exit 0
args=(create cluster --name "${INPUT_CLUSTER_NAME:-chart-testing}" --image "$image" --wait "${INPUT_WAIT:-60s}")
[ -z "${INPUT_CONFIG:-}" ] || args+=(--config "$INPUT_CONFIG")
kind "${args[@]}"
kubectl cluster-info
