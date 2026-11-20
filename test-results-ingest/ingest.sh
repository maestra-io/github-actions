#!/usr/bin/env bash
# ingest.sh: TRX / JUnit files under RESULTS -> JSONL rows -> ci-telemetry VictoriaLogs.
#
# Env: RESULTS (a directory or one file), TEST_RESULTS_JOB_SUFFIX (optional), the job's
# ACTIONS_ID_TOKEN_REQUEST_URL / _TOKEN (`id-token: write`), RUNNER_TEMP. Overridable for the
# test (scripts/test-test-results-ingest.sh, stub curl): VAULT_URL, VAULT_ROLE, VAULT_SECRET,
# INGEST_URL, OIDC_AUDIENCE.
#
# Telemetry, called with `continue-on-error: true`: it must never hold a build up. Every network
# call is bounded. The converter runs first, so no results means no Vault call at all. Then the
# bearer comes from Vault (jwt-github login, KV v2 read) through curl with a short connect
# timeout, not hashicorp/vault-action: that one has no connect timeout, and the kernel's SYN
# retries took 136 s on the critical path of frontend-mailings release 44571546791 (19.11.2026,
# `connect ETIMEDOUT 23.81.164.132:443` while the runners could not reach the Leaseweb edge).
# Worst case now, edge unreachable: ~20 s to give up on Vault.
set -euo pipefail

VAULT_URL=${VAULT_URL:-https://vault.maestra.io}
VAULT_ROLE=${VAULT_ROLE:-ci-test-results-ingest}
VAULT_SECRET=${VAULT_SECRET:-gitlab/data/common/CI_TEST_RESULTS_TOKEN}
INGEST_URL=${INGEST_URL:-https://ci-telemetry.iota.maestra.io/ci/test-results}
OIDC_AUDIENCE=${OIDC_AUDIENCE:-https://github.com/maestra-io}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ -e "$RESULTS" ] || { echo "no $RESULTS: nothing to ingest"; exit 0; }
out="$RUNNER_TEMP/test-results-ingest"; rm -rf "$out"; mkdir -p "$out"
python3 -I "$here/test-results-to-jsonl.py" "$RESULTS" > "$out/rows.jsonl"
[ -s "$out/rows.jsonl" ] || { echo "no test results under $RESULTS"; exit 0; }

warn() { echo "::warning::test-results-ingest: $*; the results are not ingested (telemetry only, the build is unaffected)"; exit 1; }

# Vault and the ingest endpoint sit behind the same edge: 5 s to connect (a healthy connect from
# the runners takes well under 1 s), 3 tries. curl --retry covers connect timeouts, 408/429/5xx;
# --retry-connrefused adds a refused connect. A 4xx (role, policy) is not retried: it will not heal.
# --retry-max-time caps the retrying too: a 429/503 Retry-After replaces --retry-delay.
vault_curl=(curl -sS --fail-with-body --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 --retry-max-time 20 --retry-connrefused)

# fetch <curl argv...>: the response body on stdout only once curl succeeded. The body goes to a
# private file (-o, truncated before each retry), never a pipe: a failed attempt's body (an
# edge's HTML 503) would reach jq ahead of the retry's JSON.
body=$(mktemp "$out/body.XXXXXX")
trap 'rm -f "$body"' EXIT
fetch() {
  local rc=0
  "$@" -o "$body" || rc=$?
  [ "$rc" = 0 ] && cat "$body"
  : > "$body"
  return "$rc"
}

[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
  || warn "no ACTIONS_ID_TOKEN_REQUEST_URL / _TOKEN: the job needs \`permissions: id-token: write\`"
aud=$(jq -rn --arg a "$OIDC_AUDIENCE" '$a | @uri')
jwt=$(fetch curl -sS --fail-with-body --connect-timeout 10 --max-time 20 --retry 2 --retry-max-time 40 --retry-connrefused \
  -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$aud" \
  | jq -er '.value') || warn "no GitHub OIDC token"
echo "::add-mask::$jwt"

vault_token=$(jq -cn --arg r "$VAULT_ROLE" --arg j "$jwt" '{role: $r, jwt: $j}' \
  | fetch "${vault_curl[@]}" -X POST -H 'Content-Type: application/json' --data-binary @- \
    "$VAULT_URL/v1/auth/jwt-github/login" \
  | jq -er '.auth.client_token') || warn "Vault login as $VAULT_ROLE at $VAULT_URL failed"
echo "::add-mask::$vault_token"
CI_TEST_RESULTS_TOKEN=$(fetch "${vault_curl[@]}" -H "X-Vault-Token: $vault_token" "$VAULT_URL/v1/$VAULT_SECRET" \
  | jq -er '.data.data.value') || warn "Vault did not return $VAULT_SECRET"
echo "::add-mask::$CI_TEST_RESULTS_TOKEN"
unset jwt vault_token

# The ingress caps a body at 16 MiB: DirectCRM's shards are ~50k rows a job.
# gzip to a file, not a pipe: curl cannot --retry a body read from stdin.
split -C 4m -d "$out/rows.jsonl" "$out/chunk-"
for c in "$out"/chunk-*; do
  gzip -c "$c" > "$c.gz"
  curl -sS --fail-with-body --connect-timeout 10 --max-time 60 --retry 3 --retry-all-errors --retry-max-time 120 \
    -H "Authorization: Bearer $CI_TEST_RESULTS_TOKEN" -H 'Content-Type: application/stream+json' \
    -H 'Content-Encoding: gzip' --data-binary "@$c.gz" "$INGEST_URL" \
    || warn "POST $INGEST_URL failed for ${c##*/}"
done
chunks=("$out"/chunk-*.gz)
echo "ingested $(($(wc -l < "$out/rows.jsonl"))) rows (${#chunks[@]} requests)"
