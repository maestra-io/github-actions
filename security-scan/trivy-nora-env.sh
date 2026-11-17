#!/usr/bin/env bash
# trivy-nora-env.sh <dir>: the rest of the job's trivy runs take their vulnerability, Java and
# checks DBs from nora's ghcr proxy, as trivy-nora/ does (issues-maestra#1649): a nora session
# token in a 0600 docker config under <dir>, and DOCKER_CONFIG / TRIVY_*_REPOSITORY appended to
# GITHUB_ENV. Needs id-token: write. The job runs no other docker client.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nora-session/nora-session.sh"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
dir=${1:?dir}
host=packages.maestra.io
token=$(nora_token "https://$host" "$host") || { echo "::error::trivy-nora-env: no nora token"; exit 1; }
echo "::add-mask::$token"
mkdir -p "$dir"
( umask 077; printf 'token:%s' "$token" | base64 | tr -d '\n' \
  | jq -Rn --arg h "$host" '{auths: {($h): {auth: input}}, credHelpers: {($h): ""}}' > "$dir/config.json" )
{
  echo "DOCKER_CONFIG=$dir"
  echo "TRIVY_DB_REPOSITORY=$host/ghcr/aquasecurity/trivy-db:2"
  echo "TRIVY_JAVA_DB_REPOSITORY=$host/ghcr/aquasecurity/trivy-java-db:1"
  echo "TRIVY_CHECKS_BUNDLE_REPOSITORY=$host/ghcr/aquasecurity/trivy-checks:2"
} >> "$GITHUB_ENV"
echo "trivy DBs from $host/ghcr/aquasecurity (nora)"
