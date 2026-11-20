#!/usr/bin/env bash
# Converter self-check, then ingest.sh with a stub curl (below): the two fixtures under test-results-ingest/testdata
# must yield 9 rows, 2 failed with a failure_hash, 2 skipped, no doubled class prefix (xunit TRX), and the GitHub context on each row.
set -euo pipefail
cd "$(dirname "$0")/.."
act=test-results-ingest
rows=$(GITHUB_HEAD_REF= GITHUB_REPOSITORY=maestra-io/x GITHUB_WORKFLOW=w GITHUB_JOB=j TEST_RESULTS_JOB_SUFFIX=-leg GITHUB_RUN_ID=1 \
  GITHUB_RUN_ATTEMPT=2 GITHUB_SHA=abc GITHUB_REF_NAME=main GITHUB_EVENT_NAME=push \
  python3 -I "$act/test-results-to-jsonl.py" "$act/testdata" 2>/dev/null)
n=$(wc -l <<<"$rows" | tr -d ' ')
failed=$(jq -r 'select(.outcome=="failed") | .failure_hash' <<<"$rows" | grep -c '^[0-9a-f]\{16\}$' || true)
skipped=$(jq -r 'select(.outcome=="skipped") | .test_id' <<<"$rows" | wc -l | tr -d ' ')
ctx=$(jq -r 'select(.repo=="maestra-io/x" and .job=="j-leg" and .run_attempt=="2" and .sha=="abc" and .branch=="main") | .test_id' <<<"$rows" | wc -l | tr -d ' ')
times=$(jq -r '._time' <<<"$rows" | grep -c '^20[0-9][0-9]-' || true)
doubled=$(jq -r '.test_id' <<<"$rows" | grep -c 'Svc.Tests.X.Svc.Tests.X' || true)
xunit=$(jq -r '.test_id' <<<"$rows" | grep -cx 'Svc.Tests.X.Works' || true)
echo "rows=$n failed_with_hash=$failed skipped=$skipped with_context=$ctx with_time=$times xunit_id=$xunit doubled=$doubled"
[ "$n" = 9 ] && [ "$failed" = 2 ] && [ "$skipped" = 2 ] && [ "$ctx" = 9 ] && [ "$times" = 9 ] && [ "$xunit" = 1 ] && [ "$doubled" = 0 ] || { echo "FAIL"; exit 1; }
echo OK

# ingest.sh with a stub curl on PATH: the converter runs before any network call, the bearer
# comes from Vault (jwt-github login, KV v2 read) through bounded curl calls, the tokens are
# masked, and an unreachable Vault ends the step quickly with a warning and no upload.
script="$PWD/$act/ingest.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=${*: -1}
printf '%s\n' "$*" >> "$CALLS"
case "$url" in
  https://idtok.example/*)
    [ "$url" = 'https://idtok.example/x?api-version=2.0&audience=https%3A%2F%2Fgithub.com%2Fmaestra-io' ] \
      || { echo "bad oidc url: $url" >&2; exit 22; }
    echo '{"value":"eyJ.stub.jwt"}' ;;
  https://vault.example/v1/auth/jwt-github/login)
    [ "${VAULT_DOWN:-}" = 1 ] && { echo "curl: (28) Connection timed out after 5001 milliseconds" >&2; exit 28; }
    body=$(cat)
    [ "$(jq -r '.role + " " + .jwt' <<<"$body")" = "ci-test-results-ingest eyJ.stub.jwt" ] || { echo "bad login body: $body" >&2; exit 22; }
    echo '{"auth":{"client_token":"hvs.stub"}}' ;;
  https://vault.example/v1/gitlab/data/common/CI_TEST_RESULTS_TOKEN)
    [[ " $* " == *" -H X-Vault-Token: hvs.stub "* ]] || { echo "no vault token: $*" >&2; exit 22; }
    if [ "${KV_EMPTY:-}" = 1 ]; then echo '{"data":{"data":{}}}'; else echo '{"data":{"data":{"value":"ingest.stub"}}}'; fi ;;
  https://ingest.example/ci/test-results)
    [[ " $* " == *" -H Authorization: Bearer ingest.stub "* ]] || { echo "no bearer: $*" >&2; exit 22; }
    echo '{}' ;;
  *) echo "unexpected url: $url" >&2; exit 22 ;;
esac
STUB
chmod +x "$root/bin/curl"
# ingest.sh needs GNU split (-C): on a macOS laptop, coreutils' gsplit.
if ! split --version >/dev/null 2>&1; then
  g=$(command -v gsplit) || { echo "FAIL: GNU split needed (brew install coreutils)" >&2; exit 1; }
  ln -s "$g" "$root/bin/split"
fi
fail() { echo "FAIL: $*" >&2; exit 1; }
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token)
ingest() { # $1 = case dir, then extra env
  local d="$root/$1"; shift; mkdir -p "$d/tmp"; : > "$d/calls"
  env -i PATH="$root/bin:$PATH" HOME="$d" RUNNER_TEMP="$d/tmp" CALLS="$d/calls" RESULTS="$PWD/$act/testdata" \
    VAULT_URL=https://vault.example INGEST_URL=https://ingest.example/ci/test-results \
    GITHUB_REPOSITORY=maestra-io/x GITHUB_JOB=j GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=abc GITHUB_REF_NAME=main \
    "$@" bash "$script" > "$d/log" 2>&1
}

ingest ok "${oidc[@]}" || fail "happy path: $(cat "$root/ok/log")"
grep -qx 'ingested 9 rows (1 requests)' "$root/ok/log" || fail "no ingest line: $(cat "$root/ok/log")"
for t in eyJ.stub.jwt hvs.stub ingest.stub; do grep -qxF "::add-mask::$t" "$root/ok/log" || fail "$t not masked"; done
[ "$(wc -l < "$root/ok/calls" | tr -d ' ')" = 4 ] || fail "expected oidc, login, kv, upload: $(cat "$root/ok/calls")"
# Bounded: every Vault call connects within 5 s, every other call within 10 s, nothing unbounded.
[ "$(grep -c -- '--connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 --retry-connrefused' "$root/ok/calls")" = 2 ] \
  || fail "Vault calls not bounded: $(cat "$root/ok/calls")"
[ "$(grep -c -- '--connect-timeout' "$root/ok/calls")" = 4 ] || fail "a call without --connect-timeout: $(cat "$root/ok/calls")"
grep -q -- '--retry-max-time 120' "$root/ok/calls" || fail "upload retries not capped"

# No results: done before any network call (no Vault login for nothing).
ingest none "${oidc[@]}" RESULTS="$root/none/missing" || fail "no results failed: $(cat "$root/none/log")"
[ ! -s "$root/none/calls" ] || fail "network calls without results: $(cat "$root/none/calls")"

# Vault unreachable: a warning, a failed step (continue-on-error at the caller), no upload.
! ingest down "${oidc[@]}" VAULT_DOWN=1 || fail "an unreachable Vault passed"
grep -q '^::warning::test-results-ingest: Vault login as ci-test-results-ingest at https://vault.example failed' "$root/down/log" \
  || fail "no warning for an unreachable Vault: $(cat "$root/down/log")"
! grep -q 'ingest.example' "$root/down/calls" || fail "uploaded without a bearer"

# A KV secret without `value`, and a job without id-token: write: a warning each, no upload.
! ingest kv "${oidc[@]}" KV_EMPTY=1 || fail "an empty KV secret passed"
grep -q '^::warning::test-results-ingest: Vault did not return gitlab/data/common/CI_TEST_RESULTS_TOKEN' "$root/kv/log" || fail "KV warning: $(cat "$root/kv/log")"
! grep -q 'ingest.example' "$root/kv/calls" || fail "uploaded without a bearer (KV)"
! ingest noid || fail "ran without id-token"
# shellcheck disable=SC2016 # the backticks are literal text of the warning
grep -q 'needs `permissions: id-token: write`' "$root/noid/log" || fail "id-token warning: $(cat "$root/noid/log")"
[ ! -s "$root/noid/calls" ] || fail "network calls without id-token: $(cat "$root/noid/calls")"
echo "ingest.sh (stub curl): OK"
