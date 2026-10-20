#!/usr/bin/env bash
#
# Self-check for the tests/ jobs of mcf-build.yml: the tests/ detection (layout
# lockfile / workspace / none, functional only with the Playwright config and
# tests/package.json, not on excluded branches), the http-server wait (up / never
# up), the functional step summary from Playwright JUnit (errors count as
# failed) and the release gate (image waits for tests-checks and a required
# functional; release, sourcemaps and bake follow image by result). Runs the inline
# blocks of the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"
root=$(mktemp -d); server_pid=""
trap '[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
block() {
  local prog
  prog=$(sed -n "/# >>> $1/,/# <<< $1/p" "$wf" | sed 's/^          //')
  [ -n "$prog" ] || { echo "$1 block not found in $wf" >&2; exit 1; }
  printf '%s\n' "$prog"
}

detect_prog=$(block tests-detect)
# detect <repo dir> <functional event>; prints the step outputs
detect() {
  : > "$root/detect.out"
  (cd "$1" && FUNCTIONAL_EVENT="$2" GITHUB_HEAD_REF=renovate/x GITHUB_OUTPUT="$root/detect.out" \
    bash -c "set -eo pipefail; $detect_prog") > "$root/detect.log" 2>&1 \
    || { echo "FAIL detect exited non-zero in $1"; cat "$root/detect.log"; exit 1; }
  tr '\n' ' ' < "$root/detect.out" | sed 's/ $//'
}
repo() { # repo <name> <file under it>...
  local d="$root/repos/$1"; shift; mkdir -p "$d"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo '{}' > "$d/$f"; done
  echo "$d"
}
cfg=tests/functional/playwright.config.ts
lockfile=$(repo lockfile package.json package-lock.json tests/package.json tests/package-lock.json "$cfg")
workspace=$(repo workspace package.json package-lock.json tests/package.json "$cfg")
none=$(repo none package.json package-lock.json)
no_cfg=$(repo no-config package.json tests/package.json tests/package-lock.json)
cfg_only=$(repo config-only package.json "$cfg")
eq "$(detect "$lockfile" true)" "tests=true tests-layout=lockfile functional=true" "tests/ with its own lockfile"
eq "$(detect "$workspace" true)" "tests=true tests-layout=workspace functional=true" "tests/ as a root workspace"
eq "$(detect "$none" true)" "tests=false tests-layout=none functional=false" "no tests/"
eq "$(detect "$no_cfg" true)" "tests=true tests-layout=lockfile functional=false" "tests/ without the functional config"
eq "$(detect "$lockfile" false)" "tests=true tests-layout=lockfile functional=false" "excluded branch"
grep -q 'renovate/x' "$root/detect.log" || { echo "FAIL excluded branch is not named in the log"; exit 1; }
eq "$(detect "$cfg_only" true)" "tests=false tests-layout=none functional=false" "config without tests/package.json"
grep -q '^::warning::' "$root/detect.log" || { echo "FAIL config without tests/package.json emits no ::warning::"; exit 1; }
# shellcheck disable=SC2016 # the expression is matched literally
grep -qF "FUNCTIONAL_EVENT: \${{ !startsWith(github.head_ref, 'renovate/') && github.head_ref != 'LocalizationPull' }}" "$wf" \
  || { echo "FAIL FUNCTIONAL_EVENT does not exclude renovate/* and LocalizationPull"; exit 1; }
echo "functional detect: ok"

# Every restore of the root cache must list the same paths as its save, or it misses.
keys=$(grep -c 'key: mcf-node-modules-' "$wf")
aliases=$(grep -c 'path: \*root-node-modules$' "$wf")
eq "$aliases" "$keys" "root cache steps with the shared path list (one save + all restores but the anchor)"
if grep -nE '^ +path: node_modules$' "$wf"; then echo "FAIL a root cache step lists node_modules alone"; exit 1; fi
if grep -nF 'npx --no playwright --version' "$wf"; then echo "FAIL npx eats --version: the browser key gets npm's version"; exit 1; fi
grep -qF "v=\$(node -p \"require('@playwright/test/package.json').version\" || true)" "$wf" \
  || { echo "FAIL the browser cache key does not read @playwright/test/package.json"; exit 1; }
echo "functional cache paths: ok"

# job <name> <key>: the value of a top-level key (needs, if) of a job in the workflow
job() { awk -v j="  $1:" -v k="    $2: " '$0 == j { on = 1; next } on && /^  [a-z]/ { exit }
  on && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$wf"; }
eq "$(job image needs)" "[version, checks, test, build, tests-checks, functional]" "image needs"
eq "$(job image if)" "\${{ !cancelled() && needs.version.outputs.publish == 'true' && needs.checks.result == 'success' && needs.test.result == 'success' && needs.build.result == 'success' && (needs.version.outputs.tests != 'true' || needs.tests-checks.result == 'success') && (!inputs.functional-required || needs.version.outputs.functional != 'true' || needs.functional.result == 'success') }}" "image waits for tests-checks and a required functional"
eq "$(job functional continue-on-error)" "\${{ !inputs.functional-required }}" "functional failure is advisory only when not required"
eq "$(job release if)" "\${{ !cancelled() && needs.image.result == 'success' }}" "release follows image, not success() of skipped jobs"
eq "$(job sourcemaps if)" "\${{ !cancelled() && needs.release.result == 'success' }}" "sourcemaps follows release"
eq "$(job bake if)" "\${{ !cancelled() && needs.release.result == 'success' && needs.version.outputs.bake == 'true' }}" "bake follows release"
echo "functional release gate: ok"

wait_prog=$(block functional-wait)
# wait_for <url> <timeout>; prints "exit=<code>"
wait_for() {
  local rc=0
  BASE_URL="$1" SERVER_WAIT_TIMEOUT="$2" SERVER_LOG="$root/server.log" \
    bash -c "set -eo pipefail; $wait_prog" > "$root/wait.log" 2>&1 || rc=$?
  echo "exit=$rc"
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
mkdir -p "$root/www/v2_static/frontend_x"; echo '<html></html>' > "$root/www/v2_static/frontend_x/index.html"
echo 'server log line' > "$root/server.log"
port=$(free_port)
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$root/www" >/dev/null 2>&1 &
server_pid=$!
eq "$(wait_for "http://127.0.0.1:$port" 10)" "exit=0" "server comes up"
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
eq "$(wait_for "http://127.0.0.1:$port" 2)" "exit=1" "server never up"
grep -q '^::error::http-server did not answer' "$root/wait.log" || { echo "FAIL timeout emits no ::error::"; cat "$root/wait.log"; exit 1; }
grep -q 'server log line' "$root/wait.log" || { echo "FAIL timeout does not print the server log"; exit 1; }
echo "functional wait: ok"

summary_prog=$(block functional-summary)
# summary <junit fixture name|-> <outcome> <required> [log]; prints the summary
summary() {
  local junit="$root/missing.xml"
  [ "$1" = - ] || junit="$root/junit/$1.xml"
  : > "$root/summary.md"
  JUNIT="$junit" LOG="${4:-$root/missing.log}" OUTCOME="$2" REQUIRED="$3" GITHUB_STEP_SUMMARY="$root/summary.md" \
    bash -c "set -eo pipefail; $summary_prog" || { echo "FAIL summary exited non-zero for $1"; exit 1; }
  cat "$root/summary.md"
}
has() { grep -qF -- "$2" <<<"$1" || { printf 'FAIL %s: no line %s\n%s\n' "$3" "$2" "$1"; exit 1; }; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then printf 'FAIL %s: unexpected %s\n%s\n' "$3" "$2" "$1"; exit 1; fi; }
mkdir -p "$root/junit"
case_ok() { printf '<testcase name="%s" classname="%s" time="1.5"><system-out>ok</system-out></testcase>\n' "$1" "$2"; }
suites() { # suites <name> <testsuites attributes> <testcases...>
  local n=$1 attrs=$2; shift 2
  { echo "<testsuites id=\"\" name=\"\" $attrs>"; echo '<testsuite name="a.test.ts" hostname="chromium">'
    printf '%s\n' "$@"; echo '</testsuite>'; echo '</testsuites>'; } > "$root/junit/$n.xml"
}
suites green 'tests="2" failures="0" skipped="0" errors="0" time="3.25"' \
  "$(case_ok 'list › loads' a.test.ts)" "$(case_ok 'list › filters' a.test.ts)"
suites failures 'tests="3" failures="1" skipped="0" errors="0" time="9"' \
  "$(case_ok 'list › loads' a.test.ts)" \
  '<testcase name="list › saves" classname="a.test.ts" time="4"><failure message="expect" type="expect.toBe">x</failure></testcase>' \
  '<testcase name="list › flaky" classname="a.test.ts" time="2"><flakyFailure message="m" type="FAILURE"><stackTrace>s</stackTrace></flakyFailure></testcase>'
suites errors 'tests="1" failures="0" skipped="0" errors="1" time="6"' \
  '<testcase name="smoke › Webhooks list page loads" classname="smoke/smoke.test.ts" time="1"><error message="page.goto: net::ERR_CONNECTION_REFUSED" type="Error">x</error></testcase>'
suites skipped 'tests="3" failures="0" skipped="2" errors="0" time="1"' \
  "$(case_ok 'list › loads' a.test.ts)" \
  '<testcase name="list › later" classname="a.test.ts" time="0"><skipped/></testcase>' \
  '<testcase name="list › never" classname="a.test.ts" time="0"><skipped/></testcase>'
printf '  1 flaky\n    [chromium] › a.test.ts:3:1 › list › filters\n  1 passed (3.2s)\n' > "$root/flaky.log"

out=$(summary green success false "$root/flaky.log")
has "$out" ":white_check_mark: 2 of 2 passed" "all green"
has "$out" "| 2 | 2 | 0 | 1 | 0 | 3.2 s |" "all green, flaky from the line reporter"
has "$out" "not blocking: functional-required is false" "advisory"
out=$(summary green success true)
has "$out" "| 2 | 2 | 0 | 0 | 0 | 3.2 s |" "all green, no log"
hasnt "$out" "not blocking" "required"
out=$(summary failures failure false)
has "$out" ":x: 1 of 3 failed" "failures"
has "$out" "| 3 | 2 | 1 | 1 | 0 | 9.0 s |" "failures, flaky from flakyFailure"
has "$out" "- \`a.test.ts › list › saves\`" "failed test named"
hasnt "$out" "list › loads\`" "passed test not named"
has "$out" "not blocking: functional-required is false" "advisory red"
out=$(summary errors failure true)
has "$out" ":x: 1 of 1 failed" "errors count as failed"
has "$out" "| 1 | 0 | 1 | 0 | 0 | 6.0 s |" "errors-only table"
has "$out" "- \`smoke/smoke.test.ts › smoke › Webhooks list page loads\`" "errored test named"
out=$(summary skipped success false)
has "$out" ":white_check_mark: 1 of 3 passed" "skipped"
has "$out" "| 3 | 1 | 0 | 0 | 2 | 1.0 s |" "skipped table"
out=$(summary green failure false)
has "$out" ":x: \`functional:ci\` failed (failure) with no failed test in the report" "red exit, green report"
out=$(summary - failure false)
has "$out" ":x: no JUnit report at" "no report"
out=$(summary - skipped false)
has "$out" ":x: the tests did not run: an earlier step failed" "run step skipped"
echo "functional summary: ok"
