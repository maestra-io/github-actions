#!/usr/bin/env bash
#
# Self-check for dotnet-service-build.yml `graphql-schemas`: the .graphqlrc.json
# discovery, the *.maestra.io host, path and build-context guards, the
# private-packages-token conflict, and the loud failures on a missing OIDC token,
# an auth-jwt error, a curl transport error, a 401, an HTML login page or a download without SDL. Runs the
# workflow's own block (`test` job, the only copy) against stub curl and dotnet.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
[ "$(grep -c '# >>> graphql-schemas' "$wf")" = 1 ] || { echo "FAIL graphql-schemas: expected exactly one copy of the block in $wf"; exit 1; }
prog=$(sed -n '/# >>> graphql-schemas/,/# <<< graphql-schemas/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "graphql-schemas block not found in $wf"; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/tmp/packages-token"
printf 'Username=ci;Password=nora' > "$work/tmp/packages-token/NUGET_CREDENTIALS"
# curl: OIDC -> {"value":"oidc"} and auth-jwt -> {"token":"jwt"} unless $AUTH says otherwise;
# a GraphQL URI answers per $INTROSPECTION.
cat > "$work/bin/curl" <<'C'
#!/usr/bin/env bash
out=/dev/stdout; url=""; auth=""; stdin=false
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    --data-binary) [ "$2" = @- ] && stdin=true; shift ;;
    -w|-X|--data|--connect-timeout|--max-time|--retry) shift ;; http*) url="$1" ;;
  esac; shift
done
if $stdin; then cat >/dev/null; fi
echo "$url $auth" >> "$CALLS"
case "$url" in
  "$ACTIONS_ID_TOKEN_REQUEST_URL"*) if [ "$AUTH" = oidc-empty ]; then echo '{}'; else echo '{"value":"oidc"}'; fi ;;
  https://auth-jwt.maestra.io/token) case "$AUTH" in
       jwt-403) echo '{"error":"forbidden"}' > "$out"; printf 403 ;;
       jwt-transport) printf 000; exit 7 ;;
       jwt-notoken) echo '{}' > "$out"; printf 200 ;;
       *) echo '{"token":"jwt"}' > "$out"; printf 200 ;;
     esac ;;
  *) case "$INTROSPECTION" in
       ok) echo '{"data":{"__schema":{"queryType":{"name":"Q"}}}}' > "$out"; printf 200 ;;
       401) : > "$out"; printf 401 ;;
       transport) printf 000; exit 28 ;;
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
echo "dotnet-graphql $* roll=${DOTNET_ROLL_FORWARD:-} root=${DOTNET_ROOT:-}" >> "$CALLS"
f=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
if [ "$DOWNLOAD" = sdl ]; then printf 'schema {\n  query: Q\n}\n\ntype Q {\n  a: Int\n}\n' > "$f"; else echo '<html/>' > "$f"; fi
G
chmod +x "$tp/dotnet-graphql"
D
chmod +x "$work/bin/curl" "$work/bin/dotnet"

fresh() { rm -rf "$work/repo" "$work/tmp/graphql-schemas.tgz" "$work/tmp/jwt.json"; mkdir -p "$work/repo"; : > "$work/tmp/output"; }
# rc <dir> <url> [schema]: a StrawberryShake .graphqlrc.json in the repo
rc() {
  mkdir -p "$work/repo/$1"
  jq -n --arg u "$2" --arg s "${3-schema.graphql}" '{schema: $s, documents: "**/*.graphql", extensions: {strawberryShake: {name: "C", url: $u}}}' \
    > "$work/repo/$1/.graphqlrc.json"
}
# run [MATRIX] [INTROSPECTION] [DOWNLOAD] [AUTH] [HAS_TOKEN_OVERRIDE] -> exit code; log in $work/out, calls in $work/calls
run() {
  : > "$work/calls"; local rc=0 root='[{"context":"."}]'
  (cd "$work/repo" && PATH="$work/bin:$PATH" CALLS="$work/calls" RUNNER_TEMP="$work/tmp" GITHUB_OUTPUT="$work/tmp/output" \
    MATRIX="${1:-$root}" INTROSPECTION="${2:-ok}" DOWNLOAD="${3:-sdl}" AUTH="${4:-ok}" \
    HAS_TOKEN_OVERRIDE="${5:-false}" RUN_ATTEMPT=1 DOTNET_ROOT= \
    PACKAGES_URL=https://packages.maestra.io AUTH_JWT_URL=https://auth-jwt.maestra.io \
    AUTH_JWT_CLIENT=github-dotnet-graphql-schema TOOL_VERSION=15.1.3 \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example/t?x=1' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
    bash -c "set -eo pipefail; $prog") >"$work/out" 2>&1 || rc=$?
  echo "$rc"
}
ok() { [ "$(run "$@")" = 0 ] || { cat "$work/out"; echo "FAIL: rejected (${1:-default matrix})"; exit 1; }; }
fails() { # <want in the log> <run args...>
  local want="$1"; shift
  [ "$(run "$@")" != 0 ] || { cat "$work/out"; echo "FAIL: accepted, wanted '$want'"; exit 1; }
  grep -qF -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL: failed without '$want'"; exit 1; }
}
rejects() { # <want> <run args...>: fails before any network call
  fails "$@"
  [ ! -s "$work/calls" ] || { cat "$work/calls"; echo "FAIL: '$1' rejected, but still called out"; exit 1; }
}

# Two clients, plus rc files that must be ignored: a non-StrawberryShake one, and copies
# under bin/obj/node_modules with a foreign host (picked up, they would fail the run).
fresh
rc src/Cdp https://test-maestra.maestra.io/graphql/
rc "src/Sc Meta" https://scenarios.omega.maestra.io/graphql/ api.graphql
for d in src/Cdp/bin/Debug src/Cdp/obj node_modules/pkg; do rc "$d" https://evil.example/graphql; done
mkdir -p "$work/repo/web"; echo '{"schema":"web.graphql"}' > "$work/repo/web/.graphqlrc.json"
ok
[ -s "$work/repo/src/Cdp/schema.graphql" ] && [ -s "$work/repo/src/Sc Meta/api.graphql" ] || { echo "FAIL: schemas not written"; exit 1; }
grep -qF "dotnet-graphql download https://test-maestra.maestra.io/graphql/ -f $work/repo/src/Cdp/schema.graphql --token jwt roll=Major root=$(cd "$work/bin" && pwd -P)" "$work/calls" \
  || { cat "$work/calls"; echo "FAIL: download call (path, token, DOTNET_ROLL_FORWARD, DOTNET_ROOT)"; exit 1; }
grep -qF "https://scenarios.omega.maestra.io/graphql/ Authorization: Bearer jwt" "$work/calls" || { echo "FAIL: introspection without the JWT"; exit 1; }
! grep -qF evil.example "$work/calls" || { echo "FAIL: an rc file under bin/obj/node_modules was used"; exit 1; }
grep -qF "cred=Username=ci;Password=nora" "$work/calls" || { echo "FAIL: tool install without the nora credentials"; exit 1; }
[ "$(grep -c '^dotnet tool install' "$work/calls")" = 1 ] || { echo "FAIL: tool installed more than once"; exit 1; }
grep -qF "no extensions.strawberryShake, skipped" "$work/out" || { echo "FAIL: non-StrawberryShake rc not reported"; exit 1; }
[ "$(tar -tzf "$work/tmp/graphql-schemas.tgz" | sort | tr '\n' '|')" = "./src/Cdp/schema.graphql|./src/Sc Meta/api.graphql|" ] \
  || { tar -tzf "$work/tmp/graphql-schemas.tgz"; echo "FAIL: artifact archive content"; exit 1; }
grep -qE '^artifact=graphql-schemas-1-.+' "$work/tmp/output" || { cat "$work/tmp/output"; echo "FAIL: no artifact output"; exit 1; }
[ ! -e "$work/tmp/jwt.json" ] || { echo "FAIL: jwt.json left behind"; exit 1; }

# Build contexts: inside at least one images leg's context.
fresh; rc email https://x.maestra.io/graphql
ok '[{"context":"./email/"},{"context":"api"}]'
ok '[{"context":"api"},{"context":"."}]'
ok '[{"context":"email/."}]'
ok '[{"context":"./email/./"}]'
fresh; rc src https://x.maestra.io/graphql
rejects "'src/schema.graphql' is outside every images build context: api email" '[{"context":"email"},{"context":"api"}]'
fresh; rc emailer https://x.maestra.io/graphql
rejects "is outside every images build context" '[{"context":"email"}]'

# Rejected before any token is minted.
for u in https://evil.example/graphql https://maestra.io.evil.example/graphql https://x.maestra.io@evil.example/graphql \
         http://x.maestra.io/graphql https://maestra.io/graphql; do
  fresh; rc src "$u"; rejects "'$u' is not an https://*.maestra.io URL"
done
fresh; rc src https://x.maestra.io/graphql /etc/a.graphql; rejects "'/etc/a.graphql' must be relative"
fresh; rc src https://x.maestra.io/graphql ../../a.graphql; rejects "'../../a.graphql' must be relative"
fresh; mkdir -p "$work/repo/src"; echo '{"schema":"s.graphql","extensions":{"strawberryShake":{"name":"C"}}}' > "$work/repo/src/.graphqlrc.json"
rejects "src/.graphqlrc.json has no extensions.strawberryShake.url"
fresh; mkdir -p "$work/repo/src"; echo '{"extensions":{"strawberryShake":{"url":"https://x.maestra.io/graphql"}}}' > "$work/repo/src/.graphqlrc.json"
rejects "src/.graphqlrc.json has no schema file"
fresh; mkdir -p "$work/repo/src"; echo '{"schema":' > "$work/repo/src/.graphqlrc.json"; rejects "src/.graphqlrc.json is not valid JSON"
fresh; rejects "no .graphqlrc.json with extensions.strawberryShake in the repo"
fresh; mkdir -p "$work/repo/web"; echo '{"schema":"web.graphql"}' > "$work/repo/web/.graphqlrc.json"
rejects "no .graphqlrc.json with extensions.strawberryShake in the repo"
fresh; rc src https://x.maestra.io/graphql; rejects "cannot be combined with the private-packages-token secret" "" ok sdl ok true

# Token and download failures.
fresh; rc src https://x.maestra.io/graphql
fails "no GitHub OIDC token" "" ok sdl oidc-empty
fails "auth-jwt https://auth-jwt.maestra.io/token as github-dotnet-graphql-schema: HTTP 403" "" ok sdl jwt-403
[ ! -e "$work/tmp/jwt.json" ] || { echo "FAIL: jwt.json left behind after an auth-jwt error"; exit 1; }
fails "auth-jwt response has no token" "" ok sdl jwt-notoken
! grep -q '^dotnet' "$work/calls" || { echo "FAIL: tool installed without a JWT"; exit 1; }
fails "HTTP 401" "" 401
fails "auth-jwt https://auth-jwt.maestra.io/token as github-dotnet-graphql-schema: HTTP 000" "" ok sdl jwt-transport
fails "https://x.maestra.io/graphql: HTTP 000, not a GraphQL introspection result" "" transport
fails "not a GraphQL introspection result: <html>" "" html
fails "wrote no SDL" "" ok html
echo "dotnet-service-build graphql-schemas: OK"
