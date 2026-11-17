#!/usr/bin/env bash
# A dependency container from a packages.maestra.io image (action.yml says why). Env: the
# action's INPUT_IMAGE, _NAME, _PORTS, _ENV, _OPTIONS, _TIMEOUT, _URL, _AUDIENCE; the runner's
# ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}, GITHUB_OUTPUT, GITHUB_STATE. Writes output and state
# `id` (post.js removes the container by it) as soon as the container exists.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nora-session/nora-session.sh"

image="${INPUT_IMAGE:-}"
nora="${INPUT_URL%/}"; host="${nora#*://}"; host="${host%%/*}"
[[ "$image" == "$host"/*:*@sha256:* ]] || {
  echo "::error::nora-service: image must be $host/<path>:<tag>@sha256:<digest>, got '$image'"; exit 1; }
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"

# The token lives in a 0600 docker config used for this one pull: never in ~/.docker, argv or env.
cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
token=$(nora_token "$nora" "$INPUT_AUDIENCE") || { echo "::error::nora-service: no nora token from $nora"; exit 1; }
echo "::add-mask::$token"
( umask 077; printf 'token:%s' "$token" | base64 | tr -d '\n' \
  | jq -Rn --arg h "$host" '{auths: {($h): {auth: input}}}' > "$cfg/config.json" )
DOCKER_CONFIG="$cfg" docker pull -q "$image"

args=(-d --pull never --label maestra.nora-service=1)
[ -z "${INPUT_NAME:-}" ] || args+=(--name "$INPUT_NAME")
while read -r l; do [ -z "$l" ] || args+=(-p "$l"); done <<< "${INPUT_PORTS:-}"
while read -r l; do [ -z "$l" ] || args+=(-e "$l"); done <<< "${INPUT_ENV:-}"
# xargs splits the shell-quoted flags as a shell would, without eval; empty would give one "".
if [ -n "${INPUT_OPTIONS//[[:space:]]/}" ]; then
  readarray -d '' opts < <(xargs printf '%s\0' <<< "$INPUT_OPTIONS")
  args+=("${opts[@]}")
fi
cid=$(docker run "${args[@]}" "$image")
echo "id=$cid" >> "$GITHUB_STATE"
echo "id=$cid" >> "$GITHUB_OUTPUT"

timeout="${INPUT_TIMEOUT:-180}" state=
for ((i = 0; i <= timeout; i++)); do
  read -r state health < <(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid") || state=gone
  case "$state/${health:-none}" in
    running/healthy|running/none) echo "nora-service: $image up, id $cid"; exit 0 ;;
    running/starting) sleep 1 ;;
    *) break ;; # exited, dead, unhealthy
  esac
done
docker logs --tail 50 "$cid" >&2 || true
echo "::error::nora-service: $image not ready after ${timeout}s: ${state:-?}/${health:-none}"
exit 1
