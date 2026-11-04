#!/usr/bin/env bash
# sign-image.sh: cosign keyless sign + CycloneDX attest each REF (<image>@sha256:<64 hex>).
# Env: SIGN_REFS (newline/space separated), SBOM (true|false), SYFT_IMAGE. Best-effort per ref:
# prints `status=<sbom+signature|signature|none>` (the weakest over all refs) to $GITHUB_OUTPUT
# and a ::warning:: for every ref that got less than asked; exits 0 unless REFS is malformed.
# The SBOMs are made in the background while cosign installs and signs: the scan (image
# download + syft) is most of the time and does not depend on the signature.
set -uo pipefail

# cosign 3.1.4 (3.0.6 annotates the attestation referrer https://sigstore.dev/cosign/sign/v1,
# not the https://cyclonedx.org/bom SOC registry:no-sbom keys on, issues-maestra#1648).
# Bump: both sha256 from the release's cosign_checksums.txt, after
# `cosign verify-blob --bundle cosign-linux-<arch>.sigstore.json` of each binary.
COSIGN_VERSION=v3.1.4
declare -A COSIGN_SHA256=(
  [amd64]=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa
  [arm64]=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2
)

retry() { # <what> <cmd...>: 3 attempts, 5 min each
  local what=$1 i; shift
  for i in 1 2 3; do
    timeout 300 "$@" && return 0
    echo "$what attempt $i failed"; [ "$i" -lt 3 ] && sleep $((i * 15))
  done
  return 1
}

install_cosign() { # pinned binary from the GitHub release, sha256-checked; one retry after a pause.
  # Left on the job's PATH like cosign-installer did (callers verify with it afterwards).
  local arch bindir="${RUNNER_TEMP:-$dir}/sign-image-bin" i
  local bin="$bindir/cosign"
  case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "no cosign pin for $(uname -m)"; return 1 ;; esac
  mkdir -p "$bindir"
  for i in 1 2; do
    if curl -fsSL --retry 3 -o "$bin" "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-$arch" &&
      sha256sum -c --status <<<"${COSIGN_SHA256[$arch]}  $bin"; then
      chmod +x "$bin"; PATH="$bindir:$PATH"
      [ -n "${GITHUB_PATH:-}" ] && echo "$bindir" >>"$GITHUB_PATH"
      return 0
    fi
    echo "cosign $COSIGN_VERSION download attempt $i failed"; [ "$i" -lt 2 ] && sleep 20
  done
  return 1
}

syft_run() { # <docker run args...> -- <syft args...>: syft from its OCI image, CycloneDX JSON on stdout
  local args=()
  while [ "$1" != -- ]; do args+=("$1"); shift; done; shift
  timeout 900 docker run --rm "${args[@]}" "$SYFT_IMAGE" "$@" -q -o cyclonedx-json
}

sbom_of() { # <ref> <out file>: ECR auth from the job's AWS credentials
  local ref=$1 out=$2 registry region pass oci
  registry=${ref%%/*}
  region=$(cut -d. -f4 <<<"$registry")
  pass=$(aws ecr get-login-password --region "$region") || return 1
  # skopeo downloads the layers in parallel into an OCI layout (2-3x faster than syft's own
  # registry pull, eu-central-1 runner <- us-west-2 ECR); syft scans the layout. Same
  # components as `registry:` (byte-identical .components); --source-* keep the image ref
  # and the pushed digest in metadata.component. Any failure: syft pulls it itself.
  oci="$dir/oci-${out##*/}"
  if command -v skopeo >/dev/null &&
    (umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$registry" "$(printf 'AWS:%s' "$pass" | base64 -w0)" >"$dir/auth.json") &&
    timeout 900 skopeo copy -q --authfile "$dir/auth.json" "docker://$ref" "oci:$oci" &&
    syft_run -v "$oci:/oci:ro" -- oci-dir:/oci --source-name "${ref%@*}" --source-version "${ref#*@}" >"$out"; then
    :
  else
    echo "$ref: skopeo path failed or unavailable, syft pulls from the registry"
    SYFT_REGISTRY_AUTH_PASSWORD=$pass syft_run -e SYFT_REGISTRY_AUTH_AUTHORITY="$registry" -e SYFT_REGISTRY_AUTH_USERNAME=AWS \
      -e SYFT_REGISTRY_AUTH_PASSWORD -- "registry:$ref" >"$out" || { rm -rf "$oci"; return 1; }
  fi
  rm -rf "$oci" "$dir/auth.json"
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
dir=$(mktemp -d)

sbom_pid=
if [ "$SBOM" = true ]; then
  ( for i in "${!refs[@]}"; do
      sbom_of "${refs[$i]}" "$dir/sbom-$i.cdx.json" >"$dir/sbom-$i.log" 2>&1; echo $? >"$dir/sbom-$i.rc"
    done ) &
  sbom_pid=$!
fi

got=()
if install_cosign; then
  for i in "${!refs[@]}"; do
    got[i]=none
    retry "cosign sign ${refs[$i]}" cosign sign --yes "${refs[$i]}" && got[i]=signature
  done
else
  echo "::warning::sign-image: cosign could not be installed, images left unsigned"
  [ -n "$sbom_pid" ] && kill "$sbom_pid" 2>/dev/null
  for i in "${!refs[@]}"; do got[i]=none; done
fi
[ -n "$sbom_pid" ] && wait "$sbom_pid"

overall=$want
for i in "${!refs[@]}"; do
  ref=${refs[$i]} f="$dir/sbom-$i.cdx.json"
  [ -f "$dir/sbom-$i.log" ] && cat "$dir/sbom-$i.log"
  if [ "${got[$i]}" = signature ] && [ "$SBOM" = true ] && [ "$(cat "$dir/sbom-$i.rc" 2>/dev/null)" = 0 ] &&
    retry "cosign attest $ref" cosign attest --yes --type cyclonedx --predicate "$f" "$ref"; then
    got[i]=sbom+signature
  fi
  echo "$ref: ${got[$i]}"
  [ "${got[$i]}" = "$want" ] || echo "::warning::sign-image: $ref got '${got[$i]}', wanted '$want'; re-run the job to retry"
  [ "$(rank "${got[$i]}")" -lt "$(rank "$overall")" ] && overall=${got[$i]}
done
echo "status=$overall" >> "${GITHUB_OUTPUT:-/dev/null}"
