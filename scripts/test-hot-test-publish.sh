#!/usr/bin/env bash
#
# Self-check for hot-test-publish.yml: the stand names (host, bucket folder, mcf
# defaults, the inputs the ResourceSet template also rejects), the manifest
# override (the PR manifest byte for byte) and the route wait (200 is
# up, anything else until the timeout is not). Runs the inline blocks of the
# reusable workflow itself.
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
