#!/usr/bin/env bash
# Self-check for npm-lockfile-to-nora.sh (rewrite, keep, idempotence) and the
# workflows' check that refuses a lockfile resolved outside nora.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cat > "$d/package-lock.json" <<'LF'
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/@mindbox-cloud/ui-components/-/@mindbox-cloud/ui-components-22.1.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/npm/-/npm-11.17.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm-remote/@types/node/-/node-22.0.0.tgz",
      "resolved": "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
      "resolved": "https://registry.npmjs.org/@babel/core/-/core-7.26.0.tgz",
      "resolved": "https://registry.npmjs.org/npm-run-path/-/npm-run-path-5.3.0.tgz",
      "integrity": "sha512-keep",
LF
cat > "$d/want" <<'LF'
      "resolved": "https://packages.maestra.io/npm/@mindbox-cloud/ui-components/-/ui-components-22.1.0.tgz",
      "resolved": "https://packages.maestra.io/npm/npm/-/npm-11.17.0.tgz",
      "resolved": "https://packages.maestra.io/npm/@types/node/-/node-22.0.0.tgz",
      "resolved": "https://packages.maestra.io/npm/react/-/react-18.3.1.tgz",
      "resolved": "https://packages.maestra.io/npm/@babel/core/-/core-7.26.0.tgz",
      "resolved": "https://packages.maestra.io/npm/npm-run-path/-/npm-run-path-5.3.0.tgz",
      "integrity": "sha512-keep",
LF
"$here/npm-lockfile-to-nora.sh" "$d/package-lock.json" >/dev/null
diff -u "$d/want" "$d/package-lock.json"
"$here/npm-lockfile-to-nora.sh" "$d/package-lock.json" | grep -q '^unchanged:'
diff -u "$d/want" "$d/package-lock.json"

# npm-package-publish.yml and mcf-build.yml refuse a lockfile with a `resolved` URL
# outside nora before `npm ci` (inline: a reusable workflow cannot read this
# repository's files): run those copies.
lock() {
  jq -n '{lockfileVersion: 3, packages: ([$ARGS.positional | to_entries[]
    | {key: "node_modules/p\(.key)", value: {resolved: .value}}] | from_entries)}' --args "$@"
}
mapfile -t nora_urls < <(sed -nE 's/^ *"resolved": "([^"]+)",$/\1/p' "$d/want")
[ "${#nora_urls[@]}" -eq 6 ] || { echo "expected 6 nora URLs in the fixture"; exit 1; }
for wf in "$here/../.github/workflows/npm-package-publish.yml" "$here/../.github/workflows/mcf-build.yml"; do
  name=$(basename "$wf")
  # shellcheck disable=SC2016 # literal shell program, nothing to expand
  prog=$(sed -n '/^ *nora="\${URL%\/}\/npm\/"$/,/^ *fi$/p' "$wf" | sed 's/^          //')
  grep -q 'jq .*resolved' <<<"$prog" || { echo "$name: lockfile check not found"; exit 1; }
  check() { (cd "$1" && URL=https://packages.maestra.io/ bash -e -c "$prog") > /dev/null 2>&1; }
  w="$d/${name%.yml}"
  mkdir -p "$w/nora" "$w/none" "$w/invalid" "$w/spaced"
  lock "${nora_urls[@]}" tests file:../lib > "$w/nora/package-lock.json"
  check "$w/nora" || { echo "$name: a nora lockfile must pass"; exit 1; }
  check "$w/none" || { echo "$name: no lockfile must pass"; exit 1; }
  echo '{"packages": {' > "$w/invalid/package-lock.json"
  if check "$w/invalid"; then echo "$name: an unparsable lockfile must fail"; exit 1; fi
  printf '{"packages": {"node_modules/react": {"resolved" : "%s"}}}\n' \
    https://registry.npmjs.org/react/-/react-18.3.1.tgz > "$w/spaced/package-lock.json"
  if check "$w/spaced"; then echo "$name: a space before the colon must not hide a URL"; exit 1; fi
  n=0
  for url in \
    https://registry.npmjs.org/react/-/react-18.3.1.tgz \
    https://artifactory.mindbox.ru/artifactory/api/npm/npm/react/-/react-18.3.1.tgz \
    https://registry.yarnpkg.com/react/-/react-18.3.1.tgz \
    https://packages.maestra.io/npm-run-path/-/npm-run-path-5.3.0.tgz \
    git+ssh://git@github.com/maestra-io/x.git#abc; do
    for lock in package-lock.json npm-shrinkwrap.json; do
      n=$((n + 1)); mkdir "$w/bad$n"
      lock "${nora_urls[@]}" "$url" > "$w/bad$n/$lock"
      if check "$w/bad$n"; then echo "$name: $lock resolved to $url must fail"; exit 1; fi
    done
  done
  ! grep -qE 'replace-registry-host=|sed -i.*"resolved' "$wf" \
    || { echo "$name must not rewrite the lockfile or set replace-registry-host"; exit 1; }
done
echo "npm-lockfile-to-nora: OK"
