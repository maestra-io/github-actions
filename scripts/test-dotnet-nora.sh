#!/usr/bin/env bash
# dotnet-nora/dotnet-nora.sh: setup-dotnet version specs and global.json rollForward
# resolved against dotnet-nora/sdks.txt (DOTNET_NORA_RESOLVE_ONLY), the refusals, a download
# whose sha256 differs from the pin (stub curl): refused, nothing unpacked; the tool-cache
# tree pin: a tampered, extended or relinked SDK in the tool cache is reinstalled from the
# verified archive before anything in it runs, a wrong pin fails closed.
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

# every listed SDK has a tree pin (third column), not its archive sha256
sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${here}/../dotnet-nora/sdks.txt" | while read -r v sum tree extra; do
  [[ $sum =~ ^[0-9a-f]{64}$ && $tree =~ ^[0-9a-f]{64}$ && $tree != "$sum" && -z $extra ]] || fail "sdks.txt line for $v: want <version> <sha256> <tree sha256>"
done

# download: a body whose sha256 is not the pin is refused and not unpacked
mkdir -p "$root/bin" "$root/tc" "$root/tmp"
: > "$root/body" # what the stub serves; "tampered" while empty
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  *audience=*) echo '{"value":"eyJ.stub.jwt"}' ;;
  */api/oidc/session) o=; p=; for a in "$@"; do [ "$p" = -o ] && o=$a; p=$a; done; [ -n "$o" ] || { echo "session body not sent to a file: $*" >&2; exit 22; }
    printf '{"token":"nrs_1_stub"}' > "$o"; printf 200 ;;
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
  PATH="$root/bin:$PATH" BODY="$root/body" DOTNET_VERSION="$2" RUNNER_TOOL_CACHE="$root/tc" RUNNER_TEMP="$root/tmp" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  GITHUB_PATH="$root/path" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" bash "$1" > "$root/log" 2>&1
}
if install "$script" 10.0.x; then
  fail "a tampered download was accepted: $(cat "$root/log")"
fi
grep -qF "sha256" "$root/log" || fail "no sha256 refusal: $(cat "$root/log")"
left=$(find "$root/tc/dotnet-nora" -mindepth 1 ! -name '.*.lock')
[ -z "$left" ] || fail "unpacked after the refusal: $left"
[ ! -s "$root/path" ] || fail "PATH exported after the refusal"
[ -z "$(ls -A "$root/tmp/dotnet-nora")" ] || fail "the refused download was left in RUNNER_TEMP"

# install: fake SDKs 9.9.901 and 8.8.801 pinned (sha256 + tree) in a copy of the action. Each
# lands whole in its own tool-cache directory, marked complete; the job's root holds both
# (side by side), the newest one's `dotnet` host, nothing else (no runner-image SDK); PATH and
# DOTNET_ROOT point at it; a leftover unpack of an interrupted run is replaced.
act="$root/action"; mkdir -p "$act/dotnet-nora" "$act/nora-session"
cp "$script" "$act/dotnet-nora/"; cp "${here}/../nora-session/nora-session.sh" "$act/nora-session/"
mksdk() { # mksdk <version> <host text> → $root/a-<version>.tar.gz
  local s="$root/src-$1" r="${1%.*}.0"
  mkdir -p "$s/sdk/$1" "$s/shared/Microsoft.NETCore.App/$r" "$s/host/fxr/$r"
  printf '#!/bin/sh\n# %s\n' "$2" > "$s/dotnet"; chmod +x "$s/dotnet"; echo "sdk $1" > "$s/sdk/$1/dotnet.dll"
  echo "rt $r" > "$s/shared/Microsoft.NETCore.App/$r/x.dll"; echo "fxr $r" > "$s/host/fxr/$r/libhostfxr.so"
  ln -s ../sdk "$s/sdk-link"
  tar -czf "$root/a-$1.tar.gz" -C "$s" .
}
mksdk 9.9.901 host-9; mksdk 8.8.801 host-8
pinline() { printf '%s %s %s\n' "$1" "$(sha256sum "$root/a-$1.tar.gz" | cut -d' ' -f1)" "$(DOTNET_NORA_TREE="$root/a-$1.tar.gz" bash "$script")"; }
{ pinline 9.9.901; pinline 8.8.801; } > "$act/dotnet-nora/sdks.txt"
cat > "$root/bin/dotnet" <<'STUB'
#!/usr/bin/env bash
for d in "$DOTNET_ROOT"/sdk/*/; do d=${d%/}; echo "${d##*/} [$DOTNET_ROOT/sdk]"; done
STUB
chmod +x "$root/bin/dotnet"
tcd="$root/tc/dotnet-nora" rt="$root/tmp/dotnet-nora-root"
serve() { if [ "$1" = - ]; then : > "$root/body"; else cp "$root/a-$1.tar.gz" "$root/body"; fi; rm -f "$root/body.calls"; }
run() { : > "$root/path"; : > "$root/env"; : > "$root/out"; DOTNET_ROOT="$rt" install "$act/dotnet-nora/dotnet-nora.sh" "$1"; }
mkdir -p "$tcd/9.9.901.nora/sdk"; echo junk > "$tcd/9.9.901.nora/junk"
serve 9.9.901; run 9.9.x || fail "install: $(cat "$root/log")"
[ -f "$tcd/9.9.901.complete" ] && [ "$(cat "$tcd/9.9.901/sdk/9.9.901/dotnet.dll")" = "sdk 9.9.901" ] || fail "9.9.901 not in the tool cache: $(cat "$root/log")"
[ ! -e "$tcd/9.9.901.nora" ] || fail "leftover unpack not replaced"
[ "$(cat "$rt/sdk/9.9.901/dotnet.dll")" = "sdk 9.9.901" ] || fail "9.9.901 not in the job's root"
grep -qx "$rt" "$root/path" || fail "root not on PATH"
grep -qx "DOTNET_ROOT=$rt" "$root/env" || fail "DOTNET_ROOT not exported"
serve 8.8.801; run $'8.8.x\n9.9.x' || fail "side by side: $(cat "$root/log")"
[ -s "$root/body.calls" ] && [ "$(wc -l < "$root/body.calls")" -eq 1 ] || fail "side by side: want only 8.8.801 fetched: $(cat "$root/body.calls" 2>/dev/null)"
[ "$(cat "$rt/sdk/8.8.801/dotnet.dll")" = "sdk 8.8.801" ] && [ -d "$rt/sdk/9.9.901" ] || fail "side by side: both SDKs not in the root"
[ "$(cat "$rt/shared/Microsoft.NETCore.App/8.8.0/x.dll")" = "rt 8.8.0" ] && [ -d "$rt/shared/Microsoft.NETCore.App/9.9.0" ] || fail "side by side: runtimes not merged"
grep -qx '# host-9' "$rt/dotnet" || fail "the newest SDK's dotnet host is not the root's"
mkdir -p "$rt/sdk/11.0.100"; serve -; run 8.8.x || fail "rerun: $(cat "$root/log")"
[ ! -e "$rt/sdk/11.0.100" ] && [ ! -e "$rt/sdk/9.9.901" ] || fail "the root is not rebuilt fresh: $(ls "$rt/sdk")"
[ ! -e "$root/body.calls" ] || fail "rerun fetched from nora"
grep -q "SDK 8.8.801 already in the tool cache" "$root/log" || fail "rerun not served from the tool cache: $(cat "$root/log")"

# the tree pin: what an earlier job on the same host could leave in the tool cache never runs.
# Each case: nora serves a tampered body, so a reinstall must come from a verified archive
# (the runner cache) and the tampering must be gone from the root.
mkdir -p "$root/cache"; cp "$root/a-9.9.901.tar.gz" "$root/cache/dotnet-sdk-9.9.901.tar.gz"
tampered() { # tampered <what>: run 9.9.x, expect a reinstall from the cache and the pinned content
  serve -; : > "$root/out"
  DOTNET_NORA_CACHE_DIR="$root/cache" run 9.9.x || fail "$1: $(cat "$root/log")"
  grep -q "is not the pinned tree" "$root/log" || fail "$1: not reported: $(cat "$root/log")"
  [ ! -e "$root/body.calls" ] || fail "$1: fetched from nora instead of the verified cached archive"
  grep -qx '# host-9' "$rt/dotnet" && [ "$(cat "$rt/sdk/9.9.901/dotnet.dll")" = "sdk 9.9.901" ] || fail "$1: the root runs the tampered SDK"
  [ -z "$(find "$rt" "$tcd/9.9.901" -name pwned)" ] || fail "$1: an added file survived"
}
echo pwned > "$tcd/9.9.901/dotnet"; tampered "tampered host binary"
echo pwned > "$tcd/9.9.901/host/fxr/9.9.0/pwned"; tampered "added hostfxr file"
echo pwned > "$rt/sdk/9.9.901/dotnet.dll"; tampered "rewritten through the job's root (hard link)"
ln -sfn /bin/sh "$tcd/9.9.901/sdk-link"; tampered "relinked symlink"
chmod -x "$tcd/9.9.901/dotnet"; tampered "dropped exec bit"
# a fresh unpack that is not the pin (a wrong pin) fails closed: no marker, nothing exported
sed -i -e "s/^\(9.9.901 [0-9a-f]*\) .*/\1 $(printf '0%.0s' {1..64})/" "$act/dotnet-nora/sdks.txt"
rm -rf "$tcd/9.9.901" "$tcd/9.9.901.complete"
if DOTNET_NORA_CACHE_DIR="$root/cache" run 9.9.x; then fail "a wrong tree pin was accepted: $(cat "$root/log")"; fi
grep -q "unpacked to tree sha256" "$root/log" || fail "wrong tree pin not reported: $(cat "$root/log")"
[ ! -e "$tcd/9.9.901.complete" ] && [ ! -e "$tcd/9.9.901" ] && [ ! -s "$root/path" ] || fail "wrong tree pin: installed or exported"
sed -i -e "s/^\(9.9.901 [0-9a-f]*\) .*/\1/" "$act/dotnet-nora/sdks.txt"
if run 9.9.x; then fail "a missing tree pin was accepted"; fi
grep -q "has no tree pin" "$root/log" || fail "missing tree pin not reported: $(cat "$root/log")"
{ pinline 9.9.901; pinline 8.8.801; } > "$act/dotnet-nora/sdks.txt"

# cache (DOTNET_NORA_PLAN, DOTNET_NORA_CACHE_DIR): the key names the SDKs not complete in the
# tool cache and hashes their pins; a miss fetches and keeps the archive for the save; a hit
# with the pinned sha256 fetches nothing from nora; a cached archive that is not the pin is
# dropped and fetched again.
plan() { : > "$root/out"; DOTNET_NORA_PLAN=1 DOTNET_ROOT="$rt" install "$act/dotnet-nora/dotnet-nora.sh" "$1" || fail "plan: $(cat "$root/log")"; sed -n 's/^cache-key=//p' "$root/out"; }
rm -f "$root/body.calls"
[ -z "$(plan 8.8.x)" ] || fail "cache key while SDK 8.8.801 is complete: $(cat "$root/out")"
rm -rf "$tcd/9.9.901" "$tcd/9.9.901.complete"
pin=$(grep '^9.9.901 ' "$act/dotnet-nora/sdks.txt")
key=$(plan 9.9.x)
[ "$key" = "dotnet-nora-sdk-linux-x64-9.9.901-$(sha256sum <<<"$pin" | cut -c1-16)" ] || fail "cache key '$key'"
[ ! -e "$root/body.calls" ] || fail "plan fetched something"
cached() { # install 9.9.x with the cache dir, 9.9.901 removed from the tool cache first
  rm -rf "$tcd/9.9.901" "$tcd/9.9.901.complete" "$root/body.calls"
  DOTNET_NORA_CACHE_DIR="$root/cache" run 9.9.x
}
serve 9.9.901; rm -rf "$root/cache"
cached || fail "cache miss: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "cache miss fetched nothing"
cmp -s "$root/body" "$root/cache/dotnet-sdk-9.9.901.tar.gz" || fail "cache miss: archive not kept for the save"
grep -qx "save=true" "$root/out" || fail "cache miss: no save=true"
serve - # nora would serve a tampered body now: a hit must not ask
cached || fail "cache hit: $(cat "$root/log")"
[ ! -e "$root/body.calls" ] || fail "cache hit fetched from nora: $(cat "$root/body.calls")"
[ "$(cat "$rt/sdk/9.9.901/dotnet.dll")" = "sdk 9.9.901" ] || fail "cache hit: 9.9.901 not in the root"
grep -q "from the runner cache" "$root/log" || fail "cache hit not logged: $(cat "$root/log")"
! grep -q "save=true" "$root/out" || fail "cache hit asked for a save"
serve 9.9.901; echo poisoned > "$root/cache/dotnet-sdk-9.9.901.tar.gz"
cached || fail "poisoned cache: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "poisoned cache entry was used"
grep -q "not the sha256 pin" "$root/log" || fail "poisoned cache not reported: $(cat "$root/log")"
cmp -s "$root/body" "$root/cache/dotnet-sdk-9.9.901.tar.gz" || fail "poisoned cache: fresh archive not kept"
serve -; echo poisoned > "$root/cache/dotnet-sdk-9.9.901.tar.gz"
if cached; then fail "poisoned cache + tampered download accepted: $(cat "$root/log")"; fi
[ ! -e "$tcd/9.9.901" ] && [ ! -e "$tcd/9.9.901.complete" ] || fail "installed after a poisoned cache + tampered download"
# an archive that matches its sha256 pin but does not unpack fails the step, marks nothing complete
echo "not a tarball" > "$root/body"
sed -i -e "s/^9.9.901 [0-9a-f]*/9.9.901 $(sha256sum "$root/body" | cut -d' ' -f1)/" "$act/dotnet-nora/sdks.txt"
rm -rf "$tcd/9.9.901" "$tcd/9.9.901.complete" "$root/body.calls"
if run 9.9.x; then fail "an archive that does not unpack was accepted: $(cat "$root/log")"; fi
[ ! -e "$tcd/9.9.901.complete" ] && [ ! -e "$tcd/9.9.901" ] && [ ! -s "$root/path" ] || fail "failed unpack: marked complete or exported"
echo "dotnet-nora: ok"
