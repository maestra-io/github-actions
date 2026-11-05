#!/usr/bin/env bash
# uv-nora/uv-nora.sh with a stub `curl` on PATH: UV_* exported, the keyring helper
# on GITHUB_PATH (fresh token for nora URLs, nothing for any other host), the
# token output, and the refusal without the id-token permission. When uv is on
# PATH, `uv lock` against a pyproject naming the index must run the helper.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../uv-nora/uv-nora.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/tmp"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" -H Authorization: bearer req-token "* ]] || { echo "bad auth header: $*" >&2; exit 22; }
[[ " $* " == *" --get "*" --data-urlencode audience=packages.maestra.io "* ]] || { echo "bad audience: $*" >&2; exit 22; }
[[ "${*: -1}" == "https://idtok.example/x?api-version=2.0" ]] || { echo "bad url: ${*: -1}" >&2; exit 22; }
[ -z "${CURL_LOG:-}" ] || echo called >> "$CURL_LOG"
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"
fail() { echo "FAIL: $*" >&2; exit 1; }
oidc=(ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token)

run() { # $1 = NORA_URL
  env -i PATH="$root/bin:$PATH" HOME="$root" RUNNER_TEMP="$root/tmp" GITHUB_ENV="$root/env" \
    GITHUB_PATH="$root/path" GITHUB_OUTPUT="$root/out" NORA_URL="$1" NORA_AUDIENCE=packages.maestra.io \
    "${oidc[@]}" bash "$script" > "$root/log" 2>&1 || fail "run: $(cat "$root/log")"
}
run https://packages.maestra.io/
helper="$root/tmp/uv-nora/bin/keyring"
printf 'UV_KEYRING_PROVIDER=subprocess\nUV_INDEX_MAESTRA_USERNAME=token\n' | diff - "$root/env" || fail "GITHUB_ENV"
[ "$(cat "$root/path")" = "$root/tmp/uv-nora/bin" ] || fail "GITHUB_PATH: $(cat "$root/path")"
[ "$(cat "$root/out")" = "token=eyJ.stub.jwt" ] || fail "output: $(cat "$root/out")"
grep -q '::add-mask::eyJ.stub.jwt' "$root/log" || fail "token not masked"
kr() { env PATH="$root/bin:$PATH" "${oidc[@]}" "$helper" "$@"; }
[ "$(kr get https://packages.maestra.io/simple/ token)" = eyJ.stub.jwt ] || fail "helper index url"
[ "$(kr get https://packages.maestra.io/simple/six/six-1.17.0-py2.py3-none-any.whl token)" = eyJ.stub.jwt ] || fail "helper file url"
! kr get https://pypi.org/simple/ token > /dev/null 2>&1 || fail "helper answered for pypi.org"
! kr get https://packages.maestra.io.evil.example/simple/ token > /dev/null 2>&1 || fail "helper answered for a look-alike host"
! kr set https://packages.maestra.io/simple/ token < /dev/null > /dev/null 2>&1 || fail "helper accepted set"

if command -v uv >/dev/null && command -v python3 >/dev/null; then
  # A local index that answers 401 to anything without credentials: uv asks the
  # keyring only after a 401, and the helper's stub-curl call proves it ran.
  cat > "$root/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404 if self.headers.get("Authorization") else 401)
        self.send_header("WWW-Authenticate", 'Basic realm="nora"'); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print(s.server_port, flush=True); s.serve_forever()
PY
  python3 "$root/srv.py" > "$root/port" & srv=$!
  trap 'kill $srv 2>/dev/null; rm -rf "$root"' EXIT
  for _ in $(seq 50); do [ -s "$root/port" ] && break; sleep 0.1; done
  base="http://127.0.0.1:$(cat "$root/port")"
  run "$base"
  mkdir -p "$root/proj"
  printf '%s\n' '[project]' 'name = "p"' 'version = "0"' 'requires-python = ">=3.8"' 'dependencies = ["six"]' \
    '[[tool.uv.index]]' 'name = "maestra"' "url = \"$base/simple/\"" 'default = true' > "$root/proj/pyproject.toml"
  mapfile -t uvenv < "$root/env"
  ( cd "$root/proj" && env -i PATH="$root/tmp/uv-nora/bin:$root/bin:$PATH" HOME="$root" "${oidc[@]}" \
      "${uvenv[@]}" UV_NO_CACHE=1 UV_PYTHON_DOWNLOADS=never UV_HTTP_RETRIES=0 CURL_LOG="$root/curl.log" \
      uv lock > "$root/uv.log" 2>&1 ) || true
  [ -s "$root/curl.log" ] || fail "uv never ran the keyring helper: $(tail -3 "$root/uv.log")"
fi

# Refusal: no id-token permission.
mkdir -p "$root/noid"
! env -i PATH="$PATH" HOME="$root/noid" RUNNER_TEMP="$root/noid" GITHUB_ENV="$root/noid/env" GITHUB_PATH="$root/noid/path" \
  GITHUB_OUTPUT="$root/noid/out" NORA_URL=https://packages.maestra.io NORA_AUDIENCE=packages.maestra.io bash "$script" \
  > "$root/noid/log" 2>&1 || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message"
echo "uv-nora: ok"
