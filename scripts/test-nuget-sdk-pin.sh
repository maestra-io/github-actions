#!/usr/bin/env bash
# Self-check for the "pin the build SDK" program inlined in nuget-package-publish.yml:
# the newest installed SDK of the highest target framework major is pinned in a
# temporary global.json, the repo's own file is backed up and its other keys kept,
# an explicit narrower pin and a non-JSON file are left alone, and a global.json
# sdk.version above the target frameworks stays the floor. `dotnet --list-sdks` is a stub.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/nuget-package-publish.yml"
prog=$(sed -n '/# sdk-pin: begin/,/# sdk-pin: end/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "sdk-pin program not found in $wf"; exit 1; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
cat > "$d/bin/dotnet" <<'X'
#!/usr/bin/env bash
[ "$1" = --list-sdks ] || exit 1
printf '%s [/usr/share/dotnet/sdk]\n' 8.0.100 8.0.425 8.0.30 9.0.305 10.0.401
X
chmod +x "$d/bin/dotnet"

case_dir() { rm -rf "$d/w" "$d/backup"; mkdir "$d/w"; : > "$d/out"; }
run() { # $1 = SDK set (versions output); prints the pin result line
  (cd "$d/w" && PATH="$d/bin:$PATH" VERSIONS="$1" BACKUP="$d/backup" GITHUB_OUTPUT="$d/out" bash -eo pipefail -c "$prog")
}
fail() { echo "FAIL: $*"; exit 1; }
sdk() { jq -r '.sdk.version + " " + .sdk.rollForward' "$d/w/global.json"; }

case_dir; run $'8.0.x\n10.0.x' >/dev/null
[ "$(sdk)" = "10.0.401 latestFeature" ] || fail "no global.json, highest net10: got $(sdk)"
[ ! -e "$d/backup" ] || fail "no global.json: nothing to back up"
grep -qx pinned=true "$d/out" || fail "no global.json: pinned output missing"

case_dir; run $'6.0.x\n8.0.x' >/dev/null
[ "$(sdk)" = "8.0.425 latestFeature" ] || fail "highest net8 must pin the newest 8.0 SDK: got $(sdk)"

case_dir; echo '{"sdk":{"version":"8.0.100","rollForward":"latestMajor"},"msbuild-sdks":{"X":"1.0"}}' > "$d/w/global.json"
run '8.0.x' >/dev/null
[ "$(sdk)" = "8.0.425 latestFeature" ] || fail "latestMajor global.json: got $(sdk)"
[ "$(jq -r '."msbuild-sdks".X' "$d/w/global.json")" = 1.0 ] || fail "other global.json keys lost"
jq -e '.sdk.rollForward == "latestMajor"' "$d/backup" >/dev/null || fail "repo global.json not backed up"

case_dir; echo '{"sdk":{"version":"10.0.100","rollForward":"latestMajor"}}' > "$d/w/global.json"
run '8.0.x' >/dev/null
[ "$(sdk)" = "10.0.401 latestFeature" ] || fail "global.json major above the TFMs must stay the floor: got $(sdk)"

case_dir; echo '{"sdk":{"version":"8.0.100","rollForward":"latestFeature"}}' > "$d/w/global.json"
run $'8.0.x\n10.0.x' >/dev/null
if [ "$(sdk)" != "8.0.100 latestFeature" ] || [ -e "$d/backup" ] || grep -q pinned "$d/out"; then fail "explicit pin must be left alone"; fi

case_dir; printf '{ // comment\n "sdk": {"rollForward": "latestMajor"} }\n' > "$d/w/global.json"
run '8.0.x' >/dev/null
if ! grep -q '// comment' "$d/w/global.json" || grep -q pinned "$d/out"; then fail "non-JSON global.json must be left alone"; fi

case_dir; run '' >/dev/null
[ ! -e "$d/w/global.json" ] || fail "no target framework: nothing to pin"

case_dir; run '7.0.x' >/dev/null
[ ! -e "$d/w/global.json" ] || fail "SDK not installed: nothing to pin"

# a dotnet-version override in any setup-dotnet form pins its major
for spec in 8 8.x 8.0 8.0.x 8.0.4xx 8.0.425; do
  case_dir; run "$spec" >/dev/null
  [ "$(sdk)" = "8.0.425 latestFeature" ] || fail "override '$spec' must pin the newest 8.0 SDK: got $( [ -e "$d/w/global.json" ] && sdk || echo none)"
done
case_dir; run $'10.0.401\n8.0.x' >/dev/null
[ "$(sdk)" = "10.0.401 latestFeature" ] || fail "exact 10.0.401 with 8.0.x must pin 10: got $(sdk)"
# dotnet-service-build.yml (test job) runs the same program: the copies must not drift.
copy=$(sed -n '/# sdk-pin: begin/,/# sdk-pin: end/p' "$here/../.github/workflows/dotnet-service-build.yml" | sed 's/^          //')
[ "$copy" = "$prog" ] || { echo "FAIL sdk-pin: dotnet-service-build.yml copy differs from nuget-package-publish.yml"; exit 1; }
# There the SDK steps also serve a test-command run on the runner in a .NET repo, and that
# step runs after the pin (processing-orders built on the image's SDK 11, issues-maestra#1649).
python3 -I - "$here/../.github/workflows/dotnet-service-build.yml" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1]).read()
job = re.search(r"^  test:\n(.*?)^  \S", text, re.S | re.M).group(1)
steps = re.split(r"^      - ", job, flags=re.M)[1:]
def find(pat):
    hits = [i for i, s in enumerate(steps) if re.search(pat, s, re.M)]
    assert len(hits) == 1, f"{pat}: {len(hits)} steps"
    return hits[0]
want = "inputs.docker-test-target == '' && (inputs.test-command == '' || (inputs.test-image == '' && hashFiles('**/*.csproj') != ''))"
sdk = [find(r"^        id: sdk$"), find(r"^        id: sdk-set$"),
       find(r"uses: (actions/setup-dotnet|maestra-io/github-actions/dotnet-nora)@"), find(r"^        id: pin$")]
for i in sdk:
    assert want in steps[i], "SDK step without the test-command condition:\n" + steps[i][:300]
tc = find(r"^          TEST_COMMAND: ")
assert tc > max(sdk), "the test-command step runs before the SDK pin"
assert tc < find(r"name: put the repo's global.json back"), "the test-command step runs after global.json is put back"
PY
echo "nuget-sdk-pin: OK"
