#!/usr/bin/env bash
#
# Self-check for the `already in ECR?` step of service-build.yml and
# dotnet-service-build.yml: the inline block (between the ecr-push-check
# markers) against a fake `aws` that answers like ECR. Three cases: tag absent
# (push), tag holds this digest (skip), tag holds another digest (fail).
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
# fake `aws ecr describe-images`: FAKE_ECR=absent|<digest>
case "${FAKE_ECR:-absent}" in
  absent) echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageTag: 'x'} does not exist" >&2; exit 254 ;;
  norepo) echo "An error occurred (RepositoryNotFoundException) when calling the DescribeImages operation: The repository with name 'x' does not exist" >&2; exit 254 ;;
  down)   echo "An error occurred (AccessDeniedException) when calling the DescribeImages operation: nope" >&2; exit 254 ;;
  *)      printf '{"imageDetails":[{"imageDigest":"%s"}]}\n' "$FAKE_ECR" ;;
esac
SH
chmod +x "$tmp/bin/aws"
run() { # FAKE_ECR DIGEST -> prints "rc skip-output"
  : > "$tmp/out"
  rc=0; FAKE_ECR="$1" DIGEST="$2" IMAGE=x RELEASE=1.1.7 GITHUB_OUTPUT="$tmp/out" PATH="$tmp/bin:$PATH" bash -c "set -eo pipefail; $prog" >"$tmp/log" 2>&1 || rc=$?
  echo "$rc $(tr '\n' ' ' < "$tmp/out")"
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n---\n' "$3" "$1" "$2"; cat "$tmp/log"; exit 1; }; }
d=sha256:1111111111111111111111111111111111111111111111111111111111111111
e=sha256:2222222222222222222222222222222222222222222222222222222222222222
eq "$(run absent "$d")" "0 skip=false " "tag absent -> push"
eq "$(run norepo "$d")" "0 skip=false " "repository absent -> push (the action creates it)"
eq "$(run "$d" "$d")"   "0 skip=true "  "same digest -> skip"
eq "$(run "$e" "$d")"   "1 "            "other digest -> fail (immutable tag)"
eq "$(run down "$d")"   "1 "            "ECR unreadable -> fail"
eq "$(run absent "")"   "1 "            "no digest from the build -> fail"
echo "ecr-push-check: ok"
