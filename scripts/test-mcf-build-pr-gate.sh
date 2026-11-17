#!/usr/bin/env bash
#
# Self-check for the pr-gate job of mcf-build.yml: it waits for every job that runs on
# pull_request, fails on a failed or cancelled one, passes skipped ones, and counts functional
# and e2e only when their *-required input is true (e2e always on renovate/*). Runs the inline
# block of the workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
# job <name> <key>: the value of a top-level key (needs, if) of a job in the workflow
job() { awk -v j="  $1:" -v k="    $2: " '$0 == j { on = 1; next } on && /^  [a-z]/ { exit }
  on && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$wf"; }

# Every job but pr-gate itself and the publish chain, which never runs on pull_request.
jobs=$(awk '/^jobs:$/ { on = 1; next } on && /^  [a-z][a-z0-9-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$wf" \
  | grep -vxE 'pr-gate|image|deps-image|e2e-image|release|sourcemaps|bake'| paste -sd, - | sed 's/,/, /g')
eq "$(job pr-gate needs)" "[$jobs]" "pr-gate needs every PR job"
# shellcheck disable=SC2016 # the expression is matched literally
eq "$(job pr-gate if)" '${{ always() && github.event_name == '"'pull_request'"' }}' "pr-gate runs on pull_request after any outcome"
eq "$(job pr-gate name)" "pr gate" "check name (rulesets require \`build / pr gate\`)"
gate_env=$(awk '$0 == "  pr-gate:" { on = 1; next } on && /^  [a-z]/ { exit } on' "$wf")
# shellcheck disable=SC2016 # the expressions are matched literally
{
  grep -qxF '          FUNCTIONAL_REQUIRED: ${{ inputs.functional-required }}' <<<"$gate_env" \
    || { echo "FAIL pr-gate FUNCTIONAL_REQUIRED is not the input"; exit 1; }
  grep -qxF '          E2E_REQUIRED: ${{ needs.version.outputs.e2e-required == '"'true'"' }}' <<<"$gate_env" \
    || { echo "FAIL pr-gate E2E_REQUIRED is not the version job's e2e-required (input or renovate/*)"; exit 1; }
  grep -qxF '      e2e-required: ${{ inputs.e2e-required || startsWith(github.head_ref, '"'renovate/'"') }}' "$wf" \
    || { echo "FAIL the version job's e2e-required is not the input or a renovate/* branch"; exit 1; }
}
echo "mcf-build pr-gate wiring: ok"

prog=$(sed -n '/# >>> pr-gate/,/# <<< pr-gate/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "pr-gate block not found in $wf" >&2; exit 1; }
# gate <functional-required> <e2e-required> <job=result>...; prints pass or fail
gate() {
  local fr=$1 er=$2 needs='{}' kv; shift 2
  for kv in "$@"; do needs=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = {result: $v, outputs: {}}' <<<"$needs"); done
  if NEEDS="$needs" FUNCTIONAL_REQUIRED=$fr E2E_REQUIRED=$er bash -c "set -eo pipefail; $prog" >/dev/null 2>&1; then
    echo pass; else echo fail; fi
}
eq "$(gate false false version=success build=success functional=success e2e=success)" pass "all green"
eq "$(gate false false version=success tests-install=skipped hot-test=skipped e2e=skipped)" pass "skipped jobs pass"
eq "$(gate false false version=success build=failure)" fail "a failed job"
eq "$(gate false false version=success checks=cancelled)" fail "a cancelled job"
eq "$(gate false false build=success functional=failure e2e=failure)" pass "advisory functional and e2e"
eq "$(gate false false build=success functional=cancelled e2e=cancelled)" pass "advisory functional and e2e cancelled"
eq "$(gate true false build=success functional=failure e2e=failure)" fail "required functional"
eq "$(gate false true build=success functional=failure e2e=failure)" fail "required e2e"
eq "$(gate true true build=success functional=skipped e2e=skipped)" pass "required but skipped"
# renovate/* (e2e-required from the version job, functional-required as the repo sets it)
eq "$(gate false true version=success build=success functional=success e2e=failure)" fail "renovate/*: red e2e"
eq "$(gate false true version=success build=success e2e=cancelled)" fail "renovate/*: cancelled e2e"
eq "$(gate false true version=success build=success e2e-stand=success e2e=skipped)" pass "renovate/*: e2e skipped (no route)"
eq "$(gate false true version=success build=success functional=failure e2e=success)" pass "renovate/*: functional stays advisory when not required"
echo "mcf-build pr-gate verdict: ok"
