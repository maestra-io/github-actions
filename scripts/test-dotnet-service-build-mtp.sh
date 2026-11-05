#!/usr/bin/env bash
#
# Self-check for dotnet-service-build.yml `test`: warn-as-error on both test
# runners, and the TRX file VSTest writes to $RUNNER_TEMP/test-results. Runs the workflow's own dotnet-test block (it cannot read repo files)
# in ci/fixtures/dotnet-test/{mtp,vstest}. A bare /warnaserror made the
# Microsoft.Testing.Platform runner run zero tests (exit 5, maestra-io/promotions#2).
# Needs a .NET 10 SDK and nuget.org.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
fixtures="$here/../ci/fixtures/dotnet-test"
prog=$(sed -n '/# >>> dotnet-test/,/# <<< dotnet-test/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "dotnet-test block not found in $wf"; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -R "$fixtures/." "$work/"

# run <runner dir> <WARN_AS_ERROR> <SelftestWarn> -> output in $work/out, exit code
run() {
  rm -rf "$work/rt"
  (cd "$work/$1" && rm -rf bin obj \
    && RUNNER_TEMP="$work/rt" TOKEN=x SOURCE=private SOLUTION="" FILTER="TestCategory!=IntegrationTest" \
       WARN_AS_ERROR="$2" SelftestWarn="$3" bash -c "set -eo pipefail; $prog") >"$work/out" 2>&1
}
pass() { # <name> <expected output regex> <run args...>
  local name="$1" want="$2"; shift 2
  local rc=0; run "$@" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$work/out"; echo "FAIL $name: exit $rc"; exit 1; }
  grep -Eq "$want" "$work/out" || { cat "$work/out"; echo "FAIL $name: no '$want'"; exit 1; }
  echo "ok $name"
}
fail() { # <name> <expected error regex> <run args...>
  local name="$1" want="$2"; shift 2
  if run "$@"; then cat "$work/out"; echo "FAIL $name: passed"; exit 1; fi
  grep -Eq "$want" "$work/out" || { cat "$work/out"; echo "FAIL $name: no '$want'"; exit 1; }
  echo "ok $name"
}

pass "mtp: tests run under warn-as-error" 'total: 2' mtp true ""
grep -Eq 'succeeded: 2' "$work/out" || { cat "$work/out"; echo "FAIL mtp: not 2 succeeded"; exit 1; }
echo "ok mtp: VSTestLogger/VSTestResultsDirectory ignored"
fail "mtp: compiler warning is an error" 'error CS0168' mtp true cs
fail "mtp: MSBuild warning is an error" 'error SELFTEST1' mtp true msbuild
pass "mtp: warn-as-error false keeps warnings" 'succeeded: 2' mtp false cs
pass "vstest: tests run under warn-as-error" 'Passed: +2, .*Total: +2' vstest true ""
ls "$work"/rt/test-results/*.trx >/dev/null 2>&1 || { echo "FAIL vstest: no TRX in \$RUNNER_TEMP/test-results"; exit 1; }
echo "ok vstest: TRX written"
fail "vstest: compiler warning is an error" 'error CS0168' vstest true cs
fail "vstest: MSBuild warning is an error" 'error SELFTEST1' vstest true msbuild
echo "dotnet-service-build warn-as-error on MTP and VSTest, TRX on VSTest: OK"
