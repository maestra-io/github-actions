#!/usr/bin/env bash
# Tests for the pr-changes block of dotnet-service-build.yml / service-build.yml / mcf-build.yml:
# code=false only when every file the PR changes is under a kustomization tree (bake-path or a
# `bakes` path); anything else, an empty diff or a bake from the repo root means code=true.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

for wf in dotnet-service-build service-build mcf-build; do
	sed -n '/# >>> pr-changes/,/# <<< pr-changes/p' "$root/.github/workflows/$wf.yml" | sed 's/^          //' > "$work/$wf.sh"
	[ -s "$work/$wf.sh" ] || { echo "FAIL $wf: no pr-changes block"; fail=1; }
done
cmp -s "$work/dotnet-service-build.sh" "$work/service-build.sh" && cmp -s "$work/service-build.sh" "$work/mcf-build.sh" \
	&& echo "ok   the block is identical in all three workflows" || { echo "FAIL the pr-changes blocks differ"; fail=1; }

case_() { # name expected bake-path bakes files...
	local name=$1 want=$2 bp=$3 bakes=$4; shift 4
	rm -rf "$work/repo"; mkdir "$work/repo"; cd "$work/repo"
	git init -q . && git config user.email t@t && git config user.name t
	echo base > README.md; git add . && git commit -qm base
	for f in "$@"; do mkdir -p "$(dirname "$f")"; echo change >> "$f"; done
	git add -A && git commit -qm change --allow-empty
	GITHUB_OUTPUT="$work/out" BAKE_PATH="$bp" BAKES="$bakes" bash "$work/dotnet-service-build.sh" >/dev/null
	local got; got=$(sed -n 's/^code=//p' "$work/out")
	if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: code=$got, want $want"; fail=1; fi
	rm -f "$work/out"; cd "$work"
}

case_ "only kustomization/ -> skip"            false ./kustomization "" kustomization/base/a.yaml kustomization/overlays/omega/b.yaml
case_ "kustomization/ + src -> run"            true  ./kustomization "" kustomization/base/a.yaml src/App.cs
case_ "only src -> run"                         true  ./kustomization "" src/App.cs
case_ "bake-path with trailing slash"           false kustomization/  "" kustomization/a.yaml
case_ "custom bake-path .flux"                  false ./.flux         "" .flux/clusters/a.yaml
case_ "similar prefix is not the tree"          true  ./kustomization "" kustomization-old/a.yaml
case_ "bakes paths count as trees"              false ./kustomization "$(printf 'svc-a ./deploy/a\nsvc-b ./deploy/b img1,img2')" deploy/a/x.yaml deploy/b/y.yaml
case_ "file outside every bakes path -> run"    true  ./kustomization "$(printf 'svc-a ./deploy/a')" deploy/a/x.yaml deploy/c/z.yaml
case_ "bake from repo root never skips"         true  .               "" kustomization/a.yaml
case_ "empty diff -> run"                       true  ./kustomization ""

exit $fail
