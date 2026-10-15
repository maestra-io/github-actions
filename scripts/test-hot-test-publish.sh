#!/usr/bin/env bash
#
# Self-check for hot-test-publish.yml: the stand names (host, bucket folder, mcf
# defaults, the inputs the ResourceSet template also rejects) and the manifest
# override (publicPath forced, getPublicPath dropped). Runs the inline blocks of
# the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/hot-test-publish.yml"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT

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
{"id":"frontend_homepage","name":"frontend_homepage","metaData":{"name":"frontend_homepage","publicPath":null,"getPublicPath":"function() { return window.externalPublicPath || \"/\" }","remoteEntry":{"name":"remoteEntry.js","path":"","type":"global"}},"shared":[],"remotes":[],"exposes":[]}
JSON
HOT_TEST_URL=https://hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io MCF=frontend_homepage \
  site="$site" overrides="$overrides" bash -c "set -eo pipefail; $manifest_prog"
eq "$(jq -c '.metaData | {publicPath, getPublicPath, remoteEntry: .remoteEntry.name}' "$overrides/mf-manifest.json")" \
  '{"publicPath":"https://hot-test-frontend-homepage-pr-12.testing-env.omicron.maestra.io/v2_static/frontend_homepage/","getPublicPath":null,"remoteEntry":"remoteEntry.js"}' "override manifest"
eq "$(jq -c '{id, shared, remotes, exposes}' "$overrides/mf-manifest.json")" '{"id":"frontend_homepage","shared":[],"remotes":[],"exposes":[]}' "rest of the manifest kept"
echo "hot-test-publish manifest: ok"
