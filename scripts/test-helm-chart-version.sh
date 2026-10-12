#!/usr/bin/env bash
# push-helm-chart-to-aws-ecr/resolve-version.sh: Chart.yaml by default, VERSION
# overrides, APP_VERSION follows VERSION unless given.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../push-helm-chart-to-aws-ecr/resolve-version.sh"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
printf 'apiVersion: v2\nname: cdp-app-tenant\nversion: 0.2.2\nappVersion: "1.0.0"\n' > "$dir/Chart.yaml"
fails=0
check() { # <case> <expected> <env...>
  local case="$1" want="$2"; shift 2
  local got; got=$(env CHART_PATH="$dir" "$@" "$script" | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then echo "ok   $case"; else echo "FAIL $case: got '$got' want '$want'"; fails=$((fails+1)); fi
}
check "chart.yaml"          "name=cdp-app-tenant version=0.2.2 app-version=1.0.0"
check "version input"       "name=cdp-app-tenant version=4.9296.0 app-version=4.9296.0" VERSION=4.9296.0
check "hotfix prerelease"   "name=cdp-app-tenant version=4.9296.1-hotfix.7 app-version=4.9296.1-hotfix.7" VERSION=4.9296.1-hotfix.7
check "both inputs"         "name=cdp-app-tenant version=4.9296.0 app-version=215efb4" VERSION=4.9296.0 APP_VERSION=215efb4
check "appVersion only"     "name=cdp-app-tenant version=0.2.2 app-version=215efb4" APP_VERSION=215efb4
printf 'apiVersion: v2\nname: noversion\n' > "$dir/Chart.yaml"
if env CHART_PATH="$dir" "$script" >/dev/null 2>&1; then echo "FAIL no version: expected exit 1"; fails=$((fails+1)); else echo "ok   no version fails"; fi
[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
