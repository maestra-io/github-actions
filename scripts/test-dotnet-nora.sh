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
# latestMajor/major: the requested major while it serves, else a higher one
s11=$(latest 11)
expect "$s11" "" '{"sdk":{"version":"10.0.405","rollForward":"latestMajor"}}'
expect "$s11" "" '{"sdk":{"version":"10.0.405","rollForward":"major"}}'
refuse "no SDK satisfies" "" '{"sdk":{"version":"10.0.405","rollForward":"latestMinor"}}'
# comments, as dotnet accepts them; a "//" inside a string stays
expect "$s8" "" $'{ // pinned\n "sdk": { /* lts */ "version": "8.0.100", "rollForward": "latestFeature" },\n "msbuild-sdks": {"X": "http://x//y"} }'
refuse "not valid JSON" "" '{"sdk": {"version": "8.0.100",'

# download: a body whose sha256 is not the pin is refused and not unpacked
mkdir -p "$root/bin" "$root/dotnet" "$root/tmp"
: > "$root/body" # what the stub serves; "tampered" while empty
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  *audience=*) echo '{"value":"eyJ.stub.jwt"}' ;;
  */api/oidc/session) printf '{"token":"nrs_1_stub"}\n200' ;;
  */raw/src/builds.dotnet.microsoft.com/dotnet/Sdk/*)
    echo "${*: -1}" >> "$BODY.calls"
    cfg=$(cat) # -K -: the credential arrives on stdin
    [ "$cfg" = 'user = "token:nrs_1_stub"' ] || { echo "bad credential config: $cfg" >&2; exit 22; }
    while [ $# -gt 1 ]; do
      if [ "$1" = -o ]; then if [ -s "$BODY" ]; then cp "$BODY" "$2"; else echo tampered > "$2"; fi; exit 0; fi
      shift
    done; exit 22 ;;
  *) echo "unexpected curl: $*" >&2; exit 22 ;;
esac
STUB
chmod +x "$root/bin/curl"
install() { # install <script> <dotnet-version>
  PATH="$root/bin:$PATH" BODY="$root/body" DOTNET_VERSION="$2" DOTNET_INSTALL_DIR="$root/dotnet" RUNNER_TEMP="$root/tmp" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  GITHUB_PATH="$root/path" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" bash "$1" > "$root/log" 2>&1
}
if install "$script" 10.0.x; then
  fail "a tampered download was accepted: $(cat "$root/log")"
fi
grep -qF "sha256" "$root/log" || fail "no sha256 refusal: $(cat "$root/log")"
[ -z "$(ls -A "$root/dotnet")" ] || fail "unpacked after the refusal"
[ ! -s "$root/path" ] || fail "PATH exported after the refusal"
[ -z "$(ls -A "$root/tmp/dotnet-nora")" ] || fail "the refused download was left in RUNNER_TEMP"

# install: a fake SDK 9.9.901 tarball pinned in a copy of the action. The image's files stay
# (its `dotnet` host), versioned directories merge, sdk/<v> appears complete, PATH exported;
# an interrupted earlier run (stage left behind) is cleaned up; a second run skips it.
act="$root/action"; mkdir -p "$act/dotnet-nora" "$act/nora-session" "$root/sdk/sdk/9.9.901" "$root/sdk/shared/Microsoft.NETCore.App/9.9.0"
cp "$script" "$act/dotnet-nora/"; cp "${here}/../nora-session/nora-session.sh" "$act/nora-session/"
echo new-host > "$root/sdk/dotnet"; echo sdk > "$root/sdk/sdk/9.9.901/dotnet.dll"; echo rt > "$root/sdk/shared/Microsoft.NETCore.App/9.9.0/x.dll"
tar -czf "$root/body" -C "$root/sdk" .
printf '9.9.901 %s\n' "$(sha256sum "$root/body" | cut -d' ' -f1)" > "$act/dotnet-nora/sdks.txt"
mkdir -p "$root/dotnet/sdk/11.0.100" "$root/dotnet/.dotnet-nora-9.9.901/sdk/9.9.901"; echo image-host > "$root/dotnet/dotnet"
cat > "$root/bin/dotnet" <<'STUB'
#!/usr/bin/env bash
for d in "$DOTNET_ROOT"/sdk/*/; do d=${d%/}; echo "${d##*/} [$DOTNET_ROOT/sdk]"; done
STUB
chmod +x "$root/bin/dotnet"
: > "$root/path"
DOTNET_ROOT="$root/dotnet" install "$act/dotnet-nora/dotnet-nora.sh" 9.9.x || fail "install: $(cat "$root/log")"
[ "$(cat "$root/dotnet/sdk/9.9.901/dotnet.dll")" = sdk ] || fail "sdk/9.9.901 not installed: $(cat "$root/log")"
[ "$(cat "$root/dotnet/shared/Microsoft.NETCore.App/9.9.0/x.dll")" = rt ] || fail "runtime not merged"
[ "$(cat "$root/dotnet/dotnet")" = image-host ] || fail "the image's dotnet host was overwritten"
[ -d "$root/dotnet/sdk/11.0.100" ] || fail "the image's SDK is gone"
[ -z "$(find "$root/dotnet" -maxdepth 1 -name '.dotnet-nora-*')" ] || fail "staging left in $root/dotnet"
grep -qx "$root/dotnet" "$root/path" || fail "install dir not on PATH"
grep -qx "DOTNET_ROOT=$root/dotnet" "$root/env" || fail "DOTNET_ROOT not exported"
: > "$root/body"
DOTNET_ROOT="$root/dotnet" install "$act/dotnet-nora/dotnet-nora.sh" 9.9.x || fail "rerun: $(cat "$root/log")"
grep -q "SDK 9.9.901 already in" "$root/log" || fail "rerun downloaded again: $(cat "$root/log")"
# cache (DOTNET_NORA_PLAN, DOTNET_NORA_CACHE_DIR): the key names the missing SDKs and hashes
# their pins; a miss fetches and keeps the archive for the save; a hit with the pinned sha256
# fetches nothing from nora; a cached archive that is not the pin is dropped and fetched again.
plan() { : > "$root/out"; DOTNET_NORA_PLAN=1 DOTNET_ROOT="$root/dotnet" install "$act/dotnet-nora/dotnet-nora.sh" "$1" || fail "plan: $(cat "$root/log")"; sed -n 's/^cache-key=//p' "$root/out"; }
rm -f "$root/body.calls"
[ -z "$(plan 9.9.x)" ] || fail "cache key while SDK 9.9.901 is installed: $(cat "$root/out")"
rm -rf "$root/dotnet/sdk/9.9.901"
pin=$(cat "$act/dotnet-nora/sdks.txt")
key=$(plan 9.9.x)
[ "$key" = "dotnet-nora-sdk-linux-x64-9.9.901-$(sha256sum <<<"$pin" | cut -c1-16)" ] || fail "cache key '$key'"
[ ! -e "$root/body.calls" ] || fail "plan fetched something"
cached() { # cached <want save=true|-> : install 9.9.x with the cache dir, sdk/9.9.901 removed first
  rm -rf "$root/dotnet/sdk/9.9.901" "$root/body.calls"; : > "$root/out"
  DOTNET_NORA_CACHE_DIR="$root/cache" DOTNET_ROOT="$root/dotnet" install "$act/dotnet-nora/dotnet-nora.sh" 9.9.x
}
tar -czf "$root/body" -C "$root/sdk" .; rm -rf "$root/cache"
cached || fail "cache miss: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "cache miss fetched nothing"
cmp -s "$root/body" "$root/cache/dotnet-sdk-9.9.901.tar.gz" || fail "cache miss: archive not kept for the save"
grep -qx "save=true" "$root/out" || fail "cache miss: no save=true"
: > "$root/body" # nora would serve a tampered body now: a hit must not ask
cached || fail "cache hit: $(cat "$root/log")"
[ ! -e "$root/body.calls" ] || fail "cache hit fetched from nora: $(cat "$root/body.calls")"
[ "$(cat "$root/dotnet/sdk/9.9.901/dotnet.dll")" = sdk ] || fail "cache hit: sdk/9.9.901 not installed"
grep -q "from the runner cache" "$root/log" || fail "cache hit not logged: $(cat "$root/log")"
! grep -q "save=true" "$root/out" || fail "cache hit asked for a save"
tar -czf "$root/body" -C "$root/sdk" .; echo poisoned > "$root/cache/dotnet-sdk-9.9.901.tar.gz"
cached || fail "poisoned cache: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "poisoned cache entry was used"
grep -q "not the sha256 pin" "$root/log" || fail "poisoned cache not reported: $(cat "$root/log")"
cmp -s "$root/body" "$root/cache/dotnet-sdk-9.9.901.tar.gz" || fail "poisoned cache: fresh archive not kept"
: > "$root/body"; echo poisoned > "$root/cache/dotnet-sdk-9.9.901.tar.gz"
if cached; then fail "poisoned cache + tampered download accepted: $(cat "$root/log")"; fi
[ ! -e "$root/dotnet/sdk/9.9.901" ] || fail "installed after a poisoned cache + tampered download"
# a copy that fails (a directory the job cannot write) fails the step and leaves no sdk/<v>
# that would mark the partial install complete; root writes anyway, so only as a user (CI)
if [ "$(id -u)" != 0 ]; then
  tar -czf "$root/body" -C "$root/sdk" .
  rm -rf "$root/dotnet"; mkdir -p "$root/dotnet/shared"; chmod 555 "$root/dotnet/shared"
  if DOTNET_ROOT="$root/dotnet" install "$act/dotnet-nora/dotnet-nora.sh" 9.9.x; then
    chmod 755 "$root/dotnet/shared"; fail "a failed copy was accepted: $(cat "$root/log")"
  fi
  chmod 755 "$root/dotnet/shared"
  [ ! -e "$root/dotnet/sdk/9.9.901" ] || fail "sdk/9.9.901 present after a failed copy"
fi
echo "dotnet-nora: ok"
