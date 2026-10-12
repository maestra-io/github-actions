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
