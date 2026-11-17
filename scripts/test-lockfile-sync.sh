#!/usr/bin/env bash
#
# Self-check for the lockfile-sync block of mcf-build.yml (the `check lockfile` step of install
# and tests-install): it reports every dependency spec where a package.json (root or npm
# workspace) and package-lock.json disagree, which a node_modules cache hit would otherwise hide.
# Runs the inline block of the workflow against fixture package.json / package-lock.json files.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

prog=$(awk '
  /# >>> lockfile-sync$/ { on = 1; match($0, /^ */); ind = RLENGTH }
  on { print substr($0, ind + 1) }
  /# <<< lockfile-sync$/ { exit }
' "$wf")
[ -n "$prog" ] || { echo "lockfile-sync block not found in $wf" >&2; exit 1; }

# drift <package.json> <package-lock.json> [<tests/package.json>]; prints the drift lines joined by " | "
drift() {
  local d="$root/case"; rm -rf "$d"; mkdir -p "$d"
  printf '%s\n' "$1" > "$d/package.json"
  printf '%s\n' "$2" > "$d/package-lock.json"
  if [ $# -ge 3 ]; then mkdir -p "$d/tests"; printf '%s\n' "$3" > "$d/tests/package.json"; fi
  # The workflow step runs under `bash -e`: the call itself must not fail.
  (cd "$d" && bash -eo pipefail -c "$prog"$'\n''lockfile_drift' | paste -sd'|' - | sed 's/|/ | /g')
}

pkg='{"dependencies":{"a":"1.0.0"},"devDependencies":{"b":"^2.0.0"}}'
lock='{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"},"devDependencies":{"b":"^2.0.0"}},"node_modules/a":{"version":"1.0.0"},"node_modules/b":{"version":"2.1.0"}}}'
eq "$(drift "$pkg" "$lock")" "" "in sync"
eq "$(drift '{"dependencies":{"a":"1.1.0"},"devDependencies":{"b":"^2.0.0"}}' "$lock")" \
  ". dependencies a: package.json 1.1.0, lockfile 1.0.0" "version bumped in package.json only"
eq "$(drift '{"dependencies":{"a":"1.0.0","c":"3.0.0"},"devDependencies":{"b":"^2.0.0"}}' "$lock")" \
  ". dependencies c: package.json 3.0.0, lockfile -" "dependency added to package.json only"
eq "$(drift '{"devDependencies":{"b":"^2.0.0"}}' "$lock")" \
  ". dependencies a: package.json -, lockfile 1.0.0" "dependency removed from package.json only"
eq "$(drift '{"devDependencies":{"b":"^2.0.0","a":"1.0.0"}}' "$lock")" \
  ". dependencies a: package.json -, lockfile 1.0.0 | . devDependencies a: package.json 1.0.0, lockfile -" \
  "moved between dependency kinds"
eq "$(drift '{"dependencies":{"a":"1.0.0"},"devDependencies":{"b":"^2.0.0"},"peerDependencies":{"r":">=18"}}' "$lock")" \
  ". peerDependencies r: package.json >=18, lockfile -" "peerDependencies count"
eq "$(drift '{"dependencies":{"a":"1.0.0"},"devDependencies":{"b":"^2.0.0"},"scripts":{"x":"y"},"version":"9.9.9"}' "$lock")" \
  "" "fields other than dependencies do not matter"

wlock='{"lockfileVersion":3,"packages":{"":{"workspaces":["tests"],"dependencies":{"a":"1.0.0"}},"tests":{"devDependencies":{"p":"1.2.0"}},"node_modules/a":{"version":"1.0.0"},"node_modules/p":{"version":"1.2.0"}}}'
eq "$(drift '{"workspaces":["tests"],"dependencies":{"a":"1.0.0"}}' "$wlock" '{"devDependencies":{"p":"1.2.0"}}')" \
  "" "workspace in sync"
eq "$(drift '{"workspaces":["tests"],"dependencies":{"a":"1.0.0"}}' "$wlock" '{"devDependencies":{"p":"1.3.0"}}')" \
  "tests devDependencies p: package.json 1.3.0, lockfile 1.2.0" "workspace package.json bumped without the lockfile"
eq "$(drift '{"workspaces":["tests"],"dependencies":{"a":"1.0.0"}}' "$wlock")" \
  "" "a workspace without its package.json is skipped"
eq "$(drift '{"dependencies":{"a":"1.0.0"}}' '{"lockfileVersion":1,"dependencies":{"a":{"version":"1.0.0"}}}')" \
  "" "lockfile v1 (no packages map) is not checked"
echo "lockfile-sync: ok"
