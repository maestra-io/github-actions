#!/usr/bin/env bash
#
# Self-check for service-build.yml `version`: image-targets -> images matrix
# (Dockerfile and build context per image, empty target, bare image). Runs the
# inline block of the reusable workflow itself (it cannot read repo files).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/service-build.yml"
prog=$(sed -n '/# >>> image-targets/,/# <<< image-targets/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "image-targets block not found in $wf"; exit 1; }

run() { IMAGE_TARGETS="$1" DOCKERFILE="${2:-Dockerfile}" BAKE="${3:-false}" bash -c "set -eo pipefail; $prog"$'\n''echo "$matrix"'; }
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }
fails() { if run "$1" >/dev/null 2>&1; then echo "FAIL $2: accepted"; exit 1; fi; }

# Existing callers: same images and targets, default Dockerfile, repo-root context.
eq "$(run "a_services=services,a_worker=worker")" '[{"image":"a_services","dockerfile":"Dockerfile","target":"services","context":"."},{"image":"a_worker","dockerfile":"Dockerfile","target":"worker","context":"."}]' "pairs"
eq "$(run $'web=\nbare')" '[{"image":"web","dockerfile":"Dockerfile","target":"","context":"."},{"image":"bare","dockerfile":"Dockerfile","target":"","context":"."}]' "last stage"
eq "$(run "x=t" docker/App.Dockerfile)" '[{"image":"x","dockerfile":"docker/App.Dockerfile","target":"t","context":"."}]' "dockerfile input"

# Other Dockerfiles and build contexts.
eq "$(run $'api=api\ntank=Dockerfile.quiz-tank:app\nstatic=deploy/static.Dockerfile::dist\nlast=Dockerfile.x:')" '[{"image":"api","dockerfile":"Dockerfile","target":"api","context":"."},{"image":"tank","dockerfile":"Dockerfile.quiz-tank","target":"app","context":"."},{"image":"static","dockerfile":"deploy/static.Dockerfile","target":"","context":"dist"},{"image":"last","dockerfile":"Dockerfile.x","target":"","context":"."}]' "dockerfiles"

fails "" "empty"
fails $' ,\n' "blank"

# Bake-only repo (GitLab images: ""): empty image-targets with bake: true, empty matrix.
eq "$(run "" Dockerfile true)" '[]' "bake-only"
eq "$(run $' \n' Dockerfile true)" '[]' "bake-only blank"
eq "$(run "x=t" Dockerfile true)" '[{"image":"x","dockerfile":"Dockerfile","target":"t","context":"."}]' "bake with images"
fails "=t" "no image"
fails "x=:t" "empty dockerfile"
fails "x=a:b:c:d" "four fields"
echo "service-build image-targets: ok"
