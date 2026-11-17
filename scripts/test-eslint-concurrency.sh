#!/usr/bin/env bash
#
# Self-check for the eslint-concurrency block of mcf-build.yml (checks, tests-checks) and
# npm-package-publish.yml (checks): every copy is the same, and it adds --concurrency=auto
# only to a single eslint command on an ESLint that knows the flag (>= 9.34). Runs the
# inline block of the workflow against stub package.json / node_modules/eslint.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wfs=("$here/../.github/workflows/mcf-build.yml" "$here/../.github/workflows/npm-package-publish.yml")
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

# Every copy of the block, de-indented; awk ends each with a NUL.
copies=0; prog=""
for wf in "${wfs[@]}"; do
  while IFS= read -r -d '' b; do
    copies=$((copies + 1))
    if [ -z "$prog" ]; then prog=$b; else eq "$b" "$prog" "copy $copies of the block in $(basename "$wf") differs"; fi
  done < <(awk '
    /# >>> eslint-concurrency$/ { on = 1; match($0, /^ */); ind = RLENGTH }
    on { print substr($0, ind + 1) }
    /# <<< eslint-concurrency$/ { on = 0; printf "%c", 0 }
  ' "$wf")
done
eq "$copies" 3 "eslint-concurrency copies (mcf-build checks + tests-checks, npm-package-publish checks)"

# flag <check-scripts value or "-" for none> <installed eslint version or "-" for none>
flag() {
  local d="$root/case"; rm -rf "$d"; mkdir -p "$d"
  if [ "$1" = - ]; then echo '{"scripts":{}}' > "$d/package.json"
  else jq -n --arg v "$1" '{scripts: {"check-scripts": $v}}' > "$d/package.json"; fi
  if [ "$2" != - ]; then
    mkdir -p "$d/node_modules/eslint"; jq -n --arg v "$2" '{version: $v}' > "$d/node_modules/eslint/package.json"
  fi
  # The workflow steps run under `bash -e`: the call must never fail the step.
  (cd "$d" && bash -eo pipefail -c "$prog"$'\n''x=$(eslint_concurrency check-scripts); echo "[$x]"')
}
on='[--concurrency=auto]'; off='[]'
eq "$(flag eslint 9.39.4)" "$on" "plain eslint on 9.39"
eq "$(flag eslint 9.34.0)" "$on" "first version with --concurrency"
eq "$(flag eslint 10.12.0)" "$on" "eslint 10"
eq "$(flag eslint 9.33.0)" "$off" "9.33 has no --concurrency"
eq "$(flag eslint 8.57.0)" "$off" "eslint 8"
eq "$(flag eslint -)" "$off" "eslint not installed"
eq "$(flag eslint garbage)" "$off" "unparsable version"
eq "$(flag - 9.39.4)" "$off" "no check-scripts script"
eq "$(flag 'cross-env NODE_ENV=production eslint' 9.39.4)" "$on" "eslint behind cross-env"
eq "$(flag 'eslint "src/**/*.{ts,tsx}" "*.{js,mjs,ts}"' 9.39.4)" "$on" "eslint with globs"
eq "$(flag 'eslint --concurrency=4' 9.39.4)" "$off" "the script sets concurrency itself"
eq "$(flag 'eslint . && tsc --noEmit' 9.39.4)" "$off" "args would land on the last command"
eq "$(flag 'eslint . | tee lint.log' 9.39.4)" "$off" "pipeline"
eq "$(flag 'tsc --noEmit' 9.39.4)" "$off" "not eslint"
eq "$(flag 'my-eslint-wrapper' 9.39.4)" "$off" "eslint only as part of another word"
echo "eslint-concurrency: ok"
