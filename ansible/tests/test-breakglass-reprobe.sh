#!/usr/bin/env bash
# Runs the "Re-probe break-glass access" step of ansible-os-update.yml (soc-rescan
# job) verbatim against a fake gh. Asserts: the dispatch names the contour and the
# hosts, an uncovered contour dispatches nothing, and neither a missing token nor
# a failed dispatch fails the step. Run: bash ansible/tests/test-breakglass-reprobe.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
yq '.jobs.soc-rescan.steps[] | select(.name == "Re-probe break-glass access on the patched hosts") | .run' \
  .github/workflows/ansible-os-update.yml > "$T/step.sh"
[ -s "$T/step.sh" ] || { echo "FAIL  step not found in the workflow"; exit 1; }

mkdir "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
exit "${GH_RC:-0}"
GH
chmod +x "$T/bin/gh"

fail=0
check() {  # check <desc> <region> <contour> <token> <gh_rc> <want_gh_args|-> <want_summary>
  local desc="$1" out rc
  : > "$T/gh.log"; : > "$T/summary"
  out=$(PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_RC="$5" GITHUB_STEP_SUMMARY="$T/summary" \
        HOSTS='["node-a","node-b"]' REGION="$2" CONTOUR="$3" SOC_TOKEN="$4" bash "$T/step.sh" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then echo "FAIL  $desc: rc=$rc (the step must never fail the run): $out"; fail=1; return; fi
  if [ "$6" = - ]; then
    [ ! -s "$T/gh.log" ] || { echo "FAIL  $desc: gh was called: $(cat "$T/gh.log")"; fail=1; return; }
  else
    grep -qF -- "$6" "$T/gh.log" || { echo "FAIL  $desc: gh args [$(cat "$T/gh.log")] lack [$6]"; fail=1; return; }
  fi
  grep -qF -- "$7" "$T/summary" <(printf '%s\n' "$out") || { echo "FAIL  $desc: no [$7] in the summary or the log"; fail=1; return; }
  echo "ok    $desc"
}

check "omega dispatches"            us omega   tok 0 "workflow run breakglass-verify.yaml --repo maestra-io/soc --ref main -f contour=omega -f hosts=node-a,node-b" "re-probe dispatched"
check "omicron dispatches"          us omicron tok 0 "-f contour=omicron -f hosts=node-a,node-b" "re-probe dispatched"
check "iota is skipped"             us iota    tok 0 - "re-probe skipped"
check "another region is skipped"   eu omega   tok 0 - "re-probe skipped"
check "no token warns, stays green" us omega   ""  0 - "gh workflow run breakglass-verify.yaml --repo maestra-io/soc -f contour=omega -f hosts=node-a,node-b"
check "failed dispatch warns"       us omega   tok 1 "-f contour=omega" "re-probe NOT dispatched"
exit "$fail"
