#!/usr/bin/env bash
#
# Self-check for the static-prefix, static-manifest and static-version-file inputs of
# mcf-build.yml: the folder of the built static (default v2_static/<mcf>) and the files
# the build job expects there (default mf-manifest.json; frontend-core-v2 names
# manifest.json and build-info.json), and the deprecated manifest kind that still
# stands for them. Runs the inline block of the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

static_prog=$(sed -n '/# >>> static/,/# <<< static/p' "$wf" | sed 's/^          //')
[ -n "$static_prog" ] || { echo "static block not found in $wf"; exit 1; }
# static <mcf> <static-prefix> <static-manifest> <static-version-file> [deprecated manifest]
# prints "<static prefix>|<static manifest>|<static version file>|<manifest files>"
static() {
  mcf="$1" STATIC_PREFIX="$2" STATIC_MANIFEST="$3" STATIC_VERSION_FILE="$4" MANIFEST="${5:-}" \
    bash -c "set -eo pipefail; $static_prog"$'\n''echo "$static_prefix|$static_manifest|$static_version_file|$manifest_files"' | tail -n 1
}
fails() { if static "$1" "$2" "$3" "$4" "${5:-}" >/dev/null 2>&1; then echo "FAIL $6: accepted"; exit 1; fi; }

eq "$(static frontend_homepage "" "" "")" "v2_static/frontend_homepage|mf-manifest.json||mf-manifest.json" "defaults: v2_static/<mcf>, mf-manifest.json, no version file"
eq "$(static frontend_core_v2 v2_static/core manifest.json build-info.json)" "v2_static/core|manifest.json|build-info.json|manifest.json build-info.json" "core: manifest.json and build-info.json by name"
eq "$(static frontend_core_v2 v2_static/core "" "")" "v2_static/core|mf-manifest.json||mf-manifest.json" "static-prefix alone keeps mf-manifest.json"
eq "$(static frontend_homepage "" "" version.json)" "v2_static/frontend_homepage|mf-manifest.json|version.json|mf-manifest.json version.json" "version file next to the default manifest"
eq "$(static frontend_homepage "" "" "" mcf)" "v2_static/frontend_homepage|mf-manifest.json||mf-manifest.json" "deprecated manifest: mcf"
eq "$(static frontend_core_v2 v2_static/core "" "" core)" "v2_static/core|manifest.json|build-info.json|manifest.json build-info.json" "deprecated manifest: core stands for the two names"
fails frontend_core_v2 /v2_static/core manifest.json "" "" "static-prefix with a leading slash"
fails frontend_core_v2 v2_static/core/ manifest.json "" "" "static-prefix with a trailing slash"
fails frontend_core_v2 V2_static/core manifest.json "" "" "upper-case static-prefix"
fails frontend_homepage "" js/manifest.json "" "" "static-manifest with a folder"
fails frontend_homepage "" ../manifest.json "" "" "static-manifest outside the folder"
fails frontend_homepage "" "" "a b" "" "two version files"
fails frontend_homepage "" "" "" none "manifest none (hot-test-publish only)"
fails frontend_homepage "" "" "" bogus "unknown manifest kind"
echo "mcf-build static: ok"

# The build job reads the outputs the block sets, not the inputs.
for o in static-prefix static-manifest static-version-file manifest-files; do
  grep -q "echo \"$o=" "$wf" || { echo "FAIL $wf: the version job does not output $o"; exit 1; }
done
grep -q 'needs.version.outputs.manifest-files' "$wf" || { echo "FAIL $wf: the build job does not read manifest-files"; exit 1; }
grep -q 'static-prefix: ${{ needs.version.outputs.static-prefix }}' "$wf" || { echo "FAIL $wf: hot-test is not given static-prefix"; exit 1; }
for o in static-manifest static-version-file; do
  [ "$(grep -c "      $o: \${{ needs.version.outputs.$o }}" "$wf")" = 2 ] || { echo "FAIL $wf: hot-test and e2e-stand are not both given $o"; exit 1; }
done
echo "mcf-build static outputs: ok"
