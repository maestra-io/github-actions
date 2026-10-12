#!/usr/bin/env bash
# Self-check for npm-lockfile-to-nora.sh: rewrite, keep, idempotence.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cat > "$d/package-lock.json" <<'LF'
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/@mindbox-cloud/ui-components/-/@mindbox-cloud/ui-components-22.1.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/npm/-/npm-11.17.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm-remote/@types/node/-/node-22.0.0.tgz",
      "resolved": "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
      "resolved": "https://registry.npmjs.org/@babel/core/-/core-7.26.0.tgz",
      "integrity": "sha512-keep",
LF
cat > "$d/want" <<'LF'
      "resolved": "https://packages.maestra.io/npm/@mindbox-cloud/ui-components/-/ui-components-22.1.0.tgz",
      "resolved": "https://packages.maestra.io/npm/npm/-/npm-11.17.0.tgz",
      "resolved": "https://packages.maestra.io/npm/@types/node/-/node-22.0.0.tgz",
      "resolved": "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
      "resolved": "https://registry.npmjs.org/@babel/core/-/core-7.26.0.tgz",
      "integrity": "sha512-keep",
LF
"$here/npm-lockfile-to-nora.sh" "$d/package-lock.json" >/dev/null
diff -u "$d/want" "$d/package-lock.json"
"$here/npm-lockfile-to-nora.sh" "$d/package-lock.json" | grep -q '^unchanged:'
diff -u "$d/want" "$d/package-lock.json"

# The reusable npm-package-publish.yml and mcf-build.yml inline the same program (a
# reusable workflow cannot read this repository's files): run those copies too.
for wf in "$here/../.github/workflows/npm-package-publish.yml" "$here/../.github/workflows/mcf-build.yml"; do
  # shellcheck disable=SC2016 # literal sed program, nothing to expand
  prog=$(sed -n '/^ *nora="\${URL%\/}\/npm\/"/,/^ *done$/p' "$wf" | sed 's/^          //')
  [ -n "$prog" ] || { echo "inline lockfile rewrite not found in $wf"; exit 1; }
  w="$d/$(basename "$wf" .yml)"; mkdir "$w"
  cat > "$w/package-lock.json" <<'LF'
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/@mindbox-cloud/ui-components/-/@mindbox-cloud/ui-components-22.1.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm/npm/-/npm-11.17.0.tgz",
      "resolved": "https://artifactory.mindbox.ru/artifactory/api/npm/npm-remote/@types/node/-/node-22.0.0.tgz",
      "resolved": "https://registry.npmjs.org/react/-/react-18.3.1.tgz",
      "resolved": "https://registry.npmjs.org/@babel/core/-/core-7.26.0.tgz",
      "integrity": "sha512-keep",
LF
  (cd "$w" && URL=https://packages.maestra.io bash -c "$prog")
  diff -u "$d/want" "$w/package-lock.json"

  # `replace-registry-host=always` also rewrote nora's own tarball URLs into
  # /npm/npm/<pkg>/-/... (404 for anything resolved from a packument, e.g. npx).
  grep -q '^ *echo "replace-registry-host=npmjs"$' "$wf" \
    || { echo "$(basename "$wf") must write replace-registry-host=npmjs"; exit 1; }
done
echo "npm-lockfile-to-nora: OK"
