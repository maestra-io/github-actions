#!/usr/bin/env bash
# Self-check for the "checks" program inlined in npm-package-publish.yml (a
# reusable workflow cannot read this repository's files, so the test runs the
# workflow's own copy): every script runs even after one fails, a missing script
# is skipped, check-styles gets --allow-empty-input, test gets the coverage flags
# only with COVERAGE=true, and the step fails iff a script failed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/npm-package-publish.yml"
prog=$(sed -n '/# npm-checks: begin/,/# npm-checks: end/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "npm-checks program not found in $wf"; exit 1; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT

# Each script appends "<name> <args>" to ran.log; `bad` fails.
cat > "$d/package.json" <<'X'
{
  "name": "t",
  "scripts": {
    "check-types": "echo check-types >> ran.log",
    "bad": "echo bad >> ran.log && exit 3",
    "check-styles": "sh -c 'echo check-styles \"$*\" >> ran.log' --",
    "test": "sh -c 'echo test \"$*\" >> ran.log' --"
  }
}
X

run() { # $1 = CHECKS, $2 = COVERAGE; sets rc, leaves ran.log and summary.md
  rm -f "$d/ran.log" "$d/summary.md"
  rc=0
  (cd "$d" && CHECKS="$1" COVERAGE="$2" GITHUB_STEP_SUMMARY="$d/summary.md" bash -eo pipefail -c "$prog" >/dev/null 2>&1) || rc=$?
}
check() { # $1 = name, $2 = want, $3 = got
  [ "$2" = "$3" ] || { printf '%s: want [%s] got [%s]\n' "$1" "$2" "$3"; exit 1; }
}

run "check-types bad graphql-codegen check-styles test" false
check "fails when one script fails" 1 "$rc"
check "all present scripts ran, in order, with lib@3 args" \
  "$(printf 'check-types\nbad\ncheck-styles --allow-empty-input\ntest ')" "$(cat "$d/ran.log")"
grep -q '| `bad` | failed |' "$d/summary.md" || { echo "summary misses the failed script"; exit 1; }
grep -q '| `graphql-codegen` | no such script |' "$d/summary.md" || { echo "summary misses the skipped script"; exit 1; }

run "check-types test" true
check "green run" 0 "$rc"
grep -q '^test --coverage --coverage.reportsDirectory=coverage .*--coverage.reporter=json-summary' "$d/ran.log" \
  || { echo "test without coverage flags: $(cat "$d/ran.log")"; exit 1; }

run "graphql-codegen" false
check "only missing scripts is green" 0 "$rc"
echo "npm-checks: OK"
