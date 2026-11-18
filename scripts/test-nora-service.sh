#!/usr/bin/env bash
# nora-service (main.js -> nora-service.sh, post.js) with stub `curl` and `docker` on PATH: the
# pull authenticated by a throwaway docker config holding the nora session token (gone after,
# never in argv), the docker run flags from ports/env/options, output and state `id`, the
# health wait (healthy, no health check, unhealthy, timeout), the refusals (image not on nora
# by digest, no id-token permission), and post.js removing the container.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
act="${here}/../nora-service"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [[ "${*: -1}" == https://packages.maestra.io/api/oidc/session ]]; then
  o=; p=; for a in "$@"; do [ "$p" = -o ] && o=$a; p=$a; done; [ -n "$o" ] || { echo "session body not sent to a file: $*" >&2; exit 22; }
  printf '{"token":"nrs_1_stub","expires_in":3600}' > "$o"; printf 200; exit 0
fi
echo '{"value":"eyJ.stub.jwt"}'
STUB
cat > "$root/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/argv"
case "$1" in
  pull) printf '%s\n' "$DOCKER_CONFIG" > "$CASE/cfgdir"; jq -r '.auths["packages.maestra.io"].auth' \
          "$DOCKER_CONFIG/config.json" | base64 -d > "$CASE/auth"; stat -c %a "$DOCKER_CONFIG/config.json" \
          > "$CASE/mode" 2>/dev/null || stat -f %Lp "$DOCKER_CONFIG/config.json" > "$CASE/mode" ;;
  run) shift; printf '%s\n' "$@" > "$CASE/run"; echo cid123 ;;
  inspect) n=$(($(cat "$CASE/n" 2>/dev/null || echo 0) + 1)); echo "$n" > "$CASE/n"
           read -r -a s <<< "$INSPECT"; i=$((n > ${#s[@]} ? ${#s[@]} - 1 : n - 1))
           echo "${s[$i]/\// }" | sed 's/ none$/ /' ;;
  logs) echo "stub log line" ;;
esac
STUB
chmod +x "$root/bin/curl" "$root/bin/docker"
fail() { echo "FAIL: $*" >&2; exit 1; }
img='packages.maestra.io/docker-hub/library/postgres:17@sha256:3b0cda93be7c8dba2ed484d19393d93845dc3dafb88973e248ba8e6d99d784e1'
run() { # $1 = case dir, then extra env; runs main.js as the runner would
  local d="$root/$1"; shift; mkdir -p "$d"; : > "$d/argv"
  env -i PATH="$root/bin:$PATH" CASE="$d" GITHUB_OUTPUT="$d/out" GITHUB_STATE="$d/state" \
    INPUT_IMAGE="$img" INPUT_URL=https://packages.maestra.io INPUT_AUDIENCE=packages.maestra.io \
    INPUT_TIMEOUT=5 INPUT_NAME= INPUT_PORTS= INPUT_ENV= INPUT_OPTIONS= INSPECT=running/healthy \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token \
    "$@" node "$act/main.js" > "$d/log" 2>&1
}

run ok INPUT_NAME=pg INPUT_PORTS=$'5432:5432\n  127.0.0.1:6000:6000  \n' \
  INPUT_ENV=$'POSTGRES_PASSWORD=it not a secret\nPOSTGRES_DB=x\n' \
  INPUT_OPTIONS='--health-cmd "pg_isready -U postgres" --health-interval 2s' \
  INSPECT='running/starting running/starting running/healthy' || fail "run: $(cat "$root/ok/log")"
want=(-d --pull never --label maestra.nora-service=1 --name pg -p 5432:5432 -p 127.0.0.1:6000:6000
  -e 'POSTGRES_PASSWORD=it not a secret' -e POSTGRES_DB=x --health-cmd 'pg_isready -U postgres'
  --health-interval 2s "$img")
[ "$(cat "$root/ok/run")" = "$(printf '%s\n' "${want[@]}")" ] || fail "docker run flags: $(tr '\n' '|' < "$root/ok/run")"
[ "$(cat "$root/ok/auth")" = token:nrs_1_stub ] || fail "pull credential: $(cat "$root/ok/auth")"
[ "$(cat "$root/ok/mode")" = 600 ] || fail "config mode $(cat "$root/ok/mode")"
[ ! -e "$(cat "$root/ok/cfgdir")" ] || fail "the pull's docker config outlived the step"
! grep -q -e nrs_1_stub -e eyJ.stub.jwt "$root/ok/argv" || fail "a token reached docker's argv"
grep -qxF '::add-mask::nrs_1_stub' "$root/ok/log" || fail "token not masked"
[ "$(sed -n 1p "$root/ok/argv")" = "pull -q $img" ] || fail "pull: $(sed -n 1p "$root/ok/argv")"
[ "$(cat "$root/ok/out")" = id=cid123 ] && [ "$(cat "$root/ok/state")" = id=cid123 ] || fail "id output/state"
[ "$(cat "$root/ok/n")" = 3 ] || fail "waited $(cat "$root/ok/n") inspects, want 3"

run nohealth INSPECT=running/none || fail "no health check: $(cat "$root/nohealth/log")"
[ "$(cat "$root/nohealth/run")" = "$(printf '%s\n' -d --pull never --label maestra.nora-service=1 "$img")" ] \
  || fail "bare docker run flags: $(tr '\n' '|' < "$root/nohealth/run")"

! run sick INSPECT='running/starting running/unhealthy' || fail "an unhealthy container passed"
grep -q 'stub log line' "$root/sick/log" || fail "no container logs on failure"
grep -q '::error::nora-service: .* not ready after 5s: running/unhealthy' "$root/sick/log" || fail "unhealthy message"
[ "$(cat "$root/sick/state")" = id=cid123 ] || fail "a failed start left no state for post.js"

! run exited INSPECT=exited/none || fail "an exited container passed"
! run slow INPUT_TIMEOUT=2 INSPECT=running/starting || fail "a never-healthy container passed"
[ "$(cat "$root/slow/n")" = 3 ] || fail "timeout 2 s took $(cat "$root/slow/n") inspects, want 3"

for bad in docker.io/library/postgres:17@sha256:3b0c packages.maestra.io/docker-hub/library/postgres:17 \
  packages.maestra.io.evil/x:1@sha256:3b0c ''; do
  ! run badimg INPUT_IMAGE="$bad" || fail "image '$bad' accepted"
  grep -q '::error::nora-service: image must be packages.maestra.io/' "$root/badimg/log" || fail "refusal for '$bad'"
  [ ! -s "$root/badimg/argv" ] || fail "docker ran for '$bad'"
done
! run noid ACTIONS_ID_TOKEN_REQUEST_URL= || fail "ran without ACTIONS_ID_TOKEN_REQUEST_URL"
grep -q 'id-token: write' "$root/noid/log" || fail "refusal message without id-token"

d="$root/post"; mkdir -p "$d"
env -i PATH="$root/bin:$PATH" CASE="$d" STATE_id=cid123 node "$act/post.js" || fail "post.js"
[ "$(cat "$d/argv")" = "rm -f -v cid123" ] || fail "post.js ran: $(cat "$d/argv")"
: > "$d/argv"; env -i PATH="$root/bin:$PATH" CASE="$d" node "$act/post.js" || fail "post.js without state"
[ ! -s "$d/argv" ] || fail "post.js without state ran docker: $(cat "$d/argv")"
echo "nora-service: OK"
