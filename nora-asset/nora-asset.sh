#!/usr/bin/env bash
# One release asset from nora, sha256-checked (security-scan/fetch-pinned.sh), optionally installed
# on PATH. Env: ASSET_PATH, ASSET_SHA256, ASSET_BIN, ASSET_MEMBER, ASSET_FILE (action.yml inputs).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail() { echo "::error::nora-asset: $*" >&2; exit 1; }
[[ "$ASSET_PATH" =~ ^(github/[^/]+/[^/]+/releases/download/[^/]+|hashicorp/[^/]+/[^/]+|raw/src/[^/]+(/[^/]+)*)/[^/]+$ && "$ASSET_PATH" != *..* ]] ||
  fail "path '$ASSET_PATH' is not github/<owner>/<repo>/releases/download/<tag>/<asset>, hashicorp/<product>/<version>/<file> or raw/src/<host>/<path>"
[[ "$ASSET_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "sha256 '$ASSET_SHA256' is not 64 hex characters"
[[ "${ASSET_BIN:-}" =~ ^[A-Za-z0-9._-]*$ ]] || fail "bin '$ASSET_BIN' is not a file name"
file=${ASSET_FILE:-$RUNNER_TEMP/nora-asset/$ASSET_SHA256/${ASSET_PATH##*/}}
GITHUB_OUTPUT='' bash "$here/../security-scan/fetch-pinned.sh" "https://packages.maestra.io/$ASSET_PATH" "$ASSET_SHA256" "$file"
echo "file=$file" >> "$GITHUB_OUTPUT"
[ -n "${ASSET_BIN:-}" ] || exit 0
bindir="$RUNNER_TEMP/nora-asset-bin"; mkdir -p "$bindir"
case "${ASSET_MEMBER:-}:$ASSET_PATH" in
  :*) cp "$file" "$bindir/$ASSET_BIN" ;;
  *.zip) python3 -I -c 'import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' \
           "$file" "$ASSET_MEMBER" > "$bindir/$ASSET_BIN" ;;
  *) tar -xOf "$file" "$ASSET_MEMBER" > "$bindir/$ASSET_BIN" ;;
esac
[ -s "$bindir/$ASSET_BIN" ] || fail "$ASSET_MEMBER in ${file##*/} is empty"
chmod 0755 "$bindir/$ASSET_BIN"
echo "$bindir" >> "$GITHUB_PATH"
