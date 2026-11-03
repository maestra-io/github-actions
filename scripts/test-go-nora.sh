#!/usr/bin/env bash
# go-nora/go-nora.sh with a stub `curl` on PATH: GOPROXY / GOAUTH exported, the
# token output, the GOAUTH helper's credential set, and the refusal
# without the id-token permission. When go is on PATH, `go env` must accept GOAUTH.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../go-nora/go-nora.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/tmp"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" -H Authorization: bearer req-token "* ]] || { echo "bad auth header: $*" >&2; exit 22; }
[[ "${*: -1}" == "https://idtok.example/x?api-version=2.0&audience=packages.maestra.io" ]] || { echo "bad url: ${*: -1}" >&2; exit 22; }
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"
fail() { echo "FAIL: $*" >&2; exit 1; }
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token)

env -i PATH="$root/bin:$PATH" HOME="$root" RUNNER_TEMP="$root/tmp" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" \
  NORA_URL=https://packages.maestra.io/ NORA_AUDIENCE=packages.maestra.io "${oidc[@]}" \
  bash "$script" > "$root/log" 2>&1 || fail "run: $(cat "$root/log")"
helper="$root/tmp/go-nora/goauth"
printf 'GOPROXY=https://packages.maestra.io/go\nGOAUTH=command %s\n' "$helper" | diff - "$root/env" || fail "GITHUB_ENV"
[ "$(cat "$root/out")" = "token=eyJ.stub.jwt" ] || fail "output: $(cat "$root/out")"
grep -q '::add-mask::eyJ.stub.jwt' "$root/log" || fail "token not masked"
want=$(printf 'https://packages.maestra.io/go\n\nAuthorization: Basic %s\n' "$(printf 'token:eyJ.stub.jwt' | base64 | tr -d '\n')")
got=$(env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper")
[ "$got" = "$want" ] || fail "helper: $got"
# The retry form (URL argument, the 4xx response on stdin) answers the same way.
got=$(echo 'HTTP/1.1 401 Unauthorized' | env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper" https://packages.maestra.io/go/x/@v/list)
[ "$got" = "$want" ] || fail "helper retry: $got"
if command -v go >/dev/null; then
  [ "$(GOAUTH="command $helper" go env GOAUTH)" = "command $helper" ] || fail "go env GOAUTH"
fi

# Refusal: no id-token permission.
mkdir -p "$root/noid"
! env -i PATH="$PATH" HOME="$root/noid" RUNNER_TEMP="$root/noid" GITHUB_ENV="$root/noid/env" GITHUB_OUTPUT="$root/noid/out" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io bash "$script" > "$root/noid/log" 2>&1 \
  || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message"
echo "go-nora: ok"
