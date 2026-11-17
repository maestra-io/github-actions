#!/usr/bin/env bash
# security-scan/trivy-nora-env.sh with a stub `curl` on PATH: the session token lands only in
# a 0600 docker config and a 0600 maven settings.xml (masked in the log), GITHUB_ENV points
# DOCKER_CONFIG, MAVEN_HOME and trivy's DB repositories at nora; no id-token fails the step.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../security-scan/trivy-nora-env.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "${*: -1}" == https://packages.maestra.io/api/oidc/session ]]; then
  printf '{"token":"nrs_1_stub","expires_in":3600}\n200'; exit 0
fi
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"
fail() { echo "FAIL: $*" >&2; exit 1; }
env -i PATH="$root/bin:$PATH" GITHUB_ENV="$root/env" ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?a=1' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=req bash "$script" "$root/docker" > "$root/log" 2>&1 || fail "run: $(cat "$root/log")"
grep -qxF '::add-mask::nrs_1_stub' "$root/log" || fail "token not masked"
! grep -q 'nrs_1_stub' "$root/env" || fail "token in GITHUB_ENV"
[ "$(stat -c %a "$root/docker/config.json" 2>/dev/null || stat -f %Lp "$root/docker/config.json")" = 600 ] || fail "config not 0600"
[ "$(jq -r '.auths["packages.maestra.io"].auth' "$root/docker/config.json" | base64 -d)" = "token:nrs_1_stub" ] || fail "auth entry"
[ "$(jq -r '.credHelpers["packages.maestra.io"]' "$root/docker/config.json")" = "" ] || fail "credHelpers override"
x="$root/docker/maven/conf/settings.xml"
[ "$(stat -c %a "$x" 2>/dev/null || stat -f %Lp "$x")" = 600 ] || fail "settings.xml not 0600"
grep -qF '<password>nrs_1_stub</password>' "$x" || fail "settings.xml credential"
grep -qF '<url>https://packages.maestra.io/maven2/</url><mirrorOf>*</mirrorOf>' "$x" || fail "settings.xml mirror"
for kv in "DOCKER_CONFIG=$root/docker" "MAVEN_HOME=$root/docker/maven" TRIVY_SKIP_VERSION_CHECK=true TRIVY_DB_REPOSITORY=packages.maestra.io/ghcr/aquasecurity/trivy-db:2 \
  TRIVY_JAVA_DB_REPOSITORY=packages.maestra.io/ghcr/aquasecurity/trivy-java-db:1 \
  TRIVY_CHECKS_BUNDLE_REPOSITORY=packages.maestra.io/ghcr/aquasecurity/trivy-checks:2; do
  grep -qxF "$kv" "$root/env" || fail "GITHUB_ENV lacks $kv"
done
! env -i PATH="$root/bin:$PATH" GITHUB_ENV="$root/env2" bash "$script" "$root/d2" > "$root/log2" 2>&1 || fail "ran without id-token"
echo "trivy-nora-env ok"
