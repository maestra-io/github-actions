#!/usr/bin/env bash
#
# Self-check for the `already in ECR?` step of service-build.yml and
# dotnet-service-build.yml: the inline block (between the ecr-push-check
# markers) against a fake `aws` that answers like ECR. Cases: tag absent (push),
# tag holds this digest (skip), tag holds another digest built from this commit
# (retry after a non-reproducible rebuild: skip, keep the pushed digest), tag holds
# another digest from another or an unknown commit (fail).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for wf in service-build dotnet-service-build; do
  prog=$(sed -n '/# >>> ecr-push-check/,/# <<< ecr-push-check/p' "$here/../.github/workflows/$wf.yml" | sed 's/^          //')
  [ -n "$prog" ] || { echo "ecr-push-check block not found in $wf.yml"; exit 1; }
  [ "$wf" = service-build ] && first="$prog" || [ "$first" = "$prog" ] || { echo "FAIL: the block differs between service-build.yml and dotnet-service-build.yml"; exit 1; }
done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/aws" <<'SH'
#!/usr/bin/env bash
# fake `aws ecr describe-images|batch-get-image|get-download-url-for-layer`:
# FAKE_ECR=absent|norepo|down|<digest>; FAKE_REV = the stored image's revision label
# (empty: no label), FAKE_CFG=down: the config blob is unreadable.
here=$(dirname "$0")
case "$2" in
  batch-get-image)
    printf '%s\n' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:cfg"}}'
    exit 0 ;;
  get-download-url-for-layer)
    [ "${FAKE_CFG:-}" = down ] && { echo "An error occurred (LayerInaccessibleException)" >&2; exit 254; }
    if [ -n "${FAKE_REV:-}" ]; then printf '{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}\n' "$FAKE_REV"
    else echo '{"config":{"Labels":{}}}'; fi > "$here/config.json"
    echo "file://$here/config.json"
    exit 0 ;;
esac
case "${FAKE_ECR:-absent}" in
  absent) echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageTag: 'x'} does not exist" >&2; exit 254 ;;
  norepo) echo "An error occurred (RepositoryNotFoundException) when calling the DescribeImages operation: The repository with name 'x' does not exist" >&2; exit 254 ;;
  down)   echo "An error occurred (AccessDeniedException) when calling the DescribeImages operation: nope" >&2; exit 254 ;;
  *)      printf '{"imageDetails":[{"imageDigest":"%s"}]}\n' "$FAKE_ECR" ;;
esac
SH
chmod +x "$tmp/bin/aws"
sha=0123456789abcdef0123456789abcdef01234567
run() { # FAKE_ECR DIGEST [FAKE_REV [GITHUB_SHA]] -> prints "rc outputs"
  : > "$tmp/out"
  rc=0; FAKE_ECR="$1" DIGEST="$2" FAKE_REV="${3:-}" GITHUB_SHA="${4-$sha}" IMAGE=x RELEASE=1.1.7 GITHUB_OUTPUT="$tmp/out" PATH="$tmp/bin:$PATH" bash -c "set -eo pipefail; $prog" >"$tmp/log" 2>&1 || rc=$?
  echo "$rc $(tr '\n' ' ' < "$tmp/out")"
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n---\n' "$3" "$1" "$2"; cat "$tmp/log"; exit 1; }; }
d=sha256:1111111111111111111111111111111111111111111111111111111111111111
e=sha256:2222222222222222222222222222222222222222222222222222222222222222
eq "$(run absent "$d")" "0 skip=false " "tag absent -> push"
eq "$(run norepo "$d")" "0 skip=false " "repository absent -> push (the action creates it)"
eq "$(run "$d" "$d")"   "0 skip=true digest=$d " "same digest -> skip"
eq "$(run "$e" "$d")"   "1 "            "other digest, no revision label -> fail (immutable tag)"
eq "$(run "$e" "$d" "$sha")" "0 skip=true digest=$e " "other digest from this commit (retry) -> skip, keep the pushed digest"
eq "$(run "$e" "$d" fedcba9876543210fedcba9876543210fedcba98)" "1 " "other digest from another commit -> fail"
eq "$(run "$e" "$d" "" "")" "1 "        "no label and no GITHUB_SHA -> fail (empty never matches)"
eq "$(FAKE_CFG=down run "$e" "$d" "$sha")" "1 " "config blob unreadable -> fail"
eq "$(run down "$d")"   "1 "            "ECR unreadable -> fail"
eq "$(run absent "")"   "1 "            "no digest from the build -> fail"
echo "ecr-push-check: ok"
