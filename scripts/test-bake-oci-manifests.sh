#!/usr/bin/env bash
# bake-oci-manifests "flux push artifact" and "publish release tag" steps
# (extracted from action.yml): a new bake pushes only the staging tag
# bake-<tag>-<sha>, never <tag>; a re-run reuses <tag> or the staging tag of
# this commit and tree; a tag of another bake fails; publishing tags the
# signed digest with its own manifest bytes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
action="${here}/../bake-oci-manifests/action.yml"
yq -r '.runs.steps[] | select(.id=="push") | .run' "$action" > "$dir/push.sh"
yq -r '.runs.steps[] | select(.name=="publish release tag") | .run' "$action" > "$dir/publish.sh"

mkdir -p "$dir/bin" "$dir/tree"
echo a > "$dir/tree/f"
# STUB_TAGS: space-separated <tag>=<revision> present in ECR.
cat > "$dir/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
tag=$(printf '%s\n' "$@" | sed -n 's/^imageTag=//p')
case "$2" in
  batch-get-image)
    for t in $STUB_TAGS; do
      if [ "${t%%=*}" = "$tag" ] || { [ -z "$tag" ] && [ "${t%%=*}" = "${STUB_DIGEST_TAG:-}" ]; }; then
        printf '{"images":[{"imageId":{"imageDigest":"sha256:%s"},"imageManifest":"{\\"annotations\\":{\\"org.opencontainers.image.revision\\":\\"%s\\"}}"}]}' "${t%%=*}" "${t#*=}"
        exit 0
      fi
    done
    echo '{"images":[]}' ;;
  put-image) f=$(printf '%s\n' "$@" | sed -n 's|^file://||p'); cat "$f" > "$MANIFEST_OUT" ;;
esac
STUB
cat > "$dir/bin/flux" <<'STUB'
#!/usr/bin/env bash
echo "flux $*" >> "$CALLS"
if [ "$1" = pull ]; then cp "$TREE"/* "$5"/; else echo '{"digest":"sha256:new"}'; fi
STUB
chmod +x "$dir/bin/aws" "$dir/bin/flux"

fails=0
run() { # <script> <STUB_TAGS> [extra env...]
  local script="$1" tags="$2"; shift 2
  : > "$dir/calls"; : > "$dir/out"; : > "$dir/manifest"
  if env PATH="$dir/bin:$PATH" CALLS="$dir/calls" STUB_TAGS="$tags" GITHUB_OUTPUT="$dir/out" \
     MANIFEST_OUT="$dir/manifest" TREE="$dir/tree" BAKE_PATH="$dir/tree" \
     GITHUB_SHA=abc GITHUB_REPOSITORY=maestra-io/x TAG=1.2.3 IMAGE_MANIFESTS=x-manifests \
     ECR_REGISTRY=reg AWS_REGION=us-west-2 "$@" \
     bash -eo pipefail "$dir/$script" >"$dir/stdout" 2>&1; then rc=0; else rc=$?; fi
}
expect() { # <case> <what> <test...>
  local case="$1" what="$2"; shift 2
  if "$@"; then echo "ok   $case: $what"; else echo "FAIL $case: $what"; echo "--- calls"; cat "$dir/calls"; echo "--- stdout"; cat "$dir/stdout"; fails=$((fails+1)); fi
}
has() { grep -q -- "$1" "$dir/calls"; }
lacks() { ! grep -q -- "$1" "$dir/calls"; }
out() { grep -qx -- "$1" "$dir/out"; }

run push.sh ""
expect new "rc 0" [ "$rc" -eq 0 ]
expect new "pushes the staging tag" has "flux push artifact oci://reg/x-manifests:bake-1.2.3-abc "
expect new "never pushes <tag>" lacks "x-manifests:1.2.3 "
expect new "digest of the push" out "digest=sha256:new"
expect new "published=false" out "published=false"

run push.sh "1.2.3=abc"
expect tag-same "rc 0" [ "$rc" -eq 0 ]
expect tag-same "no push" lacks "flux push"
expect tag-same "reuses <tag>" out "digest=sha256:1.2.3"
expect tag-same "published=true" out "published=true"

run push.sh "bake-1.2.3-abc=abc"
expect stage-same "rc 0" [ "$rc" -eq 0 ]
expect stage-same "no push" lacks "flux push"
expect stage-same "reuses the staging tag" out "digest=sha256:bake-1.2.3-abc"
expect stage-same "published=false" out "published=false"

run push.sh "1.2.3=zzz"
expect tag-other "rc != 0" [ "$rc" -ne 0 ]
expect tag-other "no push" lacks "flux push"

mkdir -p "$dir/tree2"; echo b > "$dir/tree2/f"
run push.sh "bake-1.2.3-abc=abc" TREE="$dir/tree2"
expect stage-other-tree "rc != 0" [ "$rc" -ne 0 ]
expect stage-other-tree "no push" lacks "flux push"

run publish.sh "bake-1.2.3-abc=abc" STUB_DIGEST_TAG=bake-1.2.3-abc DIGEST=sha256:bake-1.2.3-abc
expect publish "rc 0" [ "$rc" -eq 0 ]
expect publish "put-image <tag> on the signed digest" has "put-image .*--image-tag 1.2.3 --image-digest sha256:bake-1.2.3-abc"
expect publish "manifest bytes unchanged" [ "$(cat "$dir/manifest")" = '{"annotations":{"org.opencontainers.image.revision":"abc"}}' ]
expect publish "manifest has no trailing newline" [ "$(tail -c1 "$dir/manifest" | od -An -c | tr -d ' ')" = "}" ]
expect publish "deletes nothing" lacks "batch-delete-image"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
