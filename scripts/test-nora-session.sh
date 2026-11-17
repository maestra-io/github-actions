#!/usr/bin/env bash
# nora-session/nora-session.sh with a stub `curl` on PATH: the JWT exchanged for a
# session token (masked output), the JWT kept with a warning when nora has no
# exchange (404) or no session for the provider (403), a failed exchange failing the step,
# the JWT kept out of xtrace, and the refusal without the id-token permission.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../nora-session/nora-session.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "${*: -1}" == https://packages.maestra.io/api/oidc/session ]]; then
  [[ " $* " == *" -X POST -H Authorization: Bearer eyJ.stub.jwt "* ]] || { echo "bad exchange: $*" >&2; exit 22; }
  [ -z "${SESSION_CODE:-}" ] || { printf '{"error":"x"}\n%s' "$SESSION_CODE"; exit 0; }
  printf '{"token":"nrs_1_stub","expires_in":3600}\n200'; exit 0
fi
[[ " $* " == *" -H Authorization: bearer req-token "* ]] || { echo "bad auth header: $*" >&2; exit 22; }
[[ "${*: -1}" == "https://idtok.example/x?api-version=2.0&audience=packages.maestra.io" ]] || { echo "bad url: ${*: -1}" >&2; exit 22; }
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"
fail() { echo "FAIL: $*" >&2; exit 1; }
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token)
run() { # $1 = case dir, then extra env
  local d="$root/$1"; shift; mkdir -p "$d"
  env -i PATH="$root/bin:$PATH" GITHUB_OUTPUT="$d/out" NORA_URL=https://packages.maestra.io/ \
    NORA_AUDIENCE=packages.maestra.io "$@" bash "$script" > "$d/log" 2>&1
}

run ok "${oidc[@]}" || fail "run: $(cat "$root/ok/log")"
[ "$(cat "$root/ok/out")" = "token=nrs_1_stub" ] || fail "output: $(cat "$root/ok/out")"
grep -qxF '::add-mask::nrs_1_stub' "$root/ok/log" || fail "token not masked"
! grep -q warning "$root/ok/log" || fail "warned on success"

run old "${oidc[@]}" SESSION_CODE=404 || fail "run without exchange: $(cat "$root/old/log")"
[ "$(cat "$root/old/out")" = "token=eyJ.stub.jwt" ] || fail "fallback output: $(cat "$root/old/out")"
grep -qxF '::add-mask::eyJ.stub.jwt' "$root/old/log" || fail "fallback token not masked"
grep -q '::warning::nora at .* gives no session (HTTP 404)' "$root/old/log" || fail "fallback not warned"

# A provider without sessions (403) also keeps the JWT; any other answer fails the step.
run noses "${oidc[@]}" SESSION_CODE=403 || fail "run on 403: $(cat "$root/noses/log")"
[ "$(cat "$root/noses/out")" = "token=eyJ.stub.jwt" ] || fail "403 output: $(cat "$root/noses/out")"
! run broken "${oidc[@]}" SESSION_CODE=500 || fail "a 500 from the exchange passed"
[ ! -s "$root/broken/out" ] || fail "a 500 wrote an output: $(cat "$root/broken/out")"
grep -q '::error::nora session exchange at .* answered HTTP 500' "$root/broken/log" || fail "500 message"

# The JWT is masked before anything uses it, and tracing never prints it.
grep -qxF '::add-mask::eyJ.stub.jwt' "$root/ok/log" || fail "JWT not masked"
mkdir -p "$root/trace"
# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
( set -x; source "$script"; PATH="$root/bin:$PATH" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token \
  nora_token https://packages.maestra.io packages.maestra.io ) > "$root/trace/out" 2> "$root/trace/err" \
  || fail "sourced run: $(cat "$root/trace/err")"
[ "$(cat "$root/trace/out")" = nrs_1_stub ] || fail "sourced stdout: $(cat "$root/trace/out")"
! grep -v '^::add-mask::' "$root/trace/err" | grep -q 'eyJ.stub.jwt' || fail "xtrace printed the JWT"

! run noid || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message"
echo "nora-session: ok"
