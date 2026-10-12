#!/usr/bin/env bash
#
# Self-check for the packages token in dotnet-service-build.yml (and the layer-cache
# copy in service-build.yml). A BuildKit secret's value is not part of the layer cache
# key, so a GitLab-era Dockerfile that writes the token into NuGet.Config gets that
# layer replayed by the cache after the token expired, and the first later RUN that
# restores (publish -r <rid>: runtime packs) fails 401 (maestra-io/billing). Checks:
#   1. layer-cache: such a Dockerfile builds without the cache, a clean one with it;
#   2. token-files: the secret files carry the override / a minted token in NuGet's
#      env-credential format and are re-minted in the background;
#   3. end to end (docker, a fake feed that accepts only the CURRENT token): the
#      GitLab-era Dockerfile with the cache fails exactly like billing did, without
#      the cache it passes; after scripts/nuget-secret-mount-fix.sh it passes WITH the
#      cache (restore layer reused) and no layer holds a token.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
sb="$here/../.github/workflows/service-build.yml"
fx="$here/../ci/fixtures/nuget-token-cache"
block() { sed -n "/# >>> $1/,/# <<< $1/p" "$2" | sed 's/^          //'; }
first() { awk -v b="# >>> $1" -v e="# <<< $1" 'index($0,b){n++} n==1{print} n==1&&index($0,e){exit}' "$2" | sed 's/^          //'; }
cache=$(first layer-cache "$wf"); files=$(first token-files "$wf")
[ -n "$cache" ] && [ -n "$files" ] || { echo "layer-cache/token-files block not found in $wf"; exit 1; }
# Every copy is the same code: <name> <file> <expected copies>
same() {
  local n; n=$(grep -c "# >>> $1" "$2")
  [ "$n" -eq "$3" ] || { echo "FAIL $1: $n copies in $2, want $3"; exit 1; }
  [ "$(block "$1" "$2")" = "$(for _ in $(seq 1 "$n"); do printf '%s\n' "$(first "$1" "$wf")"; done)" ] \
    || { echo "FAIL $1 copies differ in $2"; exit 1; }
}
same layer-cache "$wf" 4   # test, test base-image, images base-image, images
same layer-cache "$sb" 2
same token-files "$wf" 2

work=$(mktemp -d)
feed=""
cleanup() { [ -z "$feed" ] || kill "$feed" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

# ── 1. layer-cache ─────────────────────────────────────────────────────────────
# cache_for <dockerfile> <scopes> -> "<from lines joined by ' '>|<to>"
cache_for() {
  : > "$work/out"
  DOCKERFILE="$1" SCOPES="$2" GITHUB_OUTPUT="$work/out" bash -c "set -eo pipefail; $cache" >/dev/null
  from=$(awk '/^from<</{f=1;next} /^__CACHE__$/{f=0} f' "$work/out" | paste -sd' ' -)
  echo "${from}|$(sed -n 's/^to=//p' "$work/out")"
}
"$here/nuget-secret-mount-fix.sh" "$(cp "$fx/Dockerfile.gitlab" "$work/Dockerfile.fixed" && echo "$work/Dockerfile.fixed")" >/dev/null
grep -q 'id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private dotnet publish' "$work/Dockerfile.fixed" \
  || { cat "$work/Dockerfile.fixed"; echo "FAIL nuget-secret-mount-fix did not mount the publish RUN"; exit 1; }
eq "$("$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.fixed")" "unchanged: $work/Dockerfile.fixed" "nuget-secret-mount-fix idempotent"
printf 'FROM sdk\r\nRUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN dotnet nuget update source maestra --username ci --password $(cat /run/secrets/PRIVATE_PACKAGES_TOKEN) --store-password-in-clear-text\r\nRUN dotnet restore && dotnet test --no-build\r\n' > "$work/Dockerfile.crlf"
"$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.crlf" >/dev/null
eq "$(cat "$work/Dockerfile.crlf")" "$(printf 'FROM sdk\r\nRUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_maestra dotnet restore && dotnet test --no-build\r\n')" "nuget-secret-mount-fix: other source name, CRLF kept"
printf 'FROM sdk\nRUN --mount=type=secret,id=T dotnet nuget update source private --password $(cat /run/secrets/T) && dotnet restore\n' > "$work/Dockerfile.chained"
cp "$work/Dockerfile.chained" "$work/Dockerfile.chained.orig"
"$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.chained" | grep -q 'fix by hand' || { echo "FAIL nuget-secret-mount-fix: chained credential RUN not reported"; exit 1; }
cmp -s "$work/Dockerfile.chained" "$work/Dockerfile.chained.orig" || { echo "FAIL nuget-secret-mount-fix: chained credential RUN changed"; exit 1; }
eq "$(cache_for "$fx/Dockerfile.gitlab" $'img\ntests')" "|" "GitLab-era Dockerfile: no cache"
eq "$(cache_for "$work/Dockerfile.fixed" $'img\ntests')" "type=gha,scope=img type=gha,scope=tests|type=gha,mode=max,scope=img" "fixed Dockerfile: cache"
eq "$(cache_for "$work/Dockerfile.fixed" $'img\n')" "type=gha,scope=img|type=gha,mode=max,scope=img" "no docker-test-target"
eq "$(cache_for "$work/Dockerfile.fixed" "tests")" "type=gha,scope=tests|type=gha,mode=max,scope=tests" "test job"
for persist in 'ARG PRIVATE_PACKAGES_TOKEN' \
               'RUN --mount=type=secret,id=T npm config set //packages.maestra.io/npm/:_authToken $(cat /run/secrets/T)' \
               'RUN --mount=type=secret,id=T poetry config http-basic.maestra token $(cat /run/secrets/T)' \
               '<add key="ClearTextPassword" value="x" />'; do
  printf 'FROM busybox\n%s\n' "$persist" > "$work/Dockerfile.p"
  eq "$(cache_for "$work/Dockerfile.p" img)" "|" "persists: $persist"
done
echo "ok layer-cache"

# ── 2. token-files ─────────────────────────────────────────────────────────────
tf="$work/rt/packages-token"
RUNNER_TEMP="$work/rt" OVERRIDE=tok-override AUDIENCE=aud bash -c "set -eo pipefail; $files"
eq "$(cat "$tf/PRIVATE_PACKAGES_TOKEN")" "tok-override" "override token file"
eq "$(cat "$tf/NUGET_CREDENTIALS")" "Username=ci;Password=tok-override" "override NuGet credentials"
mkdir -p "$work/bin"; echo 0 > "$work/n"
cat > "$work/bin/curl" <<'C'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_N") + 1 )); echo "$n" > "$CURL_N"; printf '%s\n' "$*" >> "$CURL_N.args"
[ -z "${CURL_FAIL:-}" ] || exit 22
printf '{"count":1,"value":"tok-%s"}' "$n"
C
chmod +x "$work/bin/curl"
# The background loop stops after the 3rd mint (sleep is stubbed).
PATH="$work/bin:$PATH" CURL_N="$work/n" RUNNER_TEMP="$work/rt2" OVERRIDE="" AUDIENCE=packages.example \
  ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/x?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  bash -c "set -eo pipefail; sleep() { command sleep 0.1; [ \"\$(cat \"\$CURL_N\")\" -lt 3 ]; }; $files"
for _ in $(seq 1 50); do [ "$(cat "$work/n")" -ge 3 ] && break; command sleep 0.1; done
command sleep 0.3
eq "$(cat "$work/rt2/packages-token/NUGET_CREDENTIALS")" "Username=ci;Password=tok-3" "re-minted NuGet credentials"
eq "$(cat "$work/rt2/packages-token/PRIVATE_PACKAGES_TOKEN")" "tok-3" "re-minted token"
grep -q 'https://token.example/x?api-version=2.0&audience=packages.example' "$work/n.args" || { cat "$work/n.args"; echo "FAIL audience not requested"; exit 1; }
if PATH="$work/bin:$PATH" CURL_N="$work/n" CURL_FAIL=1 RUNNER_TEMP="$work/rt3" OVERRIDE="" AUDIENCE=a \
     ACTIONS_ID_TOKEN_REQUEST_URL="https://x/?a=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
     bash -c "set -eo pipefail; $files" >/dev/null 2>&1; then
  echo "FAIL token-files: a failed mint passed"; exit 1
fi
echo "ok token-files"

# ── 3. end to end ──────────────────────────────────────────────────────────────
port=18737
cp -R "$fx/." "$work/ctx/" 2>/dev/null || { mkdir -p "$work/ctx"; cp -R "$fx/." "$work/ctx/"; }
cp "$work/Dockerfile.fixed" "$work/ctx/Dockerfile.fixed"
# Unique per invocation: the daemon keeps the layer cache of earlier invocations.
nonce="$$-$RANDOM"; A="tok-A-$nonce"; B="tok-B-$nonce"
echo "$A" > "$work/token"
echo "<!-- $nonce -->" >> "$work/ctx/nuget.config" # and a layer chain of its own: no earlier token to replay
python3 -I "$fx/feed.py" "$port" "$work/token" "$work/feed.log" & feed=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; command sleep 0.1; done

# token <value>: the workflow's token files hold this token, and the feed accepts only it.
token() { echo "$1" > "$work/token"; RUNNER_TEMP="$work/e2e" OVERRIDE="$1" AUDIENCE=a bash -c "set -eo pipefail; $files"; }
# build <dockerfile> [docker flags]: a new commit (Program.cs changes), target publish.
build() {
  local df="$1"; shift
  echo "// $RANDOM$RANDOM" >> "$work/ctx/App/Program.cs"
  : > "$work/feed.log"
  docker buildx build --progress plain --load "$@" \
    --add-host host.docker.internal:host-gateway \
    --secret "id=PRIVATE_PACKAGES_TOKEN,src=$work/e2e/packages-token/PRIVATE_PACKAGES_TOKEN" \
    --secret "id=NUGET_CREDENTIALS,src=$work/e2e/packages-token/NUGET_CREDENTIALS" \
    -f "$work/ctx/$df" --target publish -t "local/selftest-token-cache:${df##*.}" "$work/ctx" >"$work/build.log" 2>&1
}
must() { build "$@" || { grep -E "error|401|CACHED|DONE" "$work/build.log" | tail -40; cat "$work/feed.log"; echo "FAIL build $*"; exit 1; }; }
leaks() { docker run --rm --entrypoint sh "local/selftest-token-cache:$1" -c "grep -rlE '$A|$B' /sln /root/.nuget/NuGet 2>/dev/null || true"; }

# GitLab-era: run 1 seeds the cache (token A), run 2 (token B, A has expired) reuses
# the NuGet.Config layer with A; publish restores Selftest.Publish -> 401.
token "$A"; must Dockerfile.gitlab
token "$B"
if build Dockerfile.gitlab; then tail -40 "$work/build.log"; echo "FAIL GitLab-era Dockerfile with the cache passed: the e2e no longer reproduces the expired-token replay"; exit 1; fi
grep -q '^401 .*selftest.publish' "$work/feed.log" || { tail -40 "$work/build.log"; cat "$work/feed.log"; echo "FAIL GitLab-era: no 401 on the publish restore"; exit 1; }
echo "ok GitLab-era Dockerfile + layer cache: publish restore 401 with the replayed token"
must Dockerfile.gitlab --no-cache
[ -n "$(leaks gitlab)" ] || { echo "FAIL leak check finds nothing in the GitLab-era image"; exit 1; }
echo "ok GitLab-era Dockerfile without the layer cache (what the workflow does): passes"

# Fixed: same two runs pass, the restore layer comes from the cache, no token in a layer.
token "$A"; must Dockerfile.fixed
token "$B"; must Dockerfile.fixed
if grep -q 'selftest.build' "$work/feed.log"; then cat "$work/feed.log"; echo "FAIL fixed: restore layer not reused from the cache"; exit 1; fi
grep -q '^200 .*selftest.publish.1.0.0.nupkg' "$work/feed.log" || { cat "$work/feed.log"; echo "FAIL fixed: publish did not restore from the feed"; exit 1; }
eq "$(leaks fixed)" "" "no token in the fixed image"
echo "ok fixed Dockerfile + layer cache: publish restores with the current token, no token in any layer"
docker rmi -f local/selftest-token-cache:gitlab local/selftest-token-cache:fixed >/dev/null 2>&1 || true
echo "dotnet-service-build packages token: OK"
