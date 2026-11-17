#!/usr/bin/env bash
# trivy-nora-env.sh <dir>: the rest of the job's trivy runs fetch nothing around nora
# (issues-maestra#1649), as trivy-nora/ does for the DBs: the vulnerability, Java and checks DBs
# from nora's ghcr proxy, and the POMs a pom.xml scan resolves from nora's maven2 proxy (a global
# settings.xml mirroring every repository; Maven Central also answers the shared runner IPs with
# 429 and fails the scan), and no version check. A nora session token sits only in 0600 files
# under <dir>; DOCKER_CONFIG, MAVEN_HOME and TRIVY_* go to GITHUB_ENV. Needs id-token: write.
# The job runs no other docker or maven client.
set -euo pipefail
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nora-session/nora-session.sh"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
dir=${1:?dir}
host=packages.maestra.io
token=$(nora_token "https://$host" "$host") || { echo "::error::trivy-nora-env: no nora token"; exit 1; }
echo "::add-mask::$token"
mkdir -p "$dir/maven/conf"
(
  umask 077
  printf 'token:%s' "$token" | base64 | tr -d '\n' \
    | jq -Rn --arg h "$host" '{auths: {($h): {auth: input}}, credHelpers: {($h): ""}}' > "$dir/config.json"
  cat > "$dir/maven/conf/settings.xml" <<XML
<settings>
  <servers><server><id>nora</id><username>token</username><password>${token}</password></server></servers>
  <mirrors><mirror><id>nora</id><url>https://${host}/maven2/</url><mirrorOf>*</mirrorOf></mirror></mirrors>
</settings>
XML
)
{
  echo "DOCKER_CONFIG=$dir"
  echo "MAVEN_HOME=$dir/maven"
  echo "TRIVY_DB_REPOSITORY=$host/ghcr/aquasecurity/trivy-db:2"
  echo "TRIVY_JAVA_DB_REPOSITORY=$host/ghcr/aquasecurity/trivy-java-db:1"
  echo "TRIVY_CHECKS_BUNDLE_REPOSITORY=$host/ghcr/aquasecurity/trivy-checks:2"
  echo "TRIVY_SKIP_VERSION_CHECK=true"
} >> "$GITHUB_ENV"
echo "trivy: DBs from $host/ghcr/aquasecurity, POMs from $host/maven2 (nora)"
