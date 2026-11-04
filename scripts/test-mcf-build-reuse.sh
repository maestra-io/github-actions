#!/usr/bin/env bash
#
# Self-check for the release reuse of mcf-build.yml: the tested-marker parser (version job,
# step reuse) finds the pr-gate marker of exactly this tree and Node.js, and the jobs it skips
# are wired to it. Runs the inline block of the workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
prog=$(sed -n '/# >>> tested-marker/,/# <<< tested-marker/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "tested-marker block not found in $wf" >&2; exit 1; }
eval "$prog"

t1=$(printf 'a%.0s' {1..40}); t2=$(printf 'b%.0s' {1..40})
body="**Coverage summary**
| lines | 61% |
<!-- mcf-build-coverage -->
<!-- mcf-tested tree=$t1 node=24.19.0 functional=success run=123 -->"
eq "$(tested_marker "$t1" 24.19.0 <<<"$body")" "success 123" "marker of this tree"
eq "$(tested_marker "$t2" 24.19.0 <<<"$body")" "" "another tree"
eq "$(tested_marker "$t1" 24.20.0 <<<"$body")" "" "another Node.js"
eq "$(tested_marker "$t1" 24.19.0 <<<"no marker here")" "" "no marker"
eq "$(tested_marker "$t1" 24.19.0 </dev/null)" "" "no comments"
eq "$(tested_marker "$t1" 24.19.0 <<<"<!-- mcf-tested tree=$t1 node=24.19.0 functional=skipped run=9 -->")" "skipped 9" "functional skipped"
eq "$(tested_marker "$t1" 24.19.0 <<<"<!-- mcf-tested tree=${t1:0:12} node=24.19.0 functional=success run=9 -->")" "" "short tree"
echo "mcf-build tested-marker: ok"

job() { awk -v j="  $1:" -v k="    $2: " '$0 == j { on = 1; next } on && /^  [a-z]/ { exit }
  on && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$wf"; }
for j in checks test tests-checks; do
  [[ "$(job "$j" if)" == *"needs.version.outputs.reuse != 'true'"* ]] || { echo "FAIL $j does not skip on reuse"; exit 1; }
done
[[ "$(job functional if)" == *"needs.version.outputs.reuse-functional != 'true'"* ]] || { echo "FAIL functional does not skip on reuse-functional"; exit 1; }
img=$(job image if)
[[ "$img" == *"needs.version.outputs.reuse == 'true' || (needs.checks.result == 'success' && needs.test.result == 'success'"* ]] \
  || { echo "FAIL image does not accept reused checks and test"; exit 1; }
[[ "$img" == *"needs.version.outputs.reuse-functional == 'true' || needs.functional.result == 'success'"* ]] \
  || { echo "FAIL image does not accept a reused functional"; exit 1; }
[[ "$img" == *"needs.build.result == 'success'"* ]] || { echo "FAIL image no longer requires build"; exit 1; }
echo "mcf-build reuse wiring: ok"
