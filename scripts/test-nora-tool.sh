#!/usr/bin/env bash
# nora-tool/nora-tool.sh (setup-{go,node,python,uv,terraform,helm}-nora): version specs and
# go.mod resolved against each versions.txt (NORA_TOOL_RESOLVE_ONLY), the refusals, and with a
# stub curl: a download whose sha256 is not the pin is refused and nothing unpacked; a fetch
# keeps the archive for the cache save; a cached archive with the pin fetches nothing; a cached
# archive that is not the pin is fetched again; a complete tool-cache directory fetches nothing.
# The real downloads from nora are the jobs of .github/workflows/nora-tool-selftest.yml.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../nora-tool/nora-tool.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
newest() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${here}/../setup-$1-nora/versions.txt" | awk '{ print $1 }' | sort -V | awk -v p="${2:-}" 'index($0, p) == 1' | tail -1; }

resolve() { # resolve <tool> <spec> [<go.mod content>]
  local f=""
  if [ $# -gt 2 ]; then f="$root/go.mod"; printf '%s\n' "$3" > "$f"; fi
  NORA_TOOL_RESOLVE_ONLY=1 TOOL_VERSION="$2" TOOL_VERSION_FILE="$f" bash "$script" "$1" plan 2>"$root/err"
}
expect() { local got; got=$(resolve "${@:2}") || fail "$2 '$3': $(cat "$root/err")"; [ "$got" = "$1" ] || fail "$2 '$3': got '$got', want '$1'"; }
refuse() { if resolve "${@:2}" >/dev/null; then fail "$2 '$3' resolved, want a refusal"; fi; grep -qF -- "$1" "$root/err" || fail "$2 '$3': no '$1' in: $(cat "$root/err")"; }

for t in go node python uv terraform helm; do
  [ -s "${here}/../setup-$t-nora/versions.txt" ] || fail "no setup-$t-nora/versions.txt"
  # every pin line: version, 64-hex sha256 (python: + its release tag)
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${here}/../setup-$t-nora/versions.txt" | while read -r v s tag rest; do
    [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$t pin '$v' is not X.Y.Z"
    [[ $s =~ ^[0-9a-f]{64}$ ]] || fail "$t $v sha256 '$s'"
    [ "$t" != python ] || [[ $tag =~ ^[0-9]{8}$ ]] || fail "python $v release tag '$tag'"
    if [ -n "$rest" ] || { [ "$t" != python ] && [ -n "$tag" ]; }; then fail "$t $v: extra columns"; fi
  done
  expect "$(newest $t)" $t ""
  expect "$(newest $t)" $t latest
  refuse "only latest, N" $t "lts/*"
  refuse "no pinned version for '9.9.9'" $t 9.9.9
done
g27=$(newest go 1.27.) g26=$(newest go 1.26.)
expect "$g27" go 1.27; expect "$g27" go 1.27.x; expect 1.27.3 go 1.27.3; expect "$g26" go v1.26
refuse "no pinned version for '1.27.99'" go 1.27.99         # exact = exact
expect "$g27" go "" $'module x\n\ngo 1.27.0'                   # go.mod: a floor within its line
expect "$g26" go "" $'module x\n\ngo 1.26'
expect 1.27.4 go "" $'module x\n\ngo 1.27.0\n\ntoolchain go1.27.4'
expect 1.27.4 go "" $'module x\n\ngo 1.26.0 // floor\n\ntoolchain go1.27.3 // CI'  # comments ignored
expect "$g26" go "" $'module x\n\ngo 1.26 // comment'
expect 1.27.4 go "" $'module x\n\n  go 1.26.0\n\ttoolchain go1.27.4'  # leading whitespace
refuse "no pinned Go 1.27.x at or above" go "" $'module x\ngo 1.27.99'
refuse "names no Go version" go "" 'module x'
expect 1.27.3 go 1.27.3 $'module x\ngo 1.26'                   # go-version wins over the file
expect "$(newest node 24.)" node 24; expect "$(newest node 24.)" node 24.x; expect 24.15.0 node 24.15.0; expect "$(newest node 22.)" node 22
expect 1.12.2 terraform 1.12.2; expect 1.17.2 terraform v1.17.2; expect "$(newest terraform 1.15.)" terraform 1.15
expect 3.18.5 helm v3.18.5; expect "$(newest helm 4.)" helm v4
expect 0.13.6 uv 0.13.6
expect "$(newest python 3.12.)" python 3.12; expect "$(newest python 3.8.)" python 3.8; expect 3.10.22 python 3.10; refuse "no pinned version for '3.99'" python 3.99

# install with a stub curl: a fake `helm` pinned in a copy of the actions (the archive layouts
# are the selftest's job). The tool cache and runner temp are directories of this test.
act="$root/action"; mkdir -p "$act/nora-tool" "$act/nora-session" "$act/setup-helm-nora" "$root/bin" "$root/tc" "$root/tmp" "$root/pkg/linux-amd64"
cp "$script" "$act/nora-tool/"; cp "${here}/../nora-session/nora-session.sh" "$act/nora-session/"
printf '#!/bin/sh\necho v9.9.9\n' > "$root/pkg/linux-amd64/helm"; chmod +x "$root/pkg/linux-amd64/helm"
tar -czf "$root/good" -C "$root/pkg" linux-amd64
printf '9.9.9 %s\n' "$(sha256sum "$root/good" | cut -d' ' -f1)" > "$act/setup-helm-nora/versions.txt"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "${*: -1}" >> "$BODY.all" # every call (token exchange too): the "nothing fetched" cases need none
case "${*: -1}" in
  *audience=*) echo '{"value":"eyJ.stub.jwt"}' ;;
  */api/oidc/session) printf '{"token":"nrs_1_stub"}\n200' ;;
  */raw/src/get.helm.sh/helm-v9.9.9-linux-amd64.tar.gz)
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
run() { # run plan|install [cache dir]
  : > "$root/out"; : > "$root/path"
  PATH="$root/bin:$PATH" BODY="$root/body" TOOL_VERSION=9.9.9 RUNNER_TOOL_CACHE="$root/tc" RUNNER_TEMP="$root/tmp" \
  NORA_URL="${NORA_URL:-https://packages.maestra.io}" NORA_AUDIENCE=packages.maestra.io NORA_TOOL_CACHE_DIR="${2:-}" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  GITHUB_PATH="$root/path" GITHUB_ENV="$root/env" GITHUB_OUTPUT="$root/out" bash "$act/nora-tool/nora-tool.sh" helm "$1" > "$root/log" 2>&1
}
dir="$root/tc/helm/9.9.9/x64"
key="nora-tool-helm-9.9.9-linux-x64-$(awk '{ print substr($2, 1, 16) }' "$act/setup-helm-nora/versions.txt")"
if NORA_URL=http://packages.maestra.io run plan; then fail "plain http accepted"; fi
grep -qF "is not https" "$root/log" || fail "no https refusal: $(cat "$root/log")"
run plan || fail "plan: $(cat "$root/log")"
grep -qx "cache-key=$key" "$root/out" || fail "plan key: $(cat "$root/out")"
grep -qx "version=9.9.9" "$root/out" || fail "plan version: $(cat "$root/out")"
[ ! -e "$root/body.all" ] || fail "plan called curl: $(cat "$root/body.all")"

: > "$root/body" # tampered
if run install; then fail "a tampered download was accepted: $(cat "$root/log")"; fi
grep -qF "versions.txt pins" "$root/log" || fail "no sha256 refusal: $(cat "$root/log")"
[ ! -e "$dir" ] && [ ! -e "$dir.complete" ] || fail "unpacked after the refusal"
[ ! -s "$root/path" ] || fail "PATH exported after the refusal"
[ -z "$(ls -A "$root/tmp/nora-tool-helm" 2>/dev/null)" ] || fail "the refused download was left in RUNNER_TEMP"

cp "$root/good" "$root/body"; rm -f "$root/body.calls"
run install "$root/cache" || fail "cache miss: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "cache miss fetched nothing"
[ "$("$dir/helm")" = v9.9.9 ] && [ -f "$dir.complete" ] || fail "not installed into $dir: $(cat "$root/log")"
grep -qx "$dir" "$root/path" || fail "install dir not on PATH: $(cat "$root/path")"
grep -qx "save=true" "$root/out" || fail "cache miss: no save=true"
grep -qx "path=$dir/helm" "$root/out" || fail "no path output: $(cat "$root/out")"
cmp -s "$root/good" "$root/cache/helm-v9.9.9-linux-amd64.tar.gz" || fail "archive not kept for the cache save"

rm -f "$root/body.calls" "$root/body.all"; : > "$root/body"
run plan || fail "plan: $(cat "$root/log")"
grep -qx "cache-key=" "$root/out" || fail "key while installed: $(cat "$root/out")"
run install || fail "installed rerun: $(cat "$root/log")"
grep -q "already in the tool cache" "$root/log" || fail "installed rerun not logged: $(cat "$root/log")"
grep -qx "source=tool-cache" "$root/out" || fail "installed rerun: source output: $(cat "$root/out")"
[ ! -e "$root/body.all" ] || fail "installed rerun called curl: $(cat "$root/body.all")"

rm -rf "$dir" "$dir.complete"
run install "$root/cache" || fail "cache hit: $(cat "$root/log")"   # nora would serve a tampered body
[ ! -e "$root/body.all" ] || fail "cache hit called curl (nora session or fetch): $(cat "$root/body.all")"
grep -q "from the runner cache" "$root/log" || fail "cache hit not logged: $(cat "$root/log")"
! grep -q "save=true" "$root/out" || fail "cache hit asked for a save"
grep -qx "source=runner-cache" "$root/out" || fail "cache hit: source output: $(cat "$root/out")"
[ "$("$dir/helm")" = v9.9.9 ] || fail "cache hit: not installed"

rm -rf "$dir" "$dir.complete"; echo poisoned > "$root/cache/helm-v9.9.9-linux-amd64.tar.gz"; cp "$root/good" "$root/body"
run install "$root/cache" || fail "poisoned cache: $(cat "$root/log")"
[ -s "$root/body.calls" ] || fail "poisoned cache entry was used"
grep -q "not the sha256 pin" "$root/log" || fail "poisoned cache not reported: $(cat "$root/log")"
cmp -s "$root/good" "$root/cache/helm-v9.9.9-linux-amd64.tar.gz" || fail "poisoned cache: fresh archive not kept"
[ "$("$dir/helm")" = v9.9.9 ] && [ -f "$dir.complete" ] || fail "poisoned cache: not installed"
grep -qx "save=true" "$root/out" || fail "poisoned cache: the fresh archive is not saved over the bad one"

rm -f "$dir/helm"; rm -f "$root/body.calls"   # a marker without its executable is not an install
run plan || fail "plan: $(cat "$root/log")"
grep -qx "cache-key=$key" "$root/out" || fail "marker without executable counted as installed: $(cat "$root/out")"
run install "$root/cache" || fail "reinstall: $(cat "$root/log")"
[ "$("$dir/helm")" = v9.9.9 ] || fail "marker without executable: not reinstalled"
echo "nora-tool: all checks passed"
