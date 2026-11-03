#!/usr/bin/env bash
# cargo-nora/cargo-nora.sh with a stub `curl` on PATH: the config.toml source
# replacement, the token-from-stdout helper, the masked token output and the
# refusal without the id-token permission.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../cargo-nora/cargo-nora.sh"
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

env -i PATH="$root/bin:$PATH" HOME="$root" RUNNER_TEMP="$root/tmp" GITHUB_OUTPUT="$root/out" \
  NORA_URL=https://packages.maestra.io/ NORA_AUDIENCE=packages.maestra.io "${oidc[@]}" \
  bash "$script" > "$root/log" 2>&1 || fail "run: $(cat "$root/log")"
helper="$root/tmp/cargo-nora/token"
want="Basic $(printf 'token:eyJ.stub.jwt' | base64 | tr -d '\n')"
cfg="$root/.cargo/config.toml"
grep -qxF 'replace-with = "nora"' "$cfg" || fail "no source replacement"
grep -qxF 'registry = "sparse+https://packages.maestra.io/cargo/index/"' "$cfg" || fail "source registry"
grep -qxF "credential-provider = [\"cargo:token-from-stdout\", \"$helper\"]" "$cfg" || fail "credential provider"
[ "$(cat "$root/out")" = "token=eyJ.stub.jwt" ] || fail "output: $(cat "$root/out")"
grep -qxF "::add-mask::eyJ.stub.jwt" "$root/log" || fail "token not masked"
got=$(env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper")
[ "$got" = "$want" ] || fail "helper: $got"

# Refusal: no id-token permission.
mkdir -p "$root/noid"
! env -i PATH="$PATH" HOME="$root/noid" RUNNER_TEMP="$root/noid" GITHUB_OUTPUT="$root/noid/out" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io bash "$script" > "$root/noid/log" 2>&1 \
  || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message"
echo "cargo-nora: ok"
