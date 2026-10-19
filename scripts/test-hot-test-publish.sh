#!/usr/bin/env bash
#
# Self-check for hot-test-publish.yml: the stand names (host, bucket folder, mcf
# defaults, the inputs the ResourceSet template also rejects), the manifest
# override (the PR manifest byte for byte), the route wait (200 is
# up, anything else until the timeout is not), the release bucket check (every
# release manifest of the entry but the PR's own is the same through the stand and
# under base-static-url, else the step fails) and the summary it leads to. Runs the
# inline blocks of the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/hot-test-publish.yml"
root=$(mktemp -d); server_pid=""
trap '[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

names_prog=$(sed -n '/# >>> names/,/# <<< names/p' "$wf" | sed 's/^          //')
[ -n "$names_prog" ] || { echo "names block not found in $wf"; exit 1; }
# names <repo input> <pr input> <mcf input> [event pr]
names() {
  REPO="$1" PR_NUMBER="$2" MCF="$3" EVENT_PR_NUMBER="${4:-}" HOT_TEST_DOMAIN=testing-env.omicron.maestra.io \
    GITHUB_REPOSITORY=maestra-io/frontend-homepage \
    bash -c "set -eo pipefail; $names_prog"$'\n''echo "$host $name $mcf"'
}
fails() { if names "$1" "$2" "$3" "${4:-}" >/dev/null 2>&1; then echo "FAIL $5: accepted"; exit 1; fi; }

eq "$(names frontend-homepage 12 frontend_homepage)" "hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-12 frontend_homepage" "explicit inputs"
eq "$(names "" "" "" 7)" "hot-test-frontend-homepage-pr-7.testing-env.omicron.maestra.io hot-test-frontend-homepage-pr-7 frontend_homepage" "defaults: repository, event PR, repo with _"
eq "$(names frontend-core-v2 3 "")" "hot-test-frontend-core-v2-pr-3.testing-env.omicron.maestra.io hot-test-frontend-core-v2-pr-3 frontend_core_v2" "mcf default from repo"
fails "Frontend-Homepage" 1 "" "" "upper-case repo"
fails "frontend.homepage" 1 "" "" "dot in repo"
fails "a/b" 1 "" "" "slash in repo"
fails frontend-homepage "" "" "" "no PR number"
fails frontend-homepage 12x "" "" "PR number with letters"
fails frontend-homepage 12 "x-y" "" "mcf with -"
fails frontend-services 12 "" "" "repo containing -services"
echo "hot-test-publish names: ok"

manifest_prog=$(sed -n '/# >>> manifest/,/# <<< manifest/p' "$wf" | sed 's/^          //')
[ -n "$manifest_prog" ] || { echo "manifest block not found in $wf"; exit 1; }
site="$root/site"; overrides="$root/overrides/manifests"; mkdir -p "$site/v2_static/frontend_homepage" "$overrides"
cat > "$site/v2_static/frontend_homepage/mf-manifest.json" <<'JSON'
{"id":"frontend_homepage","name":"frontend_homepage","metaData":{"name":"frontend_homepage","publicPath":null,"getPublicPath":"function() { return window.externalPublicPath || \"/\" }","remoteEntry":{"name":"v2_static/frontend_homepage/js/remoteEntry.js","path":"","type":"global"}},"shared":[],"remotes":[],"exposes":[]}
JSON
HOT_TEST_URL=https://hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io MCF=frontend_homepage \
  site="$site" overrides="$overrides" bash -c "set -eo pipefail; $manifest_prog"
cmp -s "$site/v2_static/frontend_homepage/mf-manifest.json" "$overrides/mf-manifest.json" \
  || { echo "FAIL override manifest differs from the PR manifest"; exit 1; }
echo "hot-test-publish manifest: ok"

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
# release <stand url> <base-static-url>; prints the step outputs and "exit=<code>"
release() {
  : > "$root/release.out"; rc=0
  URL="$1" MCF=frontend_homepage BASE_STATIC_URL="$2" RUNNER_TEMP="$root" GITHUB_OUTPUT="$root/release.out" \
    bash -c "set -eo pipefail; $release_prog" > "$root/release.log" 2>&1 || rc=$?
  { tr '\n' ' ' < "$root/release.out"; echo "exit=$rc"; }
}
# The entry list holds this PR's MCF (no release manifest anywhere: it must be skipped) and two others.
mkdir -p "$root/site/entry"
jq -n '[{id: "frontend_billing", metaData: {remoteEntry: {name: "v2_static/frontend_billing/js/b-1.js"}}},
  {id: "frontend_homepage", metaData: {remoteEntry: {name: "v2_static/frontend_homepage/js/remoteEntry.js"}}},
  {id: "frontend_staff", metaData: {remoteEntry: {name: "v2_static/frontend_staff/js/s-1.js"}}}]' \
  > "$root/site/entry/mcf-manifests.json"
put() { mkdir -p "$(dirname "$www/$1")"; echo "$2" > "$www/$1"; } # <path under www> <content>
core_path=v2_static/core/manifest.json
staff_path=v2_static/frontend_staff/mf-manifest.json
for d in base stand other partial; do
  put "$d/$core_path" '{"main":[{"path":"v2_static/core/main-1.js"}]}'
  put "$d/v2_static/frontend_billing/mf-manifest.json" '{"id":"frontend_billing","v":1}'
done
for d in base stand; do put "$d/$staff_path" '{"id":"frontend_staff","v":1}'; done
put "other/$staff_path" '{"id":"frontend_staff","v":2}'
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
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
echo "hot-test-publish release: ok"

summary_prog=$(sed -n '/# >>> summary/,/# <<< summary/p' "$wf" | sed 's/^          //')
[ -n "$summary_prog" ] || { echo "summary block not found in $wf"; exit 1; }
# summary <route up> <release ok> <release status> [code]; prints the summary body
summary() {
  : > "$root/summary.md"
  URL=https://stand SHA=abc1234 MCF=frontend_homepage OK=true WAITED=30 ROUTE_UP="$1" \
    RELEASE_OK="$2" RELEASE_STATUS="$3" RELEASE_CODE="${4:-200}" RELEASE_PATH="$staff_path" \
    RELEASE_STAND="https://stand/$staff_path" RELEASE_BASE="https://base/$staff_path" \
    FAILED_STATIC=false FAILED_ENTRY=false FAILED_TELEPORT=false FAILED_UPLOAD=false \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=maestra-io/frontend-homepage GITHUB_RUN_ID=1 \
    GITHUB_STEP_SUMMARY="$root/summary.md" bash -c "set -eo pipefail; $summary_prog"
  sed -n 2p "$root/summary.md"
}
case "$(summary true true same)" in ":white_check_mark: "*) ;; *) echo "FAIL summary: same release bucket is not ✅"; exit 1;; esac
case "$(summary false false "")" in ":warning: "*) ;; *) echo "FAIL summary: route timeout is not ⚠️"; exit 1;; esac
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
