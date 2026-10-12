#!/usr/bin/env bash
# Chart name/version/appVersion for push-helm-chart-to-aws-ecr: Chart.yaml
# values unless VERSION (and APP_VERSION) override them. APP_VERSION falls back
# to VERSION, then to Chart.yaml. Prints GITHUB_OUTPUT lines.
set -euo pipefail
chart="${CHART_PATH:-.}/Chart.yaml"
name=$(yq e '.name' "$chart")
version="${VERSION:-$(yq e '.version' "$chart")}"
app_version="${APP_VERSION:-${VERSION:-$(yq e '.appVersion' "$chart")}}"
[ -n "$name" ] && [ "$name" != null ] || { echo "::error::$chart has no name" >&2; exit 1; }
[ -n "$version" ] && [ "$version" != null ] || { echo "::error::$chart has no version and no VERSION input" >&2; exit 1; }
printf 'name=%s\nversion=%s\napp-version=%s\n' "$name" "$version" "$app_version"
