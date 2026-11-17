#!/usr/bin/env bash
# dotnet-nora/dotnet-nora.sh: setup-dotnet version specs and global.json rollForward
# resolved against dotnet-nora/sdks.txt (DOTNET_NORA_RESOLVE_ONLY), the refusals, and a
# download whose sha256 differs from the pin (stub curl): refused, nothing unpacked.
# The real download from nora is the selftest step `uses: ./dotnet-nora`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../dotnet-nora/dotnet-nora.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
latest() { awk -v M="$1" '$1 ~ "^"M"\\." { v = $1 } END { print v }' "${here}/../dotnet-nora/sdks.txt"; }
s10=$(latest 10) s8=$(latest 8) s6=$(latest 6)

resolve() { # resolve <dotnet-version> <global.json content|-> → stdout
  local gj=""
  if [ "$2" != - ]; then gj="$root/global.json"; printf '%s' "$2" > "$gj"; fi
  DOTNET_NORA_RESOLVE_ONLY=1 DOTNET_VERSION="$1" GLOBAL_JSON="$gj" bash "$script" 2>"$root/err"
}
expect() { # expect <want> <dotnet-version> <global.json|->
  local got; got=$(resolve "$2" "$3" | paste -sd' ' -) || fail "'$2' / $3: $(cat "$root/err")"
  [ "$got" = "$1" ] || fail "'$2' / $3: got '$got', want '$1'"
}
refuse() { # refuse <message part> <dotnet-version> <global.json|->
  if resolve "$2" "$3" >/dev/null; then fail "'$2' / $3 resolved, want a refusal"; fi
  grep -qF -- "$1" "$root/err" || fail "'$2' / $3: no '$1' in: $(cat "$root/err")"
}

for spec in 10 10.x 10.0 10.0.x 10.0.4xx "$s10"; do expect "$s10" "$spec" -; done
expect "$s10 $s8" $'8.0.x\n10.0.x\n' -           # newest first, blank lines skipped
expect "$s10" $'10.0.x\n10.0' -                  # duplicates once
expect "" "" -                                   # nothing asked: nothing
refuse "no SDK for '10.0.1xx'" 10.0.1xx -        # a band sdks.txt does not hold
refuse "no SDK for '10.0.100'" 10.0.100 -        # exact = exact
refuse "only N, N.x" "latest" -

# global.json: every rollForward policy the org uses (latestMajor/latestMinor/latestFeature/minor)
expect "$s10" "" '{"sdk":{"version":"10.0.201","rollForward":"latestMajor"}}'
expect "$s10" "" '{"sdk":{"version":"10.0.0","rollForward":"latestMajor"}}'   # setup-dotnet refused this one
expect "$s10" "" '{"sdk":{"version":"10.0.100","rollForward":"latestMinor","allowPrerelease":false}}'
expect "$s10" "" '{"sdk":{"version":"10.0.403","rollForward":"latestFeature"}}'
expect "$s8" "" '{"sdk":{"version":"8.0.100","rollForward":"minor"}}'
expect "$s6" "" '{"sdk":{"version":"6.0.100","rollForward":"feature"}}'
expect "$s10 $s8" 8.0.x '{"sdk":{"version":"10.0.100","rollForward":"latestMinor"}}'
expect "" "" '{"test":{"runner":"Microsoft.Testing.Platform"}}'               # no sdk.version
refuse "no SDK satisfies" "" '{"sdk":{"version":"10.0.100"}}'                 # latestPatch: band 1xx
refuse "no SDK satisfies" "" '{"sdk":{"version":"10.0.405","rollForward":"latestFeature"}}' # above the newest
expect "$s10" "" "{\"sdk\":{\"version\":\"$s10\",\"rollForward\":\"disable\"}}"
refuse "not a global.json policy" "" '{"sdk":{"version":"10.0.100","rollForward":"newest"}}'
refuse "not a release SDK version" "" '{"sdk":{"version":"10.0.100-rc.1","rollForward":"latestMajor"}}'

# download: a body whose sha256 is not the pin is refused and not unpacked
mkdir -p "$root/bin" "$root/dotnet" "$root/tmp"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  *audience=*) echo '{"value":"eyJ.stub.jwt"}' ;;
  */api/oidc/session) printf '{"token":"nrs_1_stub"}\n200' ;;
  */raw/src/builds.dotnet.microsoft.com/dotnet/Sdk/*)
    cfg=$(cat) # -K -: the credential arrives on stdin
    [ "$cfg" = 'user = "token:nrs_1_stub"' ] || { echo "bad credential config: $cfg" >&2; exit 22; }
    while [ $# -gt 1 ]; do [ "$1" = -o ] && { echo tampered > "$2"; exit 0; }; shift; done; exit 22 ;;
  *) echo "unexpected curl: $*" >&2; exit 22 ;;
esac
STUB
chmod +x "$root/bin/curl"
if PATH="$root/bin:$PATH" DOTNET_VERSION=10.0.x DOTNET_INSTALL_DIR="$root/dotnet" RUNNER_TEMP="$root/tmp" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  GITHUB_PATH="$root/path" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" bash "$script" > "$root/log" 2>&1; then
  fail "a tampered download was accepted: $(cat "$root/log")"
fi
grep -qF "sha256" "$root/log" || fail "no sha256 refusal: $(cat "$root/log")"
[ -z "$(ls -A "$root/dotnet")" ] || fail "unpacked after the refusal"
[ ! -s "$root/path" ] || fail "PATH exported after the refusal"
[ -z "$(ls -A "$root/tmp/dotnet-nora")" ] || fail "the refused download was left in RUNNER_TEMP"
echo "dotnet-nora: ok"
