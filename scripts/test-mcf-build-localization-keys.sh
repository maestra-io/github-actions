#!/usr/bin/env bash
#
# Self-check for the localization-keys check of mcf-build.yml: its exit is the dead-keys
# script's, the undefined-keys script after it neither hides nor causes a failure, and the
# checks verdict reports it as advisory while a failed blocking check still fails the step.
# Runs the inline blocks of the workflow with stub scripts.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
block() {
  local b
  b=$(sed -n "/# >>> $1\$/,/# <<< $1\$/p" "$wf" | sed "s/^ \{$2\}//")
  [ -n "$b" ] || { echo "$1 block not found in $wf" >&2; exit 1; }
  printf '%s\n' "$b"
}
prog=$(block localization-keys 12)
start_prog=$(block checks-start 10)
verdict_prog=$(block checks-verdict 10)

# stubs <dir> <dead-keys exit> <undefined-keys exit>
stubs() {
  rm -rf "$1"; mkdir -p "$1/utils" "$1/logs"
  echo "process.exit($2)" > "$1/utils/deadLocalizationKeys.js"
  echo "process.exit($3)" > "$1/utils/undefinedLocalizationKeys.js"
}

# check <dead-keys exit> <undefined-keys exit>; prints the exit of the check
check() {
  local d="$root/check"; stubs "$d" "$1" "$2"
  (cd "$d" && i18n="$d/utils" logs="$d/logs" bash -c "$prog"$'\n''rc=0; l10n > /dev/null 2>&1 || rc=$?; echo "$rc"')
}
eq "$(check 0 0)" 0 "no unused keys"
eq "$(check 1 0)" 1 "unused keys fail the check, the undefined-keys script after it does not hide that"
eq "$(check 0 1)" 0 "undefined keys never fail the check"
eq "$(check 1 1)" 1 "unused and undefined keys"

# verdict <dead-keys exit> <types exit>; runs start, wait and the verdict loop with a
# localization-keys and a blocking types check; prints "<step exit> <l10n row> <types row>"
verdict() {
  local d="$root/verdict" rc=0; stubs "$d" "$1" 0
  (cd "$d" && i18n="$d/utils" logs="$d/logs" TYPES_RC="$2" GITHUB_STEP_SUMMARY="$d/summary.md" \
    bash -c "$start_prog"$'\n'"$prog"$'\n''start localization-keys l10n; start types sh -c "exit $TYPES_RC"'$'\n'"$verdict_prog") \
    > /dev/null 2>&1 || rc=$?
  row() { grep -F "| \`$1\` |" "$d/summary.md" | sed "s/^| \`$1\` | \(.*\) |\$/\1/"; }
  echo "$rc $(row localization-keys) / $(row types)"
}
eq "$(verdict 0 0)" "0 passed / passed" "all checks pass"
eq "$(verdict 1 0)" "0 failed (not blocking) / passed" "unused keys are reported, the step stays green"
eq "$(verdict 1 1)" "1 failed (not blocking) / failed" "a failed blocking check still fails the step"
echo "mcf-build localization-keys: ok"
