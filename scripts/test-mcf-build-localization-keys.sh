#!/usr/bin/env bash
#
# Self-check for the localization-keys check of mcf-build.yml: its exit is the dead-keys
# script's, the undefined-keys script after it neither hides nor causes a failure, and the
# check stays advisory. Runs the inline block of the workflow with stub scripts.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
prog=$(sed -n '/# >>> localization-keys/,/# <<< localization-keys/p' "$wf" | sed 's/^            //')
[ -n "$prog" ] || { echo "localization-keys block not found in $wf" >&2; exit 1; }

# check <dead-keys exit> <undefined-keys exit>; prints the exit of the check
check() {
  local d="$root/repo"; rm -rf "$d"
  mkdir -p "$d/utils" "$d/logs"
  echo "process.exit($1)" > "$d/utils/deadLocalizationKeys.js"
  echo "process.exit($2)" > "$d/utils/undefinedLocalizationKeys.js"
  (cd "$d" && i18n="$d/utils" logs="$d/logs" bash -c "$prog"$'\n''rc=0; l10n > /dev/null 2>&1 || rc=$?; echo "$rc"')
}
eq "$(check 0 0)" 0 "no unused keys"
eq "$(check 1 0)" 1 "unused keys fail the check, the undefined-keys script after it does not hide that"
eq "$(check 0 1)" 0 "undefined keys never fail the check"
eq "$(check 1 1)" 1 "unused and undefined keys"
grep -qF 'advisory=" unused-code localization-keys "' "$wf" \
  || { echo "FAIL localization-keys is no longer advisory"; exit 1; }
echo "mcf-build localization-keys: ok"
