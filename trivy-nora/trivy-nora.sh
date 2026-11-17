#!/usr/bin/env bash
# trivy through nora (action.yml says why). Env: TRIVY_VERSION, TRIVY_SHA256, NORA_URL,
# NORA_AUDIENCE, the action's INPUT_*; RUNNER_TEMP and the runner's
# ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}. Exits with trivy's exit code.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nora-session/nora-session.sh"

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
nora="${NORA_URL%/}"; host="${nora#*://}"; host="${host%%/*}"
dir="${RUNNER_TEMP}/trivy-nora"
mkdir -p "$dir"
token=$(nora_token "$nora" "$NORA_AUDIENCE") || { echo "::error::trivy-nora: no nora token from $nora"; exit 1; }
echo "::add-mask::$token"

# Once per job: a second scan in the job reuses the binary and the DB in $dir/cache.
if [ "$("$dir/trivy" --version 2>/dev/null | head -1)" != "Version: ${TRIVY_VERSION}" ]; then
  tgz="$dir/trivy.tar.gz"
  printf 'user = "token:%s"\n' "$token" | curl -sfL --retry 5 --retry-delay 5 --retry-all-errors -K - -o "$tgz" \
    "${nora}/github/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
  echo "${TRIVY_SHA256}  ${tgz}" | sha256sum -c -
  tar -xzf "$tgz" -C "$dir" trivy
  rm -f "$tgz"
fi

# The DB pulls authenticate to nora from a 0600 copy of the job's docker config with the
# nora credential added (never ~/.docker, argv or env): the job's other registry logins
# (ECR for a published image) still apply to the scanned image. credHelpers[host] = ""
# makes docker's lookup take auths[host] even when the config names a credsStore.
cfg=$(mktemp -d); trap 'rm -rf "$cfg"' EXIT
src="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
[ -s "$src" ] || src=/dev/null
( umask 077; printf 'token:%s' "$token" | base64 | tr -d '\n' \
  | jq -Rn --arg h "$host" --slurpfile c "$src" \
      '($c[0] // {}) | .auths[$h] = {auth: input} | .credHelpers[$h] = ""' > "$cfg/config.json" )

export DOCKER_CONFIG="$cfg"
export TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-$dir/cache}"
export TRIVY_DB_REPOSITORY="${host}/ghcr/aquasecurity/trivy-db:2"
export TRIVY_JAVA_DB_REPOSITORY="${host}/ghcr/aquasecurity/trivy-java-db:1"
export TRIVY_CHECKS_BUNDLE_REPOSITORY="${host}/ghcr/aquasecurity/trivy-checks:2"
export TRIVY_DISABLE_VEX_NOTICE=true

# trivy-action's mapping: an empty input (or its default) leaves trivy's own default.
set_if() { if [ -n "$2" ] && [ "$2" != "${3:-}" ]; then export "$1=$2"; fi; }
set_if TRIVY_SEVERITY "${INPUT_SEVERITY:-}"
set_if TRIVY_EXIT_CODE "${INPUT_EXIT_CODE:-}"
set_if TRIVY_IGNORE_UNFIXED "${INPUT_IGNORE_UNFIXED:-}" false
set_if TRIVY_PKG_TYPES "${INPUT_VULN_TYPE:-}"
set_if TRIVY_SCANNERS "${INPUT_SCANNERS:-}"
set_if TRIVY_FORMAT "${INPUT_FORMAT:-}"
set_if TRIVY_OUTPUT "${INPUT_OUTPUT:-}"
set_if TRIVY_LIST_ALL_PKGS "${INPUT_LIST_ALL_PKGS:-}" false

if [ -n "${INPUT_TRIVYIGNORES:-}" ]; then
  IFS=, read -r -a ignores <<< "$INPUT_TRIVYIGNORES"
  for f in "${ignores[@]}"; do [ -f "$f" ] || { echo "::error::trivy-nora: no ignore file '$f'"; exit 1; }; done
  if [ "${#ignores[@]}" -eq 1 ] && [[ "${ignores[0]}" == *.y*ml ]]; then
    export TRIVY_IGNOREFILE="${ignores[0]}"
  else
    cat "${ignores[@]}" > "$dir/trivyignore"
    export TRIVY_IGNOREFILE="$dir/trivyignore"
  fi
fi

ref="${INPUT_IMAGE_REF:-${INPUT_SCAN_REF:-.}}"
echo "trivy ${TRIVY_VERSION} ${INPUT_SCAN_TYPE:-image} ${ref} (DB ${TRIVY_DB_REPOSITORY})"
rc=0
"$dir/trivy" "${INPUT_SCAN_TYPE:-image}" "$ref" || rc=$?
exit "$rc"
