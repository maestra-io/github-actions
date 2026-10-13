#!/usr/bin/env bash
# Prints the kustomize entry points under <dir>: every directory below an overlays/
# directory that holds a kustomization file (the paths Flux builds from
# <service>-manifests, incl. nested ones such as overlays/omega/r2-bucket), sorted.
set -euo pipefail
dir=${1:?usage: kustomize-entry-points.sh <dir>}
find "$dir" -type f \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) \
	-path '*/overlays/*' -exec dirname {} \; | sort -u
