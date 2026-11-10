#!/usr/bin/env bash
# go-nora/go-nora.sh with a stub `curl` on PATH: GOPROXY / GOAUTH exported, the
# token output, the GOAUTH helper's credential set, and the refusal
# without the id-token permission. When go is on PATH, `go` must run the helper.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../go-nora/go-nora.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/tmp"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "${*: -1}" == https://packages.maestra.io/api/oidc/session ]]; then
  [[ " $* " == *" -X POST -H Authorization: Bearer eyJ.stub.jwt "* ]] || { echo "bad exchange: $*" >&2; exit 22; }
  [ -z "${SESSION_CODE:-}" ] || { printf '{"error":"x"}\n%s' "$SESSION_CODE"; exit 0; }
  printf '{"token":"nrs_1_stub"}\n200'; exit 0
fi
[[ " $* " == *" -H Authorization: bearer req-token "* ]] || { echo "bad auth header: $*" >&2; exit 22; }
[[ "${*: -1}" == "https://idtok.example/x?api-version=2.0&audience=packages.maestra.io" ]] || { echo "bad url: ${*: -1}" >&2; exit 22; }
[ -z "${CURL_LOG:-}" ] || echo called >> "$CURL_LOG"
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"
fail() { echo "FAIL: $*" >&2; exit 1; }
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token)

env -i PATH="$root/bin:$PATH" HOME="$root" RUNNER_TEMP="$root/tmp" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" \
  NORA_URL=https://packages.maestra.io/ NORA_AUDIENCE=packages.maestra.io "${oidc[@]}" \
  bash "$script" > "$root/log" 2>&1 || fail "run: $(cat "$root/log")"
helper="$root/tmp/go-nora/goauth"
printf 'GOPROXY=https://packages.maestra.io/go\nGOAUTH=%s\n' "$helper" | diff - "$root/env" || fail "GITHUB_ENV"
[ "$(cat "$root/out")" = "token=nrs_1_stub" ] || fail "output: $(cat "$root/out")"
grep -q '::add-mask::nrs_1_stub' "$root/log" || fail "token not masked"
# The URL line is the origin: Go 1.24 never matches a credential stored under a path
# prefix (https://packages.maestra.io/go), so go 1.24 sent no header and got 401.
want=$(printf 'https://packages.maestra.io\n\nAuthorization: Basic %s\n' "$(printf 'token:eyJ.stub.jwt' | base64 | tr -d '\n')")
got=$(env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper")
[ "$got" = "$want" ] || fail "helper: $got"
# The retry form (URL argument, the 4xx response on stdin) answers the same way.
got=$(echo 'HTTP/1.1 401 Unauthorized' | env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper" https://packages.maestra.io/go/x/@v/list)
[ "$got" = "$want" ] || fail "helper retry: $got"
if command -v go >/dev/null; then
  # go runs GOAUTH before its first HTTPS fetch; the proxy port is closed, so the
  # helper's stub-curl call is the only proof it ran (GOAUTH="command X" never does).
  mkdir -p "$root/mod"
  ( cd "$root/mod" && printf 'module m\n' > go.mod &&
    env "$(grep GOAUTH "$root/env")" GOPROXY=https://127.0.0.1:9/go GOFLAGS=-modcacherw GONOSUMDB=* \
      GOMODCACHE="$root/modcache" PATH="$root/bin:$PATH" "${oidc[@]}" CURL_LOG="$root/curl.log" \
      go mod download -x example.com/x@v1.0.0 > "$root/go.log" 2>&1 ) || true
  [ -s "$root/curl.log" ] || fail "go never ran the GOAUTH helper: $(grep -m1 GOAUTH "$root/go.log")"
fi

# A nora without the session exchange: the raw JWT, with a warning.
env -i PATH="$root/bin:$PATH" HOME="$root" RUNNER_TEMP="$root/tmp" GITHUB_ENV="$root/env2" GITHUB_OUTPUT="$root/out2" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io SESSION_CODE=404 "${oidc[@]}" \
  bash "$script" > "$root/log2" 2>&1 || fail "run without exchange: $(cat "$root/log2")"
[ "$(cat "$root/out2")" = "token=eyJ.stub.jwt" ] || fail "fallback output: $(cat "$root/out2")"
grep -q '::warning::nora at .* gives no session (HTTP 404)' "$root/log2" || fail "fallback not warned"

# Refusal: no id-token permission.
mkdir -p "$root/noid"
! env -i PATH="$PATH" HOME="$root/noid" RUNNER_TEMP="$root/noid" GITHUB_ENV="$root/noid/env" GITHUB_OUTPUT="$root/noid/out" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io bash "$script" > "$root/noid/log" 2>&1 \
  || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message"
echo "go-nora: ok"
