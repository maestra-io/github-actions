#!/usr/bin/env bash
#
# Self-check for the `already in ECR?` step of mcf-build.yml's image, deps-image and e2e-image:
# the three copies of the inline block (between the ecr-release-check markers) are equal and
# run against a fake `aws` that answers like ECR. image, deps-image and e2e-image push side by
# side once the tests pass, so "Re-run all jobs" (same release number, immutable tags) may meet
# a tag one of them pushed in an earlier attempt. Cases: tag absent or no repository (push), tag
# built from this commit (skip, keep its digest), tag from another or an unknown commit, an
# unreadable config blob or ECR (fail). Then the wiring: each job runs the block before its
# build-and-push, which it skips on skip=true, and signs the kept digest.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/mcf-build.yml"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# every copy of the block to its own file (block-1 image, block-2 deps-image, block-3 e2e-image)
awk -v d="$tmp" '/# >>> ecr-release-check/ { n++; on = 1 } on { sub(/^          /, ""); print > (d "/block-" n) } /# <<< ecr-release-check/ { on = 0 }' "$wf"
copies=$(find "$tmp" -name 'block-*' | wc -l | tr -d ' ')
[ "$copies" = 3 ] || { echo "FAIL: $copies ecr-release-check blocks in mcf-build.yml, want 3 (image, deps-image, e2e-image)"; exit 1; }
for n in 2 3; do cmp -s "$tmp/block-1" "$tmp/block-$n" || { echo "FAIL: ecr-release-check block $n differs from block 1"; diff "$tmp/block-1" "$tmp/block-$n"; exit 1; }; done
prog=$(cat "$tmp/block-1")

mkdir -p "$tmp/bin"
cat > "$tmp/bin/aws" <<'SH'
#!/usr/bin/env bash
# fake `aws ecr describe-images|batch-get-image|get-download-url-for-layer`:
# FAKE_ECR=absent|norepo|down|<digest>; FAKE_REV = the stored image's revision label
# (empty: no label), FAKE_CFG=down: the config blob is unreadable.
here=$(dirname "$0")
echo "$*" >> "$here/calls"
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
run() { # FAKE_ECR [FAKE_REV [GITHUB_SHA]] -> prints "rc outputs"
  : > "$tmp/out"; : > "$tmp/bin/calls"
  rc=0; FAKE_ECR="$1" FAKE_REV="${2:-}" GITHUB_SHA="${3-$sha}" REPO=frontend-x-e2e RELEASE=1.1.7 GITHUB_OUTPUT="$tmp/out" \
    PATH="$tmp/bin:$PATH" bash -c "set -eo pipefail; $prog" >"$tmp/log" 2>&1 || rc=$?
  echo "$rc $(tr '\n' ' ' < "$tmp/out")"
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n---\n' "$3" "$1" "$2"; cat "$tmp/log"; exit 1; }; }
e=sha256:2222222222222222222222222222222222222222222222222222222222222222
eq "$(run absent)" "0 skip=false " "tag absent -> build and push"
eq "$(run norepo)" "0 skip=false " "repository absent -> build and push (the ecr login step creates it)"
eq "$(run "$e" "$sha")" "0 skip=true digest=$e " "tag from this commit (an earlier attempt) -> skip, keep its digest"
grep -q 'built from this commit .* by an earlier attempt: build and push skipped' "$tmp/log" || { echo "FAIL: no skip message"; cat "$tmp/log"; exit 1; }
grep -q -- '--repository-name frontend-x-e2e --image-ids imageTag=1.1.7' "$tmp/bin/calls" || { echo "FAIL: not the job's repository and release"; cat "$tmp/bin/calls"; exit 1; }
eq "$(run "$e")" "1 " "tag without a revision label -> fail (immutable tag)"
grep -q '^::error::frontend-x-e2e:1.1.7 already exists in ECR .* A new run of the release workflow takes the next release number' "$tmp/log" \
  || { echo "FAIL: no actionable error"; cat "$tmp/log"; exit 1; }
eq "$(run "$e" fedcba9876543210fedcba9876543210fedcba98)" "1 " "tag from another commit -> fail"
eq "$(run "$e" "" "")" "1 " "no label and no GITHUB_SHA -> fail (empty never matches)"
eq "$(FAKE_CFG=down run "$e" "$sha")" "1 " "config blob unreadable -> fail"
eq "$(run down)" "1 " "ECR unreadable -> fail"
echo "ecr-release-check: ok"

# Wiring: in each job the check runs before the build and push of the same repository, the
# push is skipped on skip=true, and sign-image gets the kept digest when nothing was pushed.
jobtext() { awk -v j="  $1:" '$0 == j { on = 1; next } on && /^  [a-z]/ { exit } on' "$wf"; }
for spec in "image|" "deps-image|-with-deps" "e2e-image|-e2e"; do
  job=${spec%%|*} suffix=${spec#*|}
  t=$(jobtext "$job")
  repo="\${{ needs.version.outputs.image }}$suffix"
  # shellcheck disable=SC2016 # the expressions are matched literally
  {
    grep -qxF "          repositories: $repo" <<<"$t" || { echo "FAIL $job: ecr login is not for $repo"; exit 1; }
    grep -qxF "          REPO: $repo" <<<"$t" || { echo "FAIL $job: the check does not read $repo"; exit 1; }
    check=$(grep -n '        id: existing$' <<<"$t" | cut -d: -f1)
    push=$(grep -n '        id: push$' <<<"$t" | cut -d: -f1)
    [ -n "$check" ] && [ -n "$push" ] && [ "$check" -lt "$push" ] || { echo "FAIL $job: the check does not run before the push"; exit 1; }
    sed -n "$((push + 1))p" <<<"$t" | grep -qxF "        if: \${{ steps.existing.outputs.skip != 'true' }}" \
      || { echo "FAIL $job: the push is not skipped on skip=true"; exit 1; }
    grep -qxF '          digest: ${{ steps.push.outputs.digest || steps.existing.outputs.digest }}' <<<"$t" \
      || { echo "FAIL $job: sign-image does not get the kept digest"; exit 1; }
  }
done
echo "ecr-release-check wiring: ok"

# deps-image and e2e-image (both with a gha layer cache) export the pushed image as an OCI tar
# too, and sign-image reads that very tar: a path that differs would quietly fall back to
# pulling the image back from ECR across the Atlantic.
for spec in "deps-image|with-deps" "e2e-image|e2e"; do
  job=${spec%%|*} name=${spec#*|}
  t=$(jobtext "$job")
  # shellcheck disable=SC2016 # the expressions are matched literally
  {
    grep -qxF "          outputs: type=oci,dest=\${{ runner.temp }}/$name.oci.tar,tar=true" <<<"$t" \
      || { echo "FAIL $job: no OCI tar exporter next to the push"; exit 1; }
    grep -qxF "          oci-archive: \${{ runner.temp }}/$name.oci.tar" <<<"$t" \
      || { echo "FAIL $job: sign-image does not read the exported tar"; exit 1; }
    grep -qxF '          push: true' <<<"$t" || { echo "FAIL $job: the push is no longer push: true"; exit 1; }
  }
done
hasnt_image=$(jobtext image)
if grep -q 'oci-archive:' <<<"$hasnt_image"; then echo "FAIL image: no layer cache, its tar would pull the base from ECR anyway"; exit 1; fi
echo "SBOM from the OCI tar: ok"
