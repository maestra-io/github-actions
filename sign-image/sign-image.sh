#!/usr/bin/env bash
# sign-image.sh: cosign keyless sign + CycloneDX attest each REF (<image>@sha256:<64 hex>).
# Env: SIGN_REFS (newline/space separated), SBOM (true|false), SYFT_IMAGE. Best-effort per ref:
# prints `status=<sbom+signature|signature|none>` (the weakest over all refs) to $GITHUB_OUTPUT
# and a ::warning:: for every ref that got less than asked; exits 0 unless REFS is malformed.
set -uo pipefail

retry() { # <what> <cmd...>: 3 attempts, 5 min each
  local what=$1 i; shift
  for i in 1 2 3; do
    timeout 300 "$@" && return 0
    echo "$what attempt $i failed"; [ "$i" -lt 3 ] && sleep $((i * 15))
  done
  return 1
}

sbom_of() { # <ref> <out file>: syft from its OCI image, ECR auth from the job's AWS credentials
  local ref=$1 out=$2 registry region pass
  registry=${ref%%/*}
  region=$(cut -d. -f4 <<<"$registry")
  pass=$(aws ecr get-login-password --region "$region") || return 1
  SYFT_REGISTRY_AUTH_PASSWORD=$pass timeout 900 docker run --rm \
    -e SYFT_REGISTRY_AUTH_AUTHORITY="$registry" -e SYFT_REGISTRY_AUTH_USERNAME=AWS \
    -e SYFT_REGISTRY_AUTH_PASSWORD \
    "$SYFT_IMAGE" "registry:$ref" -q -o cyclonedx-json >"$out" || return 1
  test -s "$out" || return 1
  echo "$ref: SBOM $(jq '.components | length' "$out") components, $(wc -c <"$out") bytes"
}

read -r -d '' -a refs <<<"$SIGN_REFS"
[ "${#refs[@]}" -gt 0 ] || { echo "::error::sign-image: no image given (image+digest or refs)"; exit 1; }
for ref in "${refs[@]}"; do
  [[ "$ref" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || { echo "::error::sign-image: '$ref' is not <image>@sha256:<64 hex>"; exit 1; }
done

want=signature; [ "$SBOM" = true ] && want=sbom+signature
rank() { case $1 in sbom+signature) echo 2 ;; signature) echo 1 ;; *) echo 0 ;; esac; }
overall=$want
dir=$(mktemp -d)
for ref in "${refs[@]}"; do
  got=none
  if retry "cosign sign $ref" cosign sign --yes "$ref"; then
    got=signature
    if [ "$SBOM" = true ]; then
      f="$dir/sbom-$(cut -d: -f2 <<<"${ref##*@}" | cut -c1-12).cdx.json"
      if sbom_of "$ref" "$f" && retry "cosign attest $ref" cosign attest --yes --type cyclonedx --predicate "$f" "$ref"; then
        got=sbom+signature
      fi
    fi
  fi
  echo "$ref: $got"
  [ "$got" = "$want" ] || echo "::warning::sign-image: $ref got '$got', wanted '$want'; re-run the job to retry"
  [ "$(rank "$got")" -lt "$(rank "$overall")" ] && overall=$got
done
echo "status=$overall" >> "${GITHUB_OUTPUT:-/dev/null}"
