#!/usr/bin/env bash
# sign-image.sh: cosign keyless sign + CycloneDX attest each REF (<image>@sha256:<64 hex>).
# Env: SIGN_REFS (newline/space separated), SBOM (true|false), SYFT_IMAGE; optional OCI_ARCHIVE
# with OCI_ARCHIVE_REF (<image>@sha256:<digest>): a local OCI image tar of that ref (buildx
# `--output type=oci,dest=…,tar=true` of the same build), scanned instead of pulling the image
# back from the registry. Best-effort per ref:
# prints `status=<sbom+signature|signature|none>` (the weakest over all refs) to $GITHUB_OUTPUT
# and a ::warning:: for every ref that got less than asked; exits 0 unless REFS is malformed.
# The SBOMs are made in the background while cosign installs and signs: the scan (image
# download + syft) is most of the time and does not depend on the signature.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

install_cosign() { # pinned binary from GitHub Releases through nora, sha256-checked; one retry after a pause.
  # Left on the job's PATH like cosign-installer did (callers verify with it afterwards).
  local arch bindir="${RUNNER_TEMP:-$dir}/sign-image-bin" i
  local bin="$bindir/cosign"
  case $(uname -m) in x86_64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "no cosign pin for $(uname -m)"; return 1 ;; esac
  mkdir -p "$bindir"
  for i in 1 2; do
    # GITHUB_OUTPUT is this action's own: fetched=true there is for security-scan's cache step
    if GITHUB_OUTPUT='' timeout 120 bash "$here/../security-scan/fetch-pinned.sh" \
      "https://packages.maestra.io/github/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-$arch" \
      "${COSIGN_SHA256[$arch]}" "$bin"; then
      chmod +x "$bin"; PATH="$bindir:$PATH"
      [ -n "${GITHUB_PATH:-}" ] && echo "$bindir" >>"$GITHUB_PATH"
      return 0
    fi
    echo "cosign $COSIGN_VERSION download attempt $i failed"; [ "$i" -lt 2 ] && sleep 20
  done
  return 1
}

# archive_holds <tar> <digest>: the OCI layout's index.json lists exactly this manifest digest.
archive_holds() {
  [ -s "$1" ] && tar -xOf "$1" index.json 2>/dev/null | jq -e --arg d "$2" 'any(.manifests[]?; .digest == $d)' >/dev/null
}

sbom_of() { # <ref> <out file>: syft from its OCI image, ECR auth from the job's AWS credentials.
  # The auth goes in through a throwaway docker config, not SYFT_REGISTRY_AUTH_*: syft redacts
  # every configured auth value from its output, so the username "AWS" became "*******" in the
  # package descriptions and authors of the SBOM (AWS SDK packages, code-intelligence image).
  # With OCI_ARCHIVE of this very ref, syft reads the local tar instead: the runners sit in
  # eu-central-1 and ECR in us-west-2, so the pull back was most of syft's time (e2e image
  # ~110 s). --source-name/--source-version keep the SBOM's subject the registry scan's
  # (image, digest): same document apart from serialNumber and timestamp (checked 2026-11-20).
  local ref=$1 out=$2 registry region pass cfg="$dir/docker-${2##*/}" start=$SECONDS from=registry
  local -a run=(-v "$cfg:/docker-config:ro" -e DOCKER_CONFIG=/docker-config) src=("registry:$ref")
  if [ -n "${OCI_ARCHIVE:-}" ] && [ "$ref" = "${OCI_ARCHIVE_REF:-}" ]; then
    if archive_holds "$OCI_ARCHIVE" "${ref#*@}"; then
      from="local OCI archive"
      # absolute: `-v image.tar:…` would name a Docker volume, not bind the file checked above
      local archive; archive="$(cd "$(dirname "$OCI_ARCHIVE")" && pwd)/$(basename "$OCI_ARCHIVE")"
      run=(-v "$archive:/in/image.tar:ro")
      src=(oci-archive:/in/image.tar --source-name "${ref%@*}" --source-version "${ref#*@}")
    else
      echo "$ref: $OCI_ARCHIVE does not hold ${ref#*@}: SBOM from the registry"
    fi
  fi
  if [ "$from" = registry ]; then
    registry=${ref%%/*}
    region=$(cut -d. -f4 <<<"$registry")
    pass=$(aws ecr get-login-password --region "$region") || return 1
    mkdir -p "$cfg"
    (umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$registry" "$(printf 'AWS:%s' "$pass" | base64 -w0)" >"$cfg/config.json")
  fi
  docker image inspect "$SYFT_IMAGE" >/dev/null 2>&1 || timeout 300 docker pull -q "$SYFT_IMAGE" >/dev/null
  local pulled=$SECONDS
  timeout 900 docker run --rm "${run[@]}" "$SYFT_IMAGE" "${src[@]}" -q -o cyclonedx-json >"$out"
  local rc=$?
  rm -rf "$cfg"
  [ "$rc" = 0 ] && test -s "$out" || return 1
  echo "$ref: SBOM $(jq '.components | length' "$out") components, $(wc -c <"$out") bytes, syft $((SECONDS - pulled)) s from the $from (+$((pulled - start)) s auth and syft image)"
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
      sbom_of "${refs[$i]}" "$dir/sbom-$i.cdx.json" >"$dir/sbom-$i.log" 2>&1
      echo $? >"$dir/sbom-$i.rc.tmp" && mv "$dir/sbom-$i.rc.tmp" "$dir/sbom-$i.rc"
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

# Attest each ref as soon as its SBOM is there: the next SBOM is made meanwhile.
overall=$want
for i in "${!refs[@]}"; do
  ref=${refs[$i]} f="$dir/sbom-$i.cdx.json"
  while [ -n "$sbom_pid" ] && [ ! -f "$dir/sbom-$i.rc" ] && kill -0 "$sbom_pid" 2>/dev/null; do sleep 1; done
  [ -f "$dir/sbom-$i.log" ] && cat "$dir/sbom-$i.log"
  if [ "${got[$i]}" = signature ] && [ "$SBOM" = true ] && [ "$(cat "$dir/sbom-$i.rc" 2>/dev/null)" = 0 ] &&
    retry "cosign attest $ref" cosign attest --yes --type cyclonedx --predicate "$f" "$ref"; then
    got[i]=sbom+signature
  fi
  echo "$ref: ${got[$i]}"
  [ "${got[$i]}" = "$want" ] || echo "::warning::sign-image: $ref got '${got[$i]}', wanted '$want'; re-run the job to retry"
  [ "$(rank "${got[$i]}")" -lt "$(rank "$overall")" ] && overall=${got[$i]}
done
[ -n "$sbom_pid" ] && wait "$sbom_pid"
echo "status=$overall" >> "${GITHUB_OUTPUT:-/dev/null}"
