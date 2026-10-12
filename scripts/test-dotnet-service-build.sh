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
  KARGO_PROJECT="" KARGO_WAREHOUSE="" REPO_NAME=my-repo \
    bash -c "set -eo pipefail; $prog"$'\n''echo "$matrix|$images|$bakes|$multi|$base_name|$base_dockerfile|$base_target"'
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
fails() { if run "$1" "$2" "${4:-}" >/dev/null 2>&1; then echo "FAIL $3: accepted"; exit 1; fi; }

# Existing callers: unchanged images list, one bake named after the repo.
IFS='|' read -r m i b multi _ < <(run "a_services=services,a_lrt=lrt" "")
eq "$m" '[{"image":"a_services","dockerfile":"Dockerfile","target":"services","context":"."},{"image":"a_lrt","dockerfile":"Dockerfile","target":"lrt","context":"."}]' "pairs"
eq "$i" "a_services,a_lrt" "images"
eq "$b" '[{"service":"my-repo","bake-path":"./kustomization","images":"a_services,a_lrt","kargo-project":"kargo-my-repo","kargo-warehouse":"my-repo"}]' "single bake"
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
eq "$b" '[{"service":"mindbox-mta","bake-path":"./kustomization/mta","images":"m_services","kargo-project":"kargo-mindbox-mta","kargo-warehouse":"mindbox-mta"},{"service":"campaigns","bake-path":"./kustomization/campaigns","images":"c_services,c_lrt","kargo-project":"kargo-campaigns","kargo-warehouse":"campaigns"},{"service":"all","bake-path":"./k","images":"m_services,c_services,c_lrt","kargo-project":"kargo-all","kargo-warehouse":"all"}]' "bakes"
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

# images-in-one-job: one leg carrying every target; the matrix leg list otherwise.
im=$(sed -n '/# >>> images-matrix/,/# <<< images-matrix/p' "$wf" | sed 's/^          //')
[ -n "$im" ] || { echo "images-matrix block not found in $wf"; exit 1; }
m2='[{"image":"a","dockerfile":"Dockerfile","target":"x","context":"."},{"image":"b","dockerfile":"Dockerfile","target":"y","context":"sub"}]'
im_run() { matrix="$1" ONE_JOB="$2" bash -c "set -eo pipefail; $im"$'\n''echo "$images_matrix"'; }
eq "$(im_run "$m2" false)" "$m2" "one-job off: matrix legs"
eq "$(im_run "$m2" true)" "[{\"image\":\"all\",\"target\":\"bake\",\"dockerfile\":\"Dockerfile\",\"context\":\".\",\"targets\":$m2}]" "one-job: one leg"
if im_run '[{"image":"a","dockerfile":"Dockerfile","target":"x","context":"."},{"image":"b","dockerfile":"Other","target":"y","context":"."}]' true >/dev/null 2>&1; then
  echo "FAIL one-job with two Dockerfiles: accepted"; exit 1
fi

# bake definition: per-target tags/args/labels/secrets/cache scope, base context.
bk=$(sed -n '/# >>> bake-definition/,/# <<< bake-definition/p' "$wf" | sed 's/^          //')
[ -n "$bk" ] || { echo "bake-definition block not found in $wf"; exit 1; }
bk_run() { # <cache-from> <cache-to> <base-context>
  : > "$work/gho"
  TARGETS="$m2" RELEASE=1.1.7 SHA=abc SOURCE=https://github.com/o/r CACHE_FROM="$1" CACHE_TO="$2" BASE_CONTEXT="$3" \
  RUNNER_TEMP="$work" GITHUB_WORKSPACE=/ws GITHUB_OUTPUT="$work/gho" bash -c "set -eo pipefail; $bk"
  cat "$work/images.bake.json"
}
d=$(bk_run $'type=gha,scope=a\ntype=gha,scope=b\ntype=gha,scope=tests' "type=gha,mode=max,compression=zstd,compression-level=3,scope=a" "")
eq "$(jq -c '.group.default.targets' <<<"$d")" '["a","b"]' "bake group"
eq "$(jq -c '.target.b | {context, dockerfile, target, tags, args, output}' <<<"$d")" \
   '{"context":"sub","dockerfile":"/ws/Dockerfile","target":"y","tags":["local/b:1.1.7"],"args":{"revision":"1.1.7 (abc)","release":"1.1.7 (abc)"},"output":["type=docker"]}' "bake target"
eq "$(jq -c '.target.b.labels["org.opencontainers.image.source"]' <<<"$d")" '"https://github.com/o/r"' "bake label"
eq "$(jq -c '.target.a.secret' <<<"$d")" "[\"id=PRIVATE_PACKAGES_TOKEN,src=$work/packages-token/PRIVATE_PACKAGES_TOKEN\",\"id=NUGET_CREDENTIALS,src=$work/packages-token/NUGET_CREDENTIALS\"]" "bake secrets"
eq "$(jq -c '.target.b["cache-from"]' <<<"$d")" '["type=gha,scope=a","type=gha,scope=b","type=gha,scope=tests"]' "bake cache-from"
eq "$(jq -c '[.target.a["cache-to"], .target.b["cache-to"]]' <<<"$d")" '[["type=gha,mode=max,compression=zstd,compression-level=3,scope=a"],["type=gha,mode=max,compression=zstd,compression-level=3,scope=b"]]' "bake cache-to per target"
eq "$(jq -c '.target.a.contexts // null' <<<"$d")" 'null' "bake no base context"
grep -q "^file=$work/images.bake.json$" "$work/gho" || { echo "FAIL bake: no file output"; exit 1; }
d=$(bk_run "" "" "local/base:latest=oci-layout:///t/base-image")
eq "$(jq -c '[.target.a["cache-from"], .target.a["cache-to"], .target.a.contexts]' <<<"$d")" '[[],[],{"local/base:latest":"oci-layout:///t/base-image"}]' "bake without cache, base context"
echo "dotnet-service-build images-in-one-job: OK"
