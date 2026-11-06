#!/usr/bin/env bash
#
# Self-check for the e2e jobs of mcf-build.yml: the tests/e2e/ detection (only with
# tests/package.json, not on excluded branches), the wiring of e2e-stand (the hot-test
# conditions plus tests/e2e/, no input, stand-prefix e2e, the static artifact) and e2e (only
# unless e2e: false, on a stand with a route, advisory unless e2e-required, never holds the image), the
# Vault credentials (step outputs only, never printed), the e2e step summary from
# Playwright JUnit and the release-time e2e-image (its Dockerfile from tests/node_modules, a
# root workspace's hoisted packages copied in, linked local packages by content; release waits
# for it only with tests/e2e/).
# Runs the inline blocks of the reusable workflow itself.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
has() { grep -qF -- "$2" <<<"$1" || { printf 'FAIL %s: no line %s\n%s\n' "$3" "$2" "$1"; exit 1; }; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then printf 'FAIL %s: unexpected %s\n%s\n' "$3" "$2" "$1"; exit 1; fi; }
block() {
  local prog
  prog=$(sed -n "/# >>> $1/,/# <<< $1/p" "$wf" | sed 's/^          //')
  [ -n "$prog" ] || { echo "$1 block not found in $wf" >&2; exit 1; }
  printf '%s\n' "$prog"
}
# job <name> <key>: the value of a top-level key (needs, if) of a job in the workflow
job() { awk -v j="  $1:" -v k="    $2: " '$0 == j { on = 1; next } on && /^  [a-z]/ { exit }
  on && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$wf"; }
# jobtext <name>: every line of a job
jobtext() { awk -v j="  $1:" '$0 == j { on = 1; next } on && /^  [a-z#]/ { exit } on' "$wf"; }

detect_prog=$(block tests-detect)
# detect <repo dir> <playwright event>; prints the step outputs
detect() {
  : > "$root/detect.out"
  (cd "$1" && PLAYWRIGHT_EVENT="$2" GITHUB_HEAD_REF=renovate/x GITHUB_OUTPUT="$root/detect.out" \
    bash -c "set -eo pipefail; $detect_prog") > "$root/detect.log" 2>&1 \
    || { echo "FAIL detect exited non-zero in $1"; cat "$root/detect.log"; exit 1; }
  tr '\n' ' ' < "$root/detect.out" | sed 's/ $//'
}
repo() { # repo <name> <file under it>...
  local d="$root/repos/$1"; shift; mkdir -p "$d"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo '{}' > "$d/$f"; done
  echo "$d"
}
e2e_cfg=tests/e2e/playwright.config.ts
fn_cfg=tests/functional/playwright.config.ts
lockfile=$(repo lockfile package.json tests/package.json tests/package-lock.json "$e2e_cfg")
workspace=$(repo workspace package.json tests/package.json "$e2e_cfg")
both=$(repo both package.json tests/package.json tests/package-lock.json "$e2e_cfg" "$fn_cfg")
cfg_only=$(repo config-only package.json "$e2e_cfg")
eq "$(detect "$lockfile" true)" "tests=true tests-layout=lockfile functional=false e2e=true" "e2e, tests/ with its own lockfile"
eq "$(detect "$workspace" true)" "tests=true tests-layout=workspace functional=false e2e=true" "e2e, tests/ as a root workspace"
eq "$(detect "$both" true)" "tests=true tests-layout=lockfile functional=true e2e=true" "functional and e2e"
eq "$(detect "$lockfile" false)" "tests=true tests-layout=lockfile functional=false e2e=false" "excluded branch"
grep -qF 'no e2e tests on renovate/x' "$root/detect.log" || { echo "FAIL excluded branch is not named in the log"; exit 1; }
eq "$(detect "$cfg_only" true)" "tests=false tests-layout=none functional=false e2e=false" "e2e config without tests/package.json"
grep -qF '::warning::tests/e2e/playwright.config.ts without tests/package.json' "$root/detect.log" \
  || { echo "FAIL e2e config without tests/package.json emits no ::warning::"; exit 1; }
grep -qxF '            tests/e2e/playwright.config.ts' "$wf" || { echo "FAIL the version job does not check out the e2e config"; exit 1; }
echo "e2e detect: ok"

# shellcheck disable=SC2016 # the expressions are matched literally
{
  eq "$(job e2e-stand if)" '${{ needs.version.outputs.e2e-stand == '"'true'"' }}' "e2e-stand runs on the version job's verdict"
  grep -qF 'e2e-stand: ${{ steps.v.outputs.pr-stands == '"'true'"' && steps.tests.outputs.e2e == '"'true'"' }}' "$wf" \
    || { echo "FAIL e2e-stand is not pr-stands && e2e"; exit 1; }
  grep -qF 'if [ "$PR_STANDS" = true ] && [ "$HOT_TEST_INPUT" = true ]; then HOT_TEST=true; fi' "$wf" \
    || { echo "FAIL hot-test is not pr-stands && input hot-test"; exit 1; }
  grep -qF 'PR_STANDS: ${{ github.event_name == '"'pull_request'"' && github.event.pull_request.head.repo.full_name == github.repository && !startsWith(github.head_ref, '"'renovate/'"') && github.head_ref != '"'LocalizationPull'"' }}' "$wf" \
    || { echo "FAIL PR_STANDS is not pull_request, no fork, no renovate/*, no LocalizationPull"; exit 1; }
  grep -qF "needs.version.outputs.e2e-stand == 'true'" <<<"$(jobtext build)" || { echo "FAIL build does not upload static for e2e-stand"; exit 1; }
}
eq "$(job e2e-stand needs)" "[version, build]" "e2e-stand needs"
if grep -qE 'inputs\.e2e-stand|^      e2e-stand:$' "$wf"; then echo "FAIL e2e-stand is behind an input: the stand is unconditional"; exit 1; fi
eq "$(awk '/^      e2e:$/ { on = 1; next } on && /default:/ { print $2; exit }' "$wf")" "true" "e2e runs by default, e2e: false opts a repo out"
grep -qF "      e2e: \${{ steps.tests.outputs.e2e }}" "$wf" || { echo "FAIL the e2e detection output depends on more than the files"; exit 1; }
stand=$(jobtext e2e-stand); hot=$(jobtext hot-test)
has "$stand" "      stand-prefix: e2e" "e2e-stand prefix"
eq "$(grep -A20 '^    with:' <<<"$stand" | grep -v stand-prefix)" "$(grep -A20 '^    with:' <<<"$hot" | grep -v '^      pages:')" "e2e-stand passes the hot-test inputs but pages"
eq "$(job e2e-stand uses)" "$(job hot-test uses)" "e2e-stand calls the same workflow as hot-test"
echo "e2e-stand wiring: ok"

eq "$(job e2e needs)" "[version, install, tests-install, e2e-stand]" "e2e needs"
# shellcheck disable=SC2016 # the expressions are matched literally
{
  eq "$(job e2e continue-on-error)" '${{ !inputs.e2e-required }}' "e2e failure is advisory only when not required"
  e2e_if=$(job e2e if)
  for c in '!cancelled()' 'inputs.e2e &&' "needs.e2e-stand.result == 'success'" "needs.e2e-stand.outputs.route == 'true'" \
    "needs.version.outputs.e2e == 'true'" "needs.install.result == 'success'" \
    "(needs.tests-install.result == 'success' || needs.tests-install.result == 'skipped')"; do
    has "$e2e_if" "$c" "e2e if"
  done
}
eq "$(job e2e timeout-minutes)" "60" "e2e timeout"
for j in image release sourcemaps bake; do
  if grep -qE '(\[|, )e2e(,|\])' <<<"$(job "$j" needs)"; then echo "FAIL $j waits for e2e: it is advisory"; exit 1; fi
done
echo "e2e gate: ok"

e2e=$(jobtext e2e)
pw_line="v=\$(node -p \"require('@playwright/test/package.json').version\" || true)"
eq "$(grep -cF "$pw_line" "$wf")" "$(grep -cF 'run: npx --no playwright install --with-deps chromium' "$wf")" "every chromium install reads @playwright/test/package.json"
has "$e2e" "$pw_line" "e2e Playwright version"
has "$e2e" "run: npx --no playwright install --with-deps chromium" "e2e chromium"
has "$e2e" "path: *root-node-modules" "e2e restores the root cache with the shared path list"
has "$e2e" "npm run e2e:ci 2>&1 | tee \"\$RUNNER_TEMP/e2e.log\"" "e2e log captured"
# shellcheck disable=SC2016 # the expressions are matched literally
for env in 'CI: "true"' 'BASE_URL: ${{ needs.e2e-stand.outputs.url }}' 'TEST_ENVIRONMENT: pull-request' \
  'RETRIES: "2"' 'WORKERS: ${{ inputs.e2e-workers }}'; do
  has "$e2e" "          $env" "e2e run env"
done
echo "e2e run: ok"

# The credentials leave the Vault step only as masked outputs into the run step's env.
has "$e2e" "          exportEnv: false" "vault-action does not export the credentials to every later step"
has "$e2e" "          role: \${{ inputs.e2e-vault-role }}" "vault role input"
has "$e2e" "            \${{ inputs.e2e-vault-secret }} ADMINSITE_PASSWORD | ADMINSITE_PASSWORD" "vault password line"
has "$e2e" "            \${{ inputs.e2e-vault-secret }} ADMINSITE_USERNAME | ADMINSITE_USERNAME ;" "vault username line"
eq "$(grep -v '^ *#' "$wf" | grep -c 'ADMINSITE_PASSWORD')" "2" "ADMINSITE_PASSWORD only in the Vault secret line and the run env"
has "$e2e" "          ADMINSITE_PASSWORD: \${{ steps.vault.outputs.ADMINSITE_PASSWORD }}" "password from the Vault step output"
has "$e2e" "          ADMINSITE_USERNAME: \${{ steps.vault.outputs.ADMINSITE_USERNAME }}" "username from the Vault step output"
if grep -nE '(echo|printf|tee|cat|::add-mask::|set -x).*ADMINSITE_' "$wf"; then echo "FAIL a step prints the credentials"; exit 1; fi
echo "e2e credentials: ok"

eq "$(job e2e-image needs)" "[version, install, tests-install, image]" "e2e-image needs"
# shellcheck disable=SC2016 # the expressions are matched literally
{
  e2e_image_if=$(job e2e-image if)
  for c in '!cancelled()' "needs.version.outputs.publish == 'true'" "needs.version.outputs.e2e == 'true'" \
    "needs.install.result == 'success'" "(needs.tests-install.result == 'success' || needs.tests-install.result == 'skipped')" \
    "needs.image.result == 'success'"; do
    has "$e2e_image_if" "$c" "e2e-image if"
  done
  hasnt "$e2e_image_if" "inputs.e2e" "e2e-image does not depend on the PR e2e input"
  has "$(job release needs)" "e2e-image" "release waits for e2e-image"
  has "$(job release if)" "(needs.version.outputs.e2e != 'true' || needs.e2e-image.result == 'success')" "a skipped e2e-image holds nothing"
}
ei=$(jobtext e2e-image); deps=$(jobtext deps-image)
for l in "          repositories: \${{ needs.version.outputs.image }}-e2e" "          context: tests" \
  "          file: \${{ runner.temp }}/Dockerfile.e2e" \
  "          tags: \${{ steps.ecr.outputs.registry }}/\${{ needs.version.outputs.image }}-e2e:\${{ needs.version.outputs.release }}" \
  "          cache-from: type=gha,scope=mcf-e2e-\${{ needs.version.outputs.image }}" \
  "          cache-to: type=gha,mode=max,ignore-error=true,scope=mcf-e2e-\${{ needs.version.outputs.image }}" \
  "          image: \${{ steps.ecr.outputs.registry }}/\${{ needs.version.outputs.image }}-e2e" \
  "          path: *root-node-modules" "          path: tests/node_modules"; do
  has "$ei" "$l" "e2e-image"
done
eq "$(grep -A3 '^          labels: |$' <<<"$ei")" "$(grep -A3 '^          labels: |$' <<<"$deps")" "e2e-image labels as with-deps"
eq "$(grep -B1 'uses: maestra-io/github-actions/sign-image@' <<<"$ei")" "$(grep -B1 'uses: maestra-io/github-actions/sign-image@' <<<"$deps")" "e2e-image signs best-effort with the with-deps pin"
eq "$(grep 'uses: maestra-io/github-actions/push-to-aws-ecr-repository@' <<<"$ei")" "$(grep 'uses: maestra-io/github-actions/push-to-aws-ecr-repository@' <<<"$deps")" "e2e-image ECR action pin as with-deps"
hasnt "$ei" "FROM packages.maestra.io" "e2e-image pulls the Playwright base from MCR directly"
has "$ei" "          # >>> nora-cred-helper (scripts/test-dotnet-service-build.sh runs this block; all copies equal)" "e2e-image pulls DEPS_BASE through nora"
has "$ei" "          jq --arg h \"\${DEPS_BASE%%/*}\" '.credHelpers[\$h] = \"nora\"' \"\$cfg\" > \"\$cfg.t\" && mv \"\$cfg.t\" \"\$cfg\"" "e2e-image nora credentials for DEPS_BASE's host"
has "$ei" "          package-manager-cache: false" "e2e-image publishes: no package manager cache from setup-node"
echo "e2e-image wiring: ok"

ctx_prog=$(block e2e-image-context)
# ctx <repo dir> <layout>; prints the Dockerfile, fails the test when the block fails
ctx() {
  (cd "$1" && DEPS_BASE='node:24-slim@sha256:0' LAYOUT="$2" RUNNER_TEMP="$1/.tmp" bash -c "set -eo pipefail; mkdir -p \"\$RUNNER_TEMP\"; $ctx_prog") > "$root/ctx.log" 2>&1 \
    || { echo "FAIL e2e-image-context exited non-zero in $1"; cat "$root/ctx.log"; exit 1; }
  cat "$1/.tmp/Dockerfile.e2e"
}
ctx_fails() { # ctx_fails <repo dir> <layout> <error>
  if (cd "$1" && DEPS_BASE='node:24-slim@sha256:0' LAYOUT="$2" RUNNER_TEMP="$1/.tmp" bash -c "set -eo pipefail; mkdir -p \"\$RUNNER_TEMP\"; $ctx_prog") > "$root/ctx.log" 2>&1; then
    echo "FAIL e2e-image-context passed in $1"; exit 1
  fi
  grep -qF -- "$3" "$root/ctx.log" || { echo "FAIL e2e-image-context in $1: no $3"; cat "$root/ctx.log"; exit 1; }
}
pkg() { mkdir -p "$1"; printf '{"name":"%s","version":"%s"}\n' "${1##*/node_modules/}" "$2" > "$1/package.json"; }
want=$(printf '%s\n' 'FROM node:24-slim@sha256:0 AS npm' 'FROM mcr.microsoft.com/playwright:v1.56.1-noble' \
  'RUN rm -rf /usr/lib/node_modules/npm' 'COPY --from=npm /usr/local/lib/node_modules/npm /usr/lib/node_modules/npm' \
  'WORKDIR /tests' 'RUN chown pwuser:pwuser /tests' \
  'COPY --chown=pwuser:pwuser node_modules node_modules' 'COPY --chown=pwuser:pwuser --exclude=node_modules . .' \
  'USER pwuser' 'CMD ["npm","run","e2e:ci"]')

pkg "$lockfile/tests/node_modules/@playwright/test" 1.56.1
pkg "$lockfile/node_modules/@playwright/test" 1.40.0
eq "$(ctx "$lockfile" lockfile)" "$want" "Dockerfile.e2e, tests/ with its own lockfile"
[ ! -e "$lockfile/tests/node_modules/@playwright/test/node_modules" ] || { echo "FAIL lockfile layout copied the root node_modules"; exit 1; }

pkg "$workspace/node_modules/@playwright/test" 1.56.1
pkg "$workspace/node_modules/dotenv" 17.0.0
pkg "$workspace/node_modules/eslint" 9.0.0
pkg "$workspace/tests/node_modules/eslint" 8.57.0
mkdir -p "$workspace/node_modules/.bin" "$workspace/tests/node_modules/.bin"
ln -s ../@playwright/test/cli.js "$workspace/node_modules/.bin/playwright"
ln -s ../eslint/bin/eslint.js "$workspace/node_modules/.bin/eslint"
ln -s ../eslint/bin/eslint.js "$workspace/tests/node_modules/.bin/eslint"
ln -s ../tests "$workspace/node_modules/frontend-x-tests"
mkdir -p "$workspace/packages/helpers"; pkg "$workspace/packages/helpers/node_modules/x" 1.0.0
printf '{"name":"@x/helpers","version":"2.0.0"}\n' > "$workspace/packages/helpers/package.json"
mkdir -p "$workspace/node_modules/@x"; ln -s ../../packages/helpers "$workspace/node_modules/@x/helpers"
ln -s ../missing "$workspace/node_modules/dangling"
eq "$(ctx "$workspace" workspace)" "$want" "Dockerfile.e2e, tests/ as a root workspace"
eq "$(jq -r .version "$workspace/tests/node_modules/@playwright/test/package.json")" "1.56.1" "hoisted @playwright/test copied into tests/node_modules"
eq "$(jq -r .version "$workspace/tests/node_modules/dotenv/package.json")" "17.0.0" "hoisted package copied"
eq "$(jq -r .version "$workspace/tests/node_modules/eslint/package.json")" "8.57.0" "tests/node_modules keeps its own version over the root's"
eq "$(ls "$workspace/tests/node_modules/eslint")" "package.json" "the root's eslint is not copied into the tests/ one"
eq "$(readlink "$workspace/tests/node_modules/.bin/playwright")" "../@playwright/test/cli.js" "root .bin link copied as a link"
[ ! -e "$workspace/tests/node_modules/frontend-x-tests" ] && [ ! -L "$workspace/tests/node_modules/frontend-x-tests" ] \
  || { echo "FAIL the link to the tests workspace itself is copied"; exit 1; }
[ ! -L "$workspace/tests/node_modules/@x/helpers" ] || { echo "FAIL a local package is copied as its link"; exit 1; }
eq "$(jq -r .version "$workspace/tests/node_modules/@x/helpers/package.json")" "2.0.0" "a linked local package copied with its contents"
eq "$(jq -r .version "$workspace/tests/node_modules/@x/helpers/node_modules/x/package.json")" "1.0.0" "a linked local package keeps its own node_modules"
[ ! -e "$workspace/tests/node_modules/dangling" ] && [ ! -L "$workspace/tests/node_modules/dangling" ] \
  || { echo "FAIL a dangling link is copied"; exit 1; }

nopw=$(repo no-playwright package.json tests/package.json tests/package-lock.json "$e2e_cfg")
pkg "$nopw/node_modules/@playwright/test" 1.56.1
ctx_fails "$nopw" lockfile "::error::no @playwright/test in tests/node_modules"
pre=$(repo prerelease package.json tests/package.json tests/package-lock.json "$e2e_cfg")
pkg "$pre/tests/node_modules/@playwright/test" 1.57.0-alpha-2025-10-01
ctx_fails "$pre" lockfile "has no mcr.microsoft.com/playwright image"
echo "e2e-image Dockerfile: ok"

summary_prog=$(block e2e-summary)
# summary <junit fixture name|-> <outcome> <required> [log]; prints the summary
summary() {
  local junit="$root/missing.xml"
  [ "$1" = - ] || junit="$root/junit/$1.xml"
  : > "$root/summary.md"
  JUNIT="$junit" LOG="${4:-$root/missing.log}" OUTCOME="$2" REQUIRED="$3" STAND=https://e2e-frontend-x-pr-1.testing-env.omicron.maestra.io \
    GITHUB_STEP_SUMMARY="$root/summary.md" bash -c "set -eo pipefail; $summary_prog" || { echo "FAIL summary exited non-zero for $1"; exit 1; }
  cat "$root/summary.md"
}
mkdir -p "$root/junit"
cat > "$root/junit/mixed.xml" <<'XML'
<testsuites id="" name="" tests="5" failures="1" skipped="1" errors="0" time="42.5">
<testsuite name="smoke.test.ts" hostname="chromium">
<testcase name="smoke › list loads" classname="smoke.test.ts" time="10"><system-out>ok</system-out></testcase>
<testcase name="smoke › card opens" classname="smoke.test.ts" time="12"></testcase>
<testcase name="smoke › saves" classname="smoke.test.ts" time="9"><failure message="expect" type="expect.toBe">x</failure></testcase>
<testcase name="smoke › retried" classname="smoke.test.ts" time="7"><flakyFailure message="m" type="FAILURE"><stackTrace>s</stackTrace></flakyFailure></testcase>
<testcase name="smoke › ru only" classname="smoke.test.ts" time="0"><skipped/></testcase>
</testsuite>
</testsuites>
XML
cat > "$root/junit/green.xml" <<'XML'
<testsuites id="" name="" tests="1" failures="0" skipped="0" errors="0" time="20">
<testsuite name="smoke.test.ts" hostname="chromium">
<testcase name="smoke › list loads" classname="smoke.test.ts" time="20"></testcase>
</testsuite>
</testsuites>
XML
printf '  1 flaky\n    [chromium] › smoke.test.ts:3:1 › smoke › list loads\n  1 passed (20s)\n' > "$root/flaky.log"

out=$(summary mixed failure false)
has "$out" "### e2e tests" "heading"
has "$out" "Stand: https://e2e-frontend-x-pr-1.testing-env.omicron.maestra.io" "stand URL"
has "$out" ":x: 1 of 5 failed" "mixed"
has "$out" "| 5 | 3 | 1 | 1 | 1 | 42.5 s |" "mixed: passed, failed, flaky, skipped"
has "$out" "- \`smoke.test.ts › smoke › saves\`" "failed test named"
has "$out" "not blocking: e2e-required is false" "advisory"
out=$(summary green success true "$root/flaky.log")
has "$out" ":white_check_mark: 1 of 1 passed" "green"
has "$out" "| 1 | 1 | 0 | 1 | 0 | 20.0 s |" "green, flaky from the line reporter"
hasnt "$out" "not blocking" "required"
out=$(summary green failure false)
has "$out" ":x: \`e2e:ci\` failed (failure) with no failed test in the report" "red exit, green report"
out=$(summary - failure false)
has "$out" ":x: \`e2e:ci\` failed (failure) and wrote no JUnit report at" "no report, red exit"
has "$out" "Stand: https://" "no report still names the stand"
out=$(summary - skipped false)
has "$out" ":x: the tests did not run: an earlier step failed" "run step skipped"
echo "e2e summary: ok"
