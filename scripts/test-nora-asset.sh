#!/usr/bin/env bash
# nora-asset/nora-asset.sh (stub curl): a raw binary, a tar member and a zip member land on PATH; a
# sha256 mismatch, a path outside the two nora proxies and a missing member fail and install nothing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$root/log" >&2; exit 1; }
mkdir -p "$root/bin" "$root/src/d"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  *audience=packages.maestra.io) echo '{"value":"eyJ.stub.jwt"}' ;;
  https://packages.maestra.io/*)
    grep -qx 'user = "oidc:eyJ.stub.jwt"' || exit 22
    while [ $# -gt 1 ]; do if [ "$1" = -o ]; then cp "$BODY" "$2"; exit 0; fi; shift; done; exit 22 ;;
  *) echo "unexpected curl: $*" >&2; exit 22 ;;
esac
STUB
chmod +x "$root/bin/curl"
printf '#!/bin/sh\necho tool-ran\n' > "$root/src/d/tool"
tar -czf "$root/t.tar.gz" -C "$root/src" d/tool
(cd "$root/src" && python3 -I -c 'import zipfile; zipfile.ZipFile("../t.zip", "w").write("d/tool")')
sum() { sha256sum "$1" | cut -d' ' -f1; }
run() { # body path sha256 bin member
  rm -rf "$root/tmp"; mkdir "$root/tmp"; : > "$root/out"; : > "$root/path"
  PATH="$root/bin:$PATH" BODY="$1" ASSET_PATH=$2 ASSET_SHA256=$3 ASSET_BIN=$4 ASSET_MEMBER=$5 ASSET_FILE='' \
  RUNNER_TEMP="$root/tmp" GITHUB_OUTPUT="$root/out" GITHUB_PATH="$root/path" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  bash "$here/../nora-asset/nora-asset.sh" > "$root/log" 2>&1
}
gh=github/o/r/releases/download/v1
installed() { [ "$("$(cat "$root/path")/mytool")" = tool-ran ] || fail "$1: mytool does not run from PATH"; }
refused() { [ ! -s "$root/path" ] || fail "$1: PATH changed"; }

run "$root/src/d/tool" "$gh/tool-linux" "$(sum "$root/src/d/tool")" mytool '' || fail "raw binary"
installed "raw binary"
[ "$(cat "$root/out")" = "file=$root/tmp/nora-asset/tool-linux" ] || fail "outputs: $(cat "$root/out")"
run "$root/t.tar.gz" "$gh/t.tar.gz" "$(sum "$root/t.tar.gz")" mytool d/tool || fail "tar member"; installed "tar member"
run "$root/t.zip" hashicorp/p/1.0.0/t.zip "$(sum "$root/t.zip")" mytool d/tool || fail "zip member"; installed "zip member"
run "$root/t.tar.gz" 'github/o/r/releases/download/cmd%2Fv1/t.tar.gz' "$(sum "$root/t.tar.gz")" '' '' || fail "download only"
refused "download only"
run "$root/t.zip" "$gh/t.tar.gz" "$(sum "$root/t.tar.gz")" mytool d/tool && fail "wrong sha256 passed"; refused "wrong sha256"
[ ! -e "$root/tmp/nora-asset/t.tar.gz" ] || fail "wrong sha256: the file stayed"
run "$root/t.tar.gz" "$gh/t.tar.gz" "$(sum "$root/t.tar.gz")" mytool d/none && fail "missing member passed"; refused "missing member"
for p in github/o/r/releases/latest/download/t.tar.gz npm/x "$gh/../../t.tar.gz" https://github.com/o/r/releases/download/v1/t; do
  run "$root/t.tar.gz" "$p" "$(sum "$root/t.tar.gz")" mytool d/tool && fail "path '$p' passed"; refused "path '$p'"
done
run "$root/t.tar.gz" "$gh/t.tar.gz" abc mytool d/tool && fail "short sha256 passed"; refused "short sha256"
run "$root/src/d/tool" "$gh/tool-linux" "$(sum "$root/src/d/tool")" ../x '' && fail "bin with a / passed"; refused "bin with a /"
echo "ok: nora-asset"
