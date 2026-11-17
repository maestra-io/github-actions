#!/usr/bin/env bash
#
# Self-check for dotnet-service-build.yml `version`: image-targets -> images
# matrix (Dockerfile per image, empty target) and bakes -> bake matrix. Runs the
# inline block of the reusable workflow itself (it cannot read repo files).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
prog=$(sed -n '/# >>> targets-and-bakes/,/# <<< targets-and-bakes/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "targets-and-bakes block not found in $wf"; exit 1; }

# run <IMAGE_TARGETS> <BAKES> [BASE_IMAGE] -> prints "matrix|images|bakes|multi|base_name|base_dockerfile|base_target", or exits 1
run() {
  IMAGE_TARGETS="$1" BAKES="$2" BASE_IMAGE="${3:-}" DOCKERFILE=Dockerfile SERVICE="" BAKE_PATH=./kustomization \
  REPO_NAME=my-repo \
    bash -c "set -eo pipefail; $prog"$'\n''echo "$matrix|$images|$bakes|$multi|$base_name|$base_dockerfile|$base_target"'
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
fails() { if run "$1" "$2" "${4:-}" >/dev/null 2>&1; then echo "FAIL $3: accepted"; exit 1; fi; }

# Existing callers: unchanged images list, one bake named after the repo.
IFS='|' read -r m i b multi _ < <(run "a_services=services,a_lrt=lrt" "")
eq "$m" '[{"image":"a_services","dockerfile":"Dockerfile","target":"services","context":"."},{"image":"a_lrt","dockerfile":"Dockerfile","target":"lrt","context":"."}]' "pairs"
eq "$i" "a_services,a_lrt" "images"
eq "$b" '[{"service":"my-repo","bake-path":"./kustomization","images":"a_services,a_lrt"}]' "single bake"
eq "$multi" false "single multi"

# Other Dockerfiles and last-stage builds.
IFS='|' read -r m _ _ _ _ < <(run $'web=Dockerfile-base:\nworker=Dockerfile-celery:app\nmig=' "")
eq "$m" '[{"image":"web","dockerfile":"Dockerfile-base","target":"","context":"."},{"image":"worker","dockerfile":"Dockerfile-celery","target":"app","context":"."},{"image":"mig","dockerfile":"Dockerfile","target":"","context":"."}]' "dockerfiles"

# Build context per image (GitLab `docker build --file ./email/Dockerfile.Postfix ./email`).
IFS='|' read -r m i _ _ _ < <(run $'postfix=email/Dockerfile.Postfix::email\ninit=init/Dockerfile.Init:app:init/\nsmpp=sms/SmppServer.Dockerfile:\nx=Dockerfile:t:' "")
eq "$m" '[{"image":"postfix","dockerfile":"email/Dockerfile.Postfix","target":"","context":"email"},{"image":"init","dockerfile":"init/Dockerfile.Init","target":"app","context":"init/"},{"image":"smpp","dockerfile":"sms/SmppServer.Dockerfile","target":"","context":"."},{"image":"x","dockerfile":"Dockerfile","target":"t","context":"."}]' "contexts"
eq "$i" "postfix,init,smpp,x" "context images"

# Several warehouses; images default to all; comments and blank lines ignored.
IFS='|' read -r _ _ b multi _ < <(run "m_services=services,c_services=c-services,c_lrt=c-lrt" $'# mta\nmindbox-mta ./kustomization/mta m_services\n\ncampaigns ./kustomization/campaigns c_services,c_lrt\nall ./k')
eq "$b" '[{"service":"mindbox-mta","bake-path":"./kustomization/mta","images":"m_services"},{"service":"campaigns","bake-path":"./kustomization/campaigns","images":"c_services,c_lrt"},{"service":"all","bake-path":"./k","images":"m_services,c_services,c_lrt"}]' "bakes"
eq "$multi" true "multi"

# base-image: none by default; name may carry a tag; optional target.
IFS='|' read -r _ _ _ _ bn bd bt < <(run "a=t" "")
eq "$bn|$bd|$bt" "||" "no base"
IFS='|' read -r _ _ _ _ bn bd bt < <(run "a=t" "" "local/personalization-base:latest=Dockerfile-base")
eq "$bn|$bd|$bt" "local/personalization-base:latest|Dockerfile-base|" "base last stage"
IFS='|' read -r _ _ _ _ bn bd bt < <(run "a=t" "" " base=docker/Dockerfile.base:runtime ")
eq "$bn|$bd|$bt" "base|docker/Dockerfile.base|runtime" "base target"

fails "a_services" "" "pair without ="
fails "=services" "" "empty image"
fails "a=:t" "" "empty dockerfile"
fails "a=D:t:c:x" "" "four spec fields"
fails "a=t" "svc" "bake without path"
fails "a=t" "svc ./k a extra" "bake with 4 fields"
fails "a=t" "svc ./k b" "bake image not built"
fails "a=t" $'svc ./k\nsvc ./k2' "service twice"
fails "a=t" "" "base without =" "Dockerfile-base"
fails "a=t" "" "base empty name" "=Dockerfile-base"
fails "a=t" "" "base empty dockerfile" "base=:t"
fails "a=t" "" "base three fields" "base=D:t:c"
echo "dotnet-service-build targets/bakes/base-image: OK"

# ── sdk-version: a global.json setup-dotnet rejects gets <major>.<minor>.x ──────
sdk=$(sed -n '/# >>> sdk-version/,/# <<< sdk-version/p' "$wf" | sed 's/^          //')
[ -n "$sdk" ] || { echo "sdk-version block not found in $wf"; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# sdk_for <DOTNET_VERSION> <global.json content or "-" for none> -> "version|file"
sdk_for() {
  rm -f "$work/global.json"; [ "$2" = "-" ] || printf '%s' "$2" > "$work/global.json"
  : > "$work/out"
  (cd "$work" && DOTNET_VERSION="$1" GITHUB_OUTPUT="$work/out" bash -c "set -eo pipefail; $sdk" >/dev/null)
  echo "$(sed -n 's/^version=//p' "$work/out")|$(sed -n 's/^file=//p' "$work/out")"
}
eq "$(sdk_for "" '{"sdk":{"version":"10.0.0","rollForward":"latestMajor"}}')" "10.0.x|" "10.0.0 + rollForward"
eq "$(sdk_for "" '{"sdk":{"version":"8.0.0","rollForward":"latestFeature"}}')" "8.0.x|" "8.0.0 + rollForward"
eq "$(sdk_for "" '{"sdk":{"version":"9.0.5","rollForward":"latestPatch"}}')" "9.0.x|" "runtime-like patch + rollForward"
eq "$(sdk_for "" '{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}')" "|global.json" "full SDK version: setup-dotnet reads it"
eq "$(sdk_for "" '{"sdk":{"version":"10.0.0"}}')" "|global.json" "no rollForward: as is"
eq "$(sdk_for "" '{"sdk":{"version":"10.0.100-rc.1.25451.107","rollForward":"latestMajor"}}')" "|global.json" "prerelease: as is"
eq "$(sdk_for "" $'{ // comment\n "sdk": {"version":"10.0.0","rollForward":"latestMajor"} }')" "|global.json" "unreadable global.json: as is"
eq "$(sdk_for "" -)" "|global.json" "no global.json: as before"
eq "$(sdk_for "8.0.x" '{"sdk":{"version":"10.0.0","rollForward":"latestMajor"}}')" "8.0.x|" "explicit dotnet-version wins"
echo "dotnet-service-build sdk-version: OK"

# ── aws-credentials: wait out a fresh instance's NoCredentials ─────────────────
aws=$(awk 'index($0,"# >>> aws-credentials"){n++} n==1{print} n==1&&index($0,"# <<< aws-credentials"){exit}' "$wf" | sed 's/^          //')
[ -n "$aws" ] || { echo "aws-credentials block not found in $wf"; exit 1; }
[ "$(sed -n '/# >>> aws-credentials/,/# <<< aws-credentials/p' "$wf" | sed 's/^          //')" = "$(printf '%s\n%s' "$aws" "$aws")" ] \
  || { echo "FAIL aws-credentials: the test and images copies differ"; exit 1; }
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'A'
#!/usr/bin/env bash
n=$(( $(cat "$AWS_N") + 1 )); echo "$n" > "$AWS_N"
[ "$n" -gt "$AWS_FAILS" ] && { echo 515260921971; exit 0; }
echo "Unable to locate credentials. You can configure credentials by running \"aws configure\"." >&2; exit 253
A
chmod +x "$work/bin/aws"
# aws_run <fails before success> -> "<aws calls> <sleeps> <exit>"
aws_run() {
  echo 0 > "$work/n"; : > "$work/sleeps"; local rc=0
  PATH="$work/bin:$PATH" AWS_N="$work/n" AWS_FAILS="$1" ECR_REGISTRY=515260921971.dkr.ecr.us-west-2.amazonaws.com \
    bash -c "set -eo pipefail; sleep() { echo \"\$1\" >> '$work/sleeps'; }; $aws" >"$work/out" 2>&1 || rc=$?
  echo "$(cat "$work/n") $(wc -l < "$work/sleeps" | tr -d ' ') $rc"
}
eq "$(aws_run 0)" "1 0 0" "credentials at once"
eq "$(aws_run 3)" "4 3 0" "NoCredentials 3x, then credentials"
eq "$(aws_run 9)" "5 4 0" "never: 5 tries, then the AWS steps report it"
grep -q '::warning::no AWS credentials' "$work/out" || { cat "$work/out"; echo "FAIL aws-credentials: no warning"; exit 1; }
echo "dotnet-service-build aws-credentials: OK"

# ── nora-cred-helper: a fresh OIDC token per docker pull, exchanged for a nora session ──
cred=$(awk 'index($0,"# >>> nora-cred-helper"){n++} n==1{print} n==1&&index($0,"# <<< nora-cred-helper"){exit}' "$wf" | sed 's/^          //')
[ -n "$cred" ] || { echo "nora-cred-helper block not found in $wf"; exit 1; }
# Every job that pulls through nora carries the same copy (reusable workflows cannot share a file).
for f in dotnet-service-build:2 service-build:2 mcf-build:5 nuget-package-publish:1 python-package-publish:1 mirror-test-images:1; do
  w="$here/../.github/workflows/${f%%:*}.yml"
  got=$(sed -n '/# >>> nora-cred-helper/,/# <<< nora-cred-helper/p' "$w" | sed 's/^          //')
  want=$(for _ in $(seq "${f##*:}"); do printf '%s\n' "$cred"; done)
  [ "$got" = "${want%$'\n'}" ] || { echo "FAIL nora-cred-helper: ${f%%:*}.yml copies differ or are missing"; exit 1; }
done
# the setup-buildx composite (its run: block sits two columns left of a workflow's)
got=$(sed -n '/# >>> nora-cred-helper/,/# <<< nora-cred-helper/p' "$here/../setup-buildx/action.yml" | sed 's/^        //')
[ "$got" = "$cred" ] || { echo "FAIL nora-cred-helper: setup-buildx/action.yml copy differs or is missing"; exit 1; }
n="$work/nora"; mkdir -p "$n/bin" "$n/home/.docker" "$n/tmp"
# NORA_SESSION=<http code> the exchange answers (200 = an nrs_ token)
cat > "$n/bin/curl" <<'C'
#!/usr/bin/env bash
if [[ "$*" == *"https://packages.maestra.io/api/oidc/session"* ]]; then
  [[ "$*" == *"Bearer tok-"* ]] || exit 22
  out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
  code=${NORA_SESSION:-200}; { [ "$code" = 200 ] && echo '{"token":"nrs_'"$RANDOM"'"}' || echo '{}'; } > "$out"
  printf %s "$code"; exit 0
fi
[[ "$*" == *"audience=packages.maestra.io"* ]] && echo '{"value":"tok-'"$RANDOM"'"}'
C
chmod 755 "$n/bin/curl"
echo '{"auths":{"515260921971.dkr.ecr.us-west-2.amazonaws.com":{"auth":"x"}}}' > "$n/home/.docker/config.json"
install() { # <dir> <audience>: run the block with a job's OIDC env, as the workflow step does
  mkdir -p "$1/tmp"; : > "$1/path"
  HOME="$n/home" RUNNER_TEMP="$1/tmp" GITHUB_PATH="$1/path" AUDIENCE="$2" PACKAGES_URL="${3:-https://packages.maestra.io}" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=x ACTIONS_ID_TOKEN_REQUEST_URL="https://t/?v=1" bash -c "set -eo pipefail; $cred"
}
# get <dir>: the helper as tox runs it, with an environment that has PATH only
get() { printf %s packages.maestra.io | env -i PATH="$n/bin:$PATH" NORA_SESSION="${NORA_SESSION:-200}" "$(cat "$1/path")/docker-credential-nora" get; }
install "$n/ok" packages.maestra.io
eq "$(jq -c '{a: (.auths|keys), h: .credHelpers}' "$n/home/.docker/config.json")" \
  '{"a":["515260921971.dkr.ecr.us-west-2.amazonaws.com"],"h":{"packages.maestra.io":"nora"}}' "nora config keeps auths"
# the 1 h session token, not the JWT: Testcontainers keeps the first credential for its whole run
eq "$(jq -r '.ServerURL + " " + .Username + " " + (.Secret|test("^nrs_")|tostring)' <<<"$(get "$n/ok")")" \
  "packages.maestra.io token true" "nora helper get, scrubbed env"
eq "$(NORA_SESSION=404 get "$n/ok" | jq -r '.Secret|test("^tok-")')" true "no exchange at nora: the JWT"
if NORA_SESSION=500 get "$n/ok" >/dev/null 2>&1; then echo "FAIL nora helper: a failed exchange accepted"; exit 1; fi
# python-package-publish hands its index URL: the exchange still goes to nora's origin
install "$n/py" packages.maestra.io https://packages.maestra.io/simple/
eq "$(get "$n/py" | jq -r '.Secret|test("^nrs_")')" true "index URL with a path: session at the origin"
eq "$(stat -c %a "$n/ok/tmp/nora-bin/oidc.env" 2>/dev/null || stat -f %Lp "$n/ok/tmp/nora-bin/oidc.env")" 600 "oidc.env mode"
install "$n/bad" wrong
if get "$n/bad" >/dev/null 2>&1; then echo "FAIL nora helper: empty token accepted"; exit 1; fi
echo "dotnet-service-build nora-cred-helper: OK"

# ── setup-buildx: moby/buildkit through nora, pinned by digest (issues-maestra#1649) ──
# Without driver-opts the docker-container driver pulls moby/buildkit:buildx-stable-1 from
# Docker Hub, past nora's quarantine. The daemon pulls it with ~/.docker/config.json, so the
# job's nora-cred-helper must run first. Bump: every copy, a version nora has served >3 days.
bk=$(awk '
  FNR==1 { job=""; cred=0 }
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job=$1; cred=0 }
  index($0, "# <<< nora-cred-helper") { cred=1 }
  /uses: docker\/setup-buildx-action@/ { pend=FILENAME ":" FNR " " job; c=cred; next }
  pend != "" && /^[[:space:]]*#/ { next }
  pend != "" && blk { sub(/^[[:space:]]*/, ""); print pend " cred=" c " " $0; pend=""; blk=0; next }
  pend != "" && /driver-opts:/ { sub(/.*driver-opts:[[:space:]]*/, ""); if ($0 == "|") { blk=1; next } print pend " cred=" c " " $0; pend=""; next }
  pend != "" && !/^[[:space:]]+(with:|[a-z-]+:)/ { print pend " cred=" c " none"; pend="" }
' "$here"/../.github/workflows/*.yml "$here/../setup-buildx/action.yml")
[ -n "$bk" ] || { echo "FAIL setup-buildx: no use found"; exit 1; }
img='image=packages\.maestra\.io/docker-hub/moby/buildkit:v[0-9.]+@sha256:[0-9a-f]{64}$'
bad=$(grep -vE " cred=1 $img" <<<"$bk" || true)
[ -z "$bad" ] || { printf 'FAIL setup-buildx without the nora BuildKit image or nora login before it:\n%s\n' "$bad"; exit 1; }
[ "$(awk '{print $NF}' <<<"$bk" | sort -u | wc -l | tr -d ' ')" = 1 ] || { printf 'FAIL setup-buildx: BuildKit copies differ:\n%s\n' "$bk"; exit 1; }
echo "setup-buildx BuildKit via nora: OK ($(wc -l <<<"$bk" | tr -d ' ') uses)"
