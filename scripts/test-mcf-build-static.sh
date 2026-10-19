#!/usr/bin/env bash
#
# Self-check for the static-prefix and manifest inputs of mcf-build.yml: the folder of
# the built static (default v2_static/<mcf>) and the manifest files the build job
# expects there (mf-manifest.json for mcf, manifest.json and build-info.json for core).
# Runs the inline block of the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

static_prog=$(sed -n '/# >>> static/,/# <<< static/p' "$wf" | sed 's/^          //')
[ -n "$static_prog" ] || { echo "static block not found in $wf"; exit 1; }
# static <mcf> <static-prefix input> <manifest input>; prints "<static prefix> <manifest> <manifest files>"
static() {
  mcf="$1" STATIC_PREFIX="$2" MANIFEST="$3" \
    bash -c "set -eo pipefail; $static_prog"$'\n''echo "$static_prefix $manifest $manifest_files"'
}
fails() { if static "$1" "$2" "$3" >/dev/null 2>&1; then echo "FAIL $4: accepted"; exit 1; fi; }

eq "$(static frontend_homepage "" "")" "v2_static/frontend_homepage mcf mf-manifest.json" "defaults: v2_static/<mcf>, mcf"
eq "$(static frontend_homepage "" mcf)" "v2_static/frontend_homepage mcf mf-manifest.json" "explicit mcf"
eq "$(static frontend_core_v2 v2_static/core core)" "v2_static/core core manifest.json build-info.json" "core: v2_static/core, manifest.json and build-info.json"
eq "$(static frontend_core_v2 v2_static/core "")" "v2_static/core mcf mf-manifest.json" "static-prefix alone keeps the mcf manifest"
fails frontend_core_v2 /v2_static/core core "static-prefix with a leading slash"
fails frontend_core_v2 v2_static/core/ core "static-prefix with a trailing slash"
fails frontend_core_v2 V2_static/core core "upper-case static-prefix"
fails frontend_homepage "" none "manifest none (hot-test-publish only)"
fails frontend_homepage "" bogus "unknown manifest kind"
echo "mcf-build static: ok"

# The build job reads the outputs the block sets, not the inputs.
for o in static-prefix manifest manifest-files; do
  grep -q "echo \"$o=" "$wf" || { echo "FAIL $wf: the version job does not output $o"; exit 1; }
done
grep -q 'needs.version.outputs.manifest-files' "$wf" || { echo "FAIL $wf: the build job does not read manifest-files"; exit 1; }
grep -q 'static-prefix: ${{ needs.version.outputs.static-prefix }}' "$wf" || { echo "FAIL $wf: hot-test is not given static-prefix"; exit 1; }
grep -q 'manifest: ${{ needs.version.outputs.manifest }}' "$wf" || { echo "FAIL $wf: hot-test is not given manifest"; exit 1; }
echo "mcf-build static outputs: ok"
