#!/usr/bin/env bash
#
# Self-check for the deps-prune block of mcf-build.yml: the packages named in DEPS_PRUNE
# leave node_modules together with what only they need, and nothing else does.
# Runs the inline block of the reusable workflow itself on a synthetic lockfile.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

prog=$(sed -n '/# >>> deps-prune/,/# <<< deps-prune/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "deps-prune block not found in $wf"; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
# root -> app-lib, eslint (pruned), shared-configs -> eslint-plugin-x (pruned) -> only-lint
# shared: needed by app-lib and by eslint, stays. eslint has its own nested copy of shared.
# tests workspace -> playwright. tools/lefthook-linux: an optional dependency of lefthook.
cat > package-lock.json <<'JSON'
{
  "lockfileVersion": 3,
  "packages": {
    "": { "dependencies": { "app-lib": "1" }, "devDependencies": { "eslint": "1", "shared-configs": "1", "lefthook": "1" } },
    "tests": { "devDependencies": { "playwright": "1" } },
    "node_modules/tests": { "resolved": "tests", "link": true },
    "node_modules/app-lib": { "dependencies": { "shared": "2" } },
    "node_modules/shared": {},
    "node_modules/eslint": { "dependencies": { "shared": "1", "only-lint": "1" } },
    "node_modules/eslint/node_modules/shared": {},
    "node_modules/only-lint": {},
    "node_modules/shared-configs": { "dependencies": { "eslint-plugin-x": "1", "@scope/kept": "1" }, "peerDependencies": { "peer-kept": "1" } },
    "node_modules/eslint-plugin-x": { "dependencies": { "only-lint": "1" } },
    "node_modules/@scope/kept": {},
    "node_modules/peer-kept": {},
    "node_modules/lefthook": { "optionalDependencies": { "lefthook-linux": "1" } },
    "node_modules/lefthook-linux": {},
    "node_modules/playwright": {}
  }
}
JSON
jq -r '.packages | keys[] | select(startswith("node_modules/") or contains("/node_modules/"))' package-lock.json \
  | while read -r dir; do mkdir -p "$dir"; : > "$dir/index.js"; done

out=$(DEPS_PRUNE='eslint eslint-* lefthook lefthook-*' bash -c "set -eo pipefail; $prog")
left=$(find node_modules -name index.js | sed 's#/index.js$##' | sort | tr '\n' ' ')
want='node_modules/@scope/kept node_modules/app-lib node_modules/peer-kept node_modules/playwright node_modules/shared node_modules/shared-configs node_modules/tests '
[ "$left" = "$want" ] || { printf 'FAIL prune\n  got:  %s\n  want: %s\n' "$left" "$want"; exit 1; }
[ "$out" = 'pruned 6 of 13 packages' ] || { echo "FAIL summary: $out"; exit 1; }
echo "mcf-build deps-prune: ok"

# An empty list prunes nothing.
jq -r '.packages | keys[] | select(startswith("node_modules/") or contains("/node_modules/"))' package-lock.json \
  | while read -r dir; do mkdir -p "$dir"; : > "$dir/index.js"; done
out=$(DEPS_PRUNE='' bash -c "set -eo pipefail; $prog")
[ "$out" = 'pruned 0 of 13 packages' ] || { echo "FAIL empty list: $out"; exit 1; }
echo "mcf-build deps-prune empty list: ok"

# A lockfile without the packages map is refused, not silently kept whole.
echo '{"lockfileVersion": 1, "dependencies": {}}' > package-lock.json
if DEPS_PRUNE='eslint' bash -c "set -eo pipefail; $prog" >/dev/null 2>&1; then
  echo "FAIL lockfileVersion 1: accepted"; exit 1
fi
echo "mcf-build deps-prune old lockfile: ok"
