#!/usr/bin/env bash
# security-scan/fetch-pinned.sh (stub curl): a miss fetches with the OIDC credential on stdin and
# writes fetched=true; a cached copy with the pinned sha256 fetches nothing; a cached copy that
# is not the pin is refetched; a download that is not the pin fails and leaves no file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../security-scan/fetch-pinned.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  *audience=packages.maestra.io) echo '{"value":"eyJ.stub.jwt"}' ;;
  https://packages.maestra.io/github/*)
    echo "${*: -1}" >> "$BODY.calls"
    cfg=$(cat)
    [ "$cfg" = 'user = "oidc:eyJ.stub.jwt"' ] || { echo "bad credential config: $cfg" >&2; exit 22; }
    while [ $# -gt 1 ]; do if [ "$1" = -o ]; then cp "$BODY" "$2"; exit 0; fi; shift; done; exit 22 ;;
  *) echo "unexpected curl: $*" >&2; exit 22 ;;
esac
STUB
chmod +x "$root/bin/curl"
echo good > "$root/body"; sum=$(sha256sum "$root/body" | cut -d' ' -f1)
f="$root/cache/tool.tar.gz" url=https://packages.maestra.io/github/o/r/releases/download/v1/tool.tar.gz
run() {
  rm -f "$root/body.calls"; : > "$root/out"
  PATH="$root/bin:$PATH" BODY="$root/body" GITHUB_OUTPUT="$root/out" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  bash "$script" "$url" "$sum" "$f" > "$root/log" 2>&1
}
run || fail "miss: $(cat "$root/log")"
{ [ -s "$root/body.calls" ] && cmp -s "$root/body" "$f"; } || fail "miss: not fetched into $f"
grep -qx fetched=true "$root/out" || fail "miss: no fetched=true"
echo tampered > "$root/body" # a hit must not ask nora
run || fail "hit: $(cat "$root/log")"
[ ! -e "$root/body.calls" ] || fail "hit fetched from nora"
! grep -q fetched "$root/out" || fail "hit asked for a save"
echo good > "$root/body"; echo poisoned > "$f"
run || fail "poisoned cache: $(cat "$root/log")"
{ [ -s "$root/body.calls" ] && cmp -s "$root/body" "$f"; } || fail "poisoned cache copy was used"
grep -q "not the sha256 pin" "$root/log" || fail "poisoned cache not reported"
echo tampered > "$root/body"; rm -f "$f"
if run; then fail "a download that is not the pin was accepted"; fi
[ ! -e "$f" ] || fail "the refused download was left in place"
echo "fetch-pinned: ok"
