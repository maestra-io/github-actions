#!/usr/bin/env bash
#
# Self-check for dotnet-service-build.yml `graphql-schemas`: line parsing, the
# *.maestra.io host and build-context guards, and the loud failures on a 401, an
# HTML login page or a download without SDL. Runs the workflow's own block (both
# copies must be identical) against stub curl and dotnet.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
prog=$(awk 'index($0,"# >>> graphql-schemas"){n++} n==1{print} n==1&&index($0,"# <<< graphql-schemas"){exit}' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "graphql-schemas block not found in $wf"; exit 1; }
[ "$(sed -n '/# >>> graphql-schemas/,/# <<< graphql-schemas/p' "$wf" | sed 's/^          //')" = "$(printf '%s\n%s' "$prog" "$prog")" ] \
  || { echo "FAIL graphql-schemas: the test and images copies differ"; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp/packages-token"
printf 'Username=ci;Password=nora' > "$work/tmp/packages-token/NUGET_CREDENTIALS"
# curl: OIDC -> {"value":"oidc"}; auth-jwt -> {"token":"jwt"}; a GraphQL URI answers per $INTROSPECTION.
cat > "$work/bin/curl" <<'C'
#!/usr/bin/env bash
out=/dev/stdout; fmt=""; url=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -w) fmt="$2"; shift ;; -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    -X|--data|--data-binary|--connect-timeout|--max-time) shift ;; http*) url="$1" ;;
  esac; shift
done
cat >/dev/null 2>&1 </dev/stdin || true
echo "$url $auth" >> "$CALLS"
case "$url" in
  "$ACTIONS_ID_TOKEN_REQUEST_URL"*) echo '{"value":"oidc"}' ;;
  https://auth-jwt.maestra.io/token) echo '{"token":"jwt"}' > "$out"; printf 200 ;;
  *) case "$INTROSPECTION" in
       ok) echo '{"data":{"__schema":{"queryType":{"name":"Q"}}}}' > "$out"; printf 200 ;;
       401) : > "$out"; printf 401 ;;
       html) echo '<html>login</html>' > "$out"; printf 200 ;;
     esac ;;
esac
C
# dotnet tool install -> a dotnet-graphql that writes $DOWNLOAD (sdl|html) to -f.
cat > "$work/bin/dotnet" <<'D'
#!/usr/bin/env bash
echo "dotnet $* cred=$NuGetPackageSourceCredentials_private" >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = --tool-path ] && tp="$2"; shift; done
mkdir -p "$tp"
cat > "$tp/dotnet-graphql" <<'G'
#!/usr/bin/env bash
echo "dotnet-graphql $*" >> "$CALLS"
f=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
if [ "$DOWNLOAD" = sdl ]; then printf 'schema {\n  query: Q\n}\n\ntype Q {\n  a: Int\n}\n' > "$f"; else echo '<html/>' > "$f"; fi
G
chmod +x "$tp/dotnet-graphql"
D
chmod +x "$work/bin/curl" "$work/bin/dotnet"

# run <SCHEMAS> [CONTEXT] [INTROSPECTION] [DOWNLOAD] -> exit code; log in $work/out, calls in $work/calls
run() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"; : > "$work/calls"; local rc=0
  (cd "$work/repo" && PATH="$work/bin:$PATH" CALLS="$work/calls" RUNNER_TEMP="$work/tmp" \
    SCHEMAS="$1" CONTEXT="${2:-.}" INTROSPECTION="${3:-ok}" DOWNLOAD="${4:-sdl}" \
    PACKAGES_URL=https://packages.maestra.io AUTH_JWT_URL=https://auth-jwt.maestra.io \
    AUTH_JWT_CLIENT=github-dotnet-graphql-schema TOOL_VERSION=15.1.3 \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example/t?x=1' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
    bash -c "set -eo pipefail; $prog") >"$work/out" 2>&1 || rc=$?
  echo "$rc"
}
ok() { [ "$(run "$@")" = 0 ] || { cat "$work/out"; echo "FAIL: rejected '$1'"; exit 1; }; }
fails() { # <want in the log> <run args...>
  local want="$1"; shift
  [ "$(run "$@")" != 0 ] || { cat "$work/out"; echo "FAIL: accepted '$1'"; exit 1; }
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL: '$1' failed without '$want'"; exit 1; }
}

two=$'# CDP\nhttps://test-maestra.maestra.io/graphql/ src/Cdp/schema.graphql\n\n  https://scenarios.omega.maestra.io/graphql/   ./src/Sc/schema.graphql  # scenarios\r'
ok "$two"
[ -s "$work/repo/src/Cdp/schema.graphql" ] && [ -s "$work/repo/src/Sc/schema.graphql" ] || { echo "FAIL: schemas not written"; exit 1; }
grep -qF "dotnet-graphql download https://test-maestra.maestra.io/graphql/ -f $work/repo/src/Cdp/schema.graphql --token jwt" "$work/calls" \
  || { cat "$work/calls"; echo "FAIL: download call"; exit 1; }
grep -qF "https://scenarios.omega.maestra.io/graphql/ Authorization: Bearer jwt" "$work/calls" || { echo "FAIL: introspection without the JWT"; exit 1; }
grep -qF "cred=Username=ci;Password=nora" "$work/calls" || { echo "FAIL: tool install without the nora credentials"; exit 1; }
[ "$(grep -c '^dotnet tool install' "$work/calls")" = 1 ] || { echo "FAIL: tool installed more than once"; exit 1; }
ok "https://x.maestra.io/graphql email/schema.graphql" email/
ok "https://x.maestra.io/graphql ./email/schema.graphql" ./email

fails "not an https://*.maestra.io URL" "https://evil.example/graphql a.graphql"
fails "not an https://*.maestra.io URL" "https://maestra.io.evil.example/graphql a.graphql"
fails "not an https://*.maestra.io URL" "https://x.maestra.io@evil.example/graphql a.graphql"
fails "not an https://*.maestra.io URL" "http://x.maestra.io/graphql a.graphql"
fails "not an https://*.maestra.io URL" "https://maestra.io/graphql a.graphql"
fails "is not '<uri> <path>'" "https://x.maestra.io/graphql"
fails "is not '<uri> <path>'" "https://x.maestra.io/graphql a.graphql extra"
fails "must be relative" "https://x.maestra.io/graphql /etc/a.graphql"
fails "must be relative" "https://x.maestra.io/graphql src/../../a.graphql"
fails "outside the build context" "https://x.maestra.io/graphql src/a.graphql" email
fails "has no '<uri> <path>' line" $'# nothing\n'
[ ! -s "$work/calls" ] || { echo "FAIL: a rejected line still minted a token"; exit 1; }
fails "HTTP 401" "https://x.maestra.io/graphql a.graphql" . 401
fails "not a GraphQL introspection result: <html>" "https://x.maestra.io/graphql a.graphql" . html
fails "wrote no SDL" "https://x.maestra.io/graphql a.graphql" . ok html
echo "dotnet-service-build graphql-schemas: OK"
