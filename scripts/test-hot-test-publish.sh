#!/usr/bin/env bash
#
# Self-check for hot-test-publish.yml: the stand names (host, bucket folder, mcf, static-prefix
# and stand-prefix defaults, the inputs the ResourceSet template also rejects), the manifest
# override (the PR manifest byte for byte; none with manifest: none), the route wait (200 is
# up, anything else until the timeout is not), the release bucket check (every
# release manifest of the entry but the PR's own is the same through the stand and
# under base-static-url, else the step fails; with manifest: none the PR's own MCF is
# a released one too) and the summary it leads to. Runs the inline blocks of the
# reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/hot-test-publish.yml"
root=$(mktemp -d); server_pid=""
trap '[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

names_prog=$(sed -n '/# >>> names/,/# <<< names/p' "$wf" | sed 's/^          //')
[ -n "$names_prog" ] || { echo "names block not found in $wf"; exit 1; }
# names <repo input> <pr input> <mcf input> [event pr] [static-prefix input] [manifest input]
# prints "<host> <name> <mcf> <static prefix> <manifest>"
names() {
  REPO="$1" PR_NUMBER="$2" MCF="$3" EVENT_PR_NUMBER="${4:-}" STATIC_PREFIX="${5:-}" MANIFEST="${6:-}" \
    HOT_TEST_DOMAIN=testing-env.omicron.maestra.io GITHUB_REPOSITORY=maestra-io/frontend-homepage \
    bash -c "set -eo pipefail; $names_prog"$'\n''echo "$host $name $mcf $static_prefix $manifest"'
}
fails() { if names "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" >/dev/null 2>&1; then echo "FAIL $7: accepted"; exit 1; fi; }

eq "$(names frontend-homepage 12 frontend_homepage)" "hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-12 frontend_homepage v2_static/frontend_homepage mcf" "explicit inputs"
eq "$(names "" "" "" 7)" "hot-test-frontend-homepage-pr-7.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-7 frontend_homepage v2_static/frontend_homepage mcf" "defaults: repository, event PR, repo with _"
eq "$(names frontend-core-v2 3 "")" "hot-test-frontend-core-v2-pr-3.testing-env.omicron.maestra.io hot-test-frontend-core-v2-pr-3 frontend_core_v2 v2_static/frontend_core_v2 mcf" "mcf default from repo"
eq "$(names frontend 4 "" "" public none)" "hot-test-frontend-pr-4.testing-env.omicron.maestra.io hot-test-frontend-pr-4 frontend public none" "legacy monorepo: own files in public/, no manifest"
eq "$(names frontend-core-v2 3 "" "" v2_static/core)" "hot-test-frontend-core-v2-pr-3.testing-env.omicron.maestra.io hot-test-frontend-core-v2-pr-3 frontend_core_v2 v2_static/core mcf" "static-prefix with a slash"
eq "$(names frontend-core-v2 3 "" "" v2_static/core core)" "hot-test-frontend-core-v2-pr-3.testing-env.omicron.maestra.io hot-test-frontend-core-v2-pr-3 frontend_core_v2 v2_static/core core" "core: own files in v2_static/core, core manifest"
fails "Frontend-Homepage" 1 "" "" "" "" "upper-case repo"
fails "frontend.homepage" 1 "" "" "" "" "dot in repo"
fails "a/b" 1 "" "" "" "" "slash in repo"
fails frontend-homepage "" "" "" "" "" "no PR number"
fails frontend-homepage 12x "" "" "" "" "PR number with letters"
fails frontend-homepage 12 "x-y" "" "" "" "mcf with -"
fails frontend-services 12 "" "" "" "" "repo containing -services"
fails frontend 4 "" "" /public "" "static-prefix with a leading slash"
fails frontend 4 "" "" public/ "" "static-prefix with a trailing slash"
fails frontend 4 "" "" Public "" "upper-case static-prefix"
fails frontend 4 "" "" public bogus "unknown manifest kind"
# prefixed <stand-prefix input> <repo> <pr>; prints "<url> <name>"
prefixed() {
  REPO="$2" PR_NUMBER="$3" STAND_PREFIX="$1" HOT_TEST_DOMAIN=testing-env.omicron.maestra.io \
    bash -c "set -eo pipefail; $names_prog"$'\n''echo "https://$host $name"'
}
eq "$(prefixed "" frontend-homepage 12)" "https://hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-12" "default stand-prefix is the old name"
eq "$(prefixed hot-test frontend-homepage 12)" "https://hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-12" "explicit hot-test prefix"
eq "$(prefixed e2e frontend-homepage 12)" "https://e2e-frontend-homepage-pr-12.testing-env.omicron.maestra.io e2e-frontend-homepage-pr-12" "e2e stand"
for bad in E2E e2e- -e2e e_2e e2e/x "e2e x"; do
  if prefixed "$bad" frontend-homepage 12 >/dev/null 2>&1; then echo "FAIL stand-prefix '$bad': accepted"; exit 1; fi
done
grep -qF "prefix=\"\${STAND_PREFIX:-hot-test}\"" "$wf" || { echo "FAIL the names block does not default stand-prefix to hot-test"; exit 1; }
# shellcheck disable=SC2016 # the expression is matched literally
grep -qF 'name: ${{ inputs.stand-prefix }}' "$wf" || { echo "FAIL the environment is not named after stand-prefix"; exit 1; }

pages_prog=$(sed -n '/# >>> pages/,/# <<< pages/p' "$wf" | sed 's/^          //')
[ -n "$pages_prog" ] || { echo "pages block not found in $wf"; exit 1; }
pages() { PAGES="$1" bash -c "set -eo pipefail; $pages_prog"$'\n''echo "$pages"'; }
eq "$(pages "")" "[]" "no pages"
eq "$(pages $'standard-blocks /email-editor/common-block-templates-preview?standardFlexBlocks=true\n')" \
  '[{"name":"standard-blocks","path":"/email-editor/common-block-templates-preview?standardFlexBlocks=true"}]' "one page, YAML block newline"
eq "$(pages $'  a /x\n\nb /y/z?q=1&r=%20\n')" '[{"name":"a","path":"/x"},{"name":"b","path":"/y/z?q=1&r=%20"}]' "two pages, indent and a blank line"
for bad in "Std /x" "a- /x" "a x" "a" "a /x y" 'a /x"y' $'a /x\na /y'; do
  if pages "$bad" >/dev/null 2>&1; then echo "FAIL page '$bad': accepted"; exit 1; fi
done
# shellcheck disable=SC2016 # the expression is matched literally
grep -qF 'name: ${{ inputs.stand-prefix }}-${{ matrix.page.name }}' "$wf" || { echo "FAIL the page environment is not <stand-prefix>-<name>"; exit 1; }
echo "hot-test-publish pages: ok"
grep -qF "route: \${{ steps.route.outputs.up == 'true' }}" "$wf" || { echo "FAIL the job does not output route"; exit 1; }
echo "hot-test-publish names: ok"

manifest_prog=$(sed -n '/# >>> manifest/,/# <<< manifest/p' "$wf" | sed 's/^          //')
[ -n "$manifest_prog" ] || { echo "manifest block not found in $wf"; exit 1; }
site="$root/site"; overrides="$root/overrides/manifests"; mkdir -p "$site/v2_static/frontend_homepage" "$overrides"
cat > "$site/v2_static/frontend_homepage/mf-manifest.json" <<'JSON'
{"id":"frontend_homepage","name":"frontend_homepage","metaData":{"name":"frontend_homepage","publicPath":null,"getPublicPath":"function() { return window.externalPublicPath || \"/\" }","remoteEntry":{"name":"v2_static/frontend_homepage/js/remoteEntry.js","path":"","type":"global"}},"shared":[],"remotes":[],"exposes":[]}
JSON
STATIC_PREFIX=v2_static/frontend_homepage MANIFEST=mcf \
  site="$site" overrides="$overrides" bash -c "set -eo pipefail; $manifest_prog"
cmp -s "$site/v2_static/frontend_homepage/mf-manifest.json" "$overrides/mf-manifest.json" \
  || { echo "FAIL override manifest differs from the PR manifest"; exit 1; }
rm "$overrides/mf-manifest.json"
STATIC_PREFIX=public MANIFEST=none \
  site="$site" overrides="$overrides" bash -c "set -eo pipefail; $manifest_prog"
[ -z "$(ls -A "$overrides")" ] || { echo "FAIL manifest: none wrote an override: $(ls "$overrides")"; exit 1; }
mkdir -p "$site/v2_static/core"
echo '{"main":[{"path":"v2_static/core/main-1.js","integrity":"sha384-x"}]}' > "$site/v2_static/core/manifest.json"
echo '{"buildVersion":"1.1.1","buildTimestamp":1,"lastHotfix":null}' > "$site/v2_static/core/build-info.json"
STATIC_PREFIX=v2_static/core MANIFEST=core \
  site="$site" overrides="$overrides" bash -c "set -eo pipefail; $manifest_prog"
cmp -s "$site/v2_static/core/manifest.json" "$overrides/../core-manifest.json" \
  || { echo "FAIL core: override core-manifest.json differs from the PR manifest"; exit 1; }
cmp -s "$site/v2_static/core/build-info.json" "$overrides/../core-build-info.json" \
  || { echo "FAIL core: override core-build-info.json differs from the PR build-info"; exit 1; }
[ -z "$(ls -A "$overrides")" ] || { echo "FAIL manifest: core wrote an MCF override: $(ls "$overrides")"; exit 1; }
echo "hot-test-publish manifest: ok"

core_entry_prog=$(sed -n '/# >>> core-entry/,/# <<< core-entry/p' "$wf" | sed 's/^            //')
[ -n "$core_entry_prog" ] || { echo "core-entry block not found in $wf"; exit 1; }
mkdir -p "$site/entry"
echo '<script src="https://stand/v2_static/core/main-1.js" integrity="sha384-x"></script>' > "$site/entry/index.html"
STATIC_PREFIX=v2_static/core site="$site" bash -c "set -eo pipefail; $core_entry_prog" >/dev/null \
  || { echo "FAIL core-entry: index.html with the PR chunk rejected"; exit 1; }
echo '<script src="https://stand/v2_static/core/main-0.js"></script>' > "$site/entry/index.html"
if STATIC_PREFIX=v2_static/core site="$site" bash -c "set -eo pipefail; $core_entry_prog" >/dev/null 2>&1; then
  echo "FAIL core-entry: index.html without the PR chunk accepted"; exit 1
fi
echo "hot-test-publish core entry: ok"

route_prog=$(sed -n '/# >>> route/,/# <<< route/p' "$wf" | sed 's/^          //')
[ -n "$route_prog" ] || { echo "route block not found in $wf"; exit 1; }
# route <url> <timeout> <interval>; prints the step outputs "up=... waited=..."
route() {
  : > "$root/route.out"
  URL="$1" ROUTE_WAIT_TIMEOUT="$2" ROUTE_WAIT_INTERVAL="$3" GITHUB_OUTPUT="$root/route.out" \
    bash -c "set -eo pipefail; $route_prog" > "$root/route.log" 2>&1 || { echo "FAIL route step exited non-zero for $1"; cat "$root/route.log"; exit 1; }
  tr '\n' ' ' < "$root/route.out" | sed 's/ $//'
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

www="$root/www"; mkdir -p "$www/entry"; echo '<html>stand</html>' > "$www/entry/index.html"
port=$(free_port)
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$www" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -sf -o /dev/null "http://127.0.0.1:$port/entry/index.html" && break; sleep 0.1; done
eq "$(route "http://127.0.0.1:$port" 10 1)" "up=true waited=0" "route answers 200"
eq "$(route "http://127.0.0.1:$port/missing" 2 1)" "up=false waited=2" "404 is not up"
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
eq "$(route "http://127.0.0.1:$port" 2 1)" "up=false waited=2" "closed port is not up"
grep -q '^::warning::' "$root/route.log" || { echo "FAIL route timeout emits no ::warning::"; cat "$root/route.log"; exit 1; }
echo "hot-test-publish route: ok"

release_prog=$(sed -n '/# >>> release/,/# <<< release/p' "$wf" | sed 's/^          //')
[ -n "$release_prog" ] || { echo "release block not found in $wf"; exit 1; }
# release <stand url> <base-static-url> [static prefix, default v2_static/frontend_homepage]; prints the step outputs and "exit=<code>"
release() {
  : > "$root/release.out"; rc=0
  URL="$1" STATIC_PREFIX="${3:-v2_static/frontend_homepage}" BASE_STATIC_URL="$2" RUNNER_TEMP="$root" GITHUB_OUTPUT="$root/release.out" \
    bash -c "set -eo pipefail; $release_prog" > "$root/release.log" 2>&1 || rc=$?
  { tr '\n' ' ' < "$root/release.out"; echo "exit=$rc"; }
}
# The entry list holds this PR's MCF (released only on base and stand: skipped as the PR's
# own under static-prefix, checked when the PR's files live elsewhere) and two others.
mkdir -p "$root/site/entry"
jq -n '[{id: "frontend_billing", metaData: {remoteEntry: {name: "v2_static/frontend_billing/js/b-1.js"}}},
  {id: "frontend_homepage", metaData: {remoteEntry: {name: "v2_static/frontend_homepage/js/remoteEntry.js"}}},
  {id: "frontend_staff", metaData: {remoteEntry: {name: "v2_static/frontend_staff/js/s-1.js"}}}]' \
  > "$root/site/entry/mcf-manifests.json"
put() { mkdir -p "$(dirname "$www/$1")"; echo "$2" > "$www/$1"; } # <path under www> <content>
core_path=v2_static/core/manifest.json
staff_path=v2_static/frontend_staff/mf-manifest.json
homepage_path=v2_static/frontend_homepage/mf-manifest.json
for d in base stand other partial; do
  put "$d/$core_path" '{"main":[{"path":"v2_static/core/main-1.js"}]}'
  put "$d/v2_static/frontend_billing/mf-manifest.json" '{"id":"frontend_billing","v":1}'
done
for d in base stand; do put "$d/$staff_path" '{"id":"frontend_staff","v":1}'; put "$d/$homepage_path" '{"id":"frontend_homepage","v":1}'; done
put "other/$staff_path" '{"id":"frontend_staff","v":2}'
put "other/$homepage_path" '{"id":"frontend_homepage","v":1}'
# A stand with another core and the released MCFs: the core PR's own, another PR's drift.
put "coreother/$core_path" '{"main":[{"path":"v2_static/core/main-2.js"}]}'
put "coreother/v2_static/frontend_billing/mf-manifest.json" '{"id":"frontend_billing","v":1}'
put "coreother/$staff_path" '{"id":"frontend_staff","v":1}'
put "coreother/$homepage_path" '{"id":"frontend_homepage","v":1}'
port=$(free_port)
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$www" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -sf -o /dev/null "http://127.0.0.1:$port/base/$core_path" && break; sleep 0.1; done
srv="http://127.0.0.1:$port"
eq "$(release "$srv/stand" "$srv/base/")" "status=same path= code=200 stand=$srv/stand/ base=$srv/base/ exit=0" "same release bucket"
eq "$(release "$srv/other" "$srv/base")" "status=differs path=$staff_path code=200 stand=$srv/other/$staff_path base=$srv/base/$staff_path exit=1" "same core, another MCF manifest"
grep -q '^::error::.*baseStaticDomain' "$root/release.log" || { echo "FAIL release mismatch emits no ::error::"; cat "$root/release.log"; exit 1; }
eq "$(release "$srv/partial" "$srv/base")" "status=missing path=$staff_path code=404 stand=$srv/partial/$staff_path base=$srv/base/$staff_path exit=1" "stand without an MCF manifest"
eq "$(release "$srv/stand" "$srv/missing")" "exit=1" "unreadable base-static-url"
eq "$(release "$srv/stand" "$srv/base/" public)" "status=same path= code=200 stand=$srv/stand/ base=$srv/base/ exit=0" "own files in public/: every MCF is released, same bucket"
eq "$(release "$srv/partial" "$srv/base" public)" "status=missing path=$homepage_path code=404 stand=$srv/partial/$homepage_path base=$srv/base/$homepage_path exit=1" "own files in public/: the MCF named after the repo is checked too"
eq "$(release "$srv/coreother" "$srv/base" v2_static/core)" "status=same path= code=200 stand=$srv/coreother/ base=$srv/base/ exit=0" "core PR: the stand's own core is skipped, the MCFs match"
eq "$(release "$srv/coreother" "$srv/base")" "status=differs path=$core_path code=200 stand=$srv/coreother/$core_path base=$srv/base/$core_path exit=1" "MCF PR: another core on the stand"
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
echo "hot-test-publish release: ok"

summary_prog=$(sed -n '/# >>> summary/,/# <<< summary/p' "$wf" | sed 's/^          //')
[ -n "$summary_prog" ] || { echo "summary block not found in $wf"; exit 1; }
# summary <route up> <release ok> <release status> [code] [static prefix] [stand prefix]; prints the summary body
summary() {
  : > "$root/summary.md"
  PREFIX="${6:-hot-test}" URL=https://stand SHA=abc1234 REPO=frontend-homepage STATIC_PREFIX="${5:-v2_static/frontend_homepage}" OK=true WAITED=30 ROUTE_UP="$1" \
    RELEASE_OK="$2" RELEASE_STATUS="$3" RELEASE_CODE="${4:-200}" RELEASE_PATH="$staff_path" \
    RELEASE_STAND="https://stand/$staff_path" RELEASE_BASE="https://base/$staff_path" \
    FAILED_STATIC=false FAILED_ENTRY=false FAILED_TELEPORT=false FAILED_UPLOAD=false \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=maestra-io/frontend-homepage GITHUB_RUN_ID=1 \
    GITHUB_STEP_SUMMARY="$root/summary.md" bash -c "set -eo pipefail; $summary_prog"
  sed -n 2p "$root/summary.md"
}
body=$(summary true true same)
case "$body" in ":white_check_mark: **Hot-test stand**: "*) ;; *) echo "FAIL summary: same release bucket is not ✅ Hot-test stand"; exit 1;; esac
eq "$(sed -n 1p "$root/summary.md")" "### hot-test stand" "summary heading, default prefix"
summary false false "" 200 v2_static/frontend_homepage e2e >/dev/null
eq "$(sed -n 1p "$root/summary.md")" "### e2e stand" "summary heading, e2e prefix"
grep -qF 'registered in fluxcd for e2e stands' "$root/summary.md" || { echo "FAIL summary: no route on the e2e stand does not name e2e"; exit 1; }
case "$(sed -n 2p "$root/summary.md")" in ":warning: **E2e stand** "*) ;; *) echo "FAIL summary: the e2e body label does not follow the prefix"; exit 1;; esac
if grep -qF 'Hot-test' "$root/summary.md"; then echo "FAIL summary: the e2e stand summary says Hot-test"; exit 1; fi
body=$(summary true true same 200 public; sed -n 4p "$root/summary.md")
case "$body" in *'`/public/` of `frontend-homepage` from this PR'*) ;; *) printf 'FAIL summary: own files and repo are not named\n  got: %s\n' "$body"; exit 1;; esac
body=$(summary false false "")
case "$body" in ":warning: "*'`frontend-homepage` is not registered in fluxcd'*) ;; *) printf 'FAIL summary: route timeout is not ⚠️ naming the repo\n  got: %s\n' "$body"; exit 1;; esac
body=$(summary true false differs)
case "$body" in ":x: "*"(\`baseStaticDomain\` провайдера hot-test) разный, первое расхождение \`$staff_path\`: https://stand/$staff_path ≠ https://base/$staff_path"*) ;;
  *) printf 'FAIL summary: another release bucket\n  got: %s\n' "$body"; exit 1;; esac
body=$(summary true false missing 404)
case "$body" in ":x: "*"стенд не отдал \`$staff_path\` (HTTP 404): https://stand/$staff_path"*) ;;
  *) printf 'FAIL summary: stand without a release manifest\n  got: %s\n' "$body"; exit 1;; esac
case "$body" in *разный*) echo "FAIL summary: a non-200 from the stand is reported as another bucket"; exit 1;; esac
case "$(summary true false "")" in ":x: "*) ;; *) echo "FAIL summary: failed release check is not ❌"; exit 1;; esac
echo "hot-test-publish summary: ok"

if grep -rnE 'backend-host|BACKEND_HOST' "$here/.." --exclude-dir=.git --exclude="$(basename "$0")"; then
  echo "FAIL the removed input backend-host is still referenced"; exit 1
fi
if grep -rnE 'LEGACY_SERVICE_HOS[T]' "$here/.." --exclude-dir=.git; then
  echo "FAIL the builder's legacy service host variable is still referenced"; exit 1
fi
echo "hot-test-publish inputs: ok"
