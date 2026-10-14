#!/usr/bin/env bash
# push-helm-chart-to-aws-ecr "Package and push" step (extracted from action.yml):
# the registry comes from the role ARN, one describe-images decides between
# skip / create repository / push, any other ECR error fails the step.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
yq -r '.runs.steps[] | select(.id=="push") | .run' "${here}/../push-helm-chart-to-aws-ecr/action.yml" > "$dir/push.sh"

mkdir -p "$dir/bin" "$dir/wd" "$dir/chart"
cat > "$dir/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "$2" in
  describe-images)
    case "$STUB_IMAGE" in
      exists) exit 0 ;;
      norepo) echo "An error occurred (RepositoryNotFoundException) when calling the DescribeImages operation: The repository with name 'x' does not exist in the registry" >&2; exit 254 ;;
      noimage) echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageTag: '1'} does not exist" >&2; exit 254 ;;
      denied) echo "An error occurred (AccessDeniedException) when calling the DescribeImages operation: not authorized" >&2; exit 254 ;;
    esac ;;
  get-login-password) echo pw ;;
esac
STUB
cat > "$dir/bin/helm" <<'STUB'
#!/usr/bin/env bash
echo "helm $*" >> "$CALLS"
[ "$1 $2" = "registry login" ] && cat >/dev/null  # drain --password-stdin, else aws dies of SIGPIPE under pipefail
exit 0
STUB
chmod +x "$dir/bin/aws" "$dir/bin/helm"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "create-repository $*" >> "$CALLS"\n' > "$dir/wd/create-repository.sh"
echo '{}' > "$dir/wd/ecr-policy.json"

fails=0
run() { # <case> <STUB_IMAGE> [role ARN]
  : > "$dir/calls"; : > "$dir/out"
  if (cd "$dir/wd" && env PATH="$dir/bin:$PATH" CALLS="$dir/calls" STUB_IMAGE="$2" GITHUB_OUTPUT="$dir/out" \
     CHART_PATH="$dir/chart" NAME=cdp-app-tenant VERSION=4.9318.0 APP_VERSION=4.9318.0 PREFIX=helm-charts \
     AWS_REGION=us-west-2 AWS_ROLE_ARN="${3:-arn:aws:iam::515260921971:role/teleport-image-push}" \
     bash "$dir/push.sh" >"$dir/stdout" 2>&1); then rc=0; else rc=$?; fi
}
expect() { # <case> <condition description> <test...>
  local case="$1" what="$2"; shift 2
  if "$@"; then echo "ok   $case: $what"; else echo "FAIL $case: $what"; echo "--- calls"; cat "$dir/calls"; echo "--- stdout"; cat "$dir/stdout"; fails=$((fails+1)); fi
}
has() { grep -q -- "$1" "$dir/calls"; }
lacks() { ! grep -q -- "$1" "$dir/calls"; }

run exists exists
expect exists "rc 0" [ "$rc" -eq 0 ]
expect exists "pushed=false" grep -q '^pushed=false$' "$dir/out"
expect exists "no helm push" lacks "helm push"
expect exists "one aws call" [ "$(grep -c '^aws ' "$dir/calls")" -eq 1 ]

run noimage noimage
expect noimage "rc 0" [ "$rc" -eq 0 ]
expect noimage "pushed=true" grep -q '^pushed=true$' "$dir/out"
expect noimage "no create-repository" lacks "create-repository"
expect noimage "registry from the role ARN" has "helm push .*oci://515260921971.dkr.ecr.us-west-2.amazonaws.com/helm-charts"
expect noimage "two aws calls (describe-images, get-login-password)" [ "$(grep -c '^aws ' "$dir/calls")" -eq 2 ]
expect noimage "no sts call" lacks "aws sts"

run govcloud noimage arn:aws-us-gov:iam::123456789012:role/x
expect govcloud "account parsed from a non-aws partition" has "helm push .*oci://123456789012.dkr.ecr.us-west-2.amazonaws.com/helm-charts"
run badarn noimage arn:aws:iam::nope:role/x
expect badarn "rc 1" [ "$rc" -eq 1 ]
expect badarn "no helm push" lacks "helm push"

run norepo norepo
expect norepo "rc 0" [ "$rc" -eq 0 ]
expect norepo "create-repository helm-charts/cdp-app-tenant" has "create-repository helm-charts/cdp-app-tenant"
expect norepo "repository policy set" has "aws ecr set-repository-policy --repository-name helm-charts/cdp-app-tenant"
expect norepo "helm push" has "helm push"

run denied denied
expect denied "rc 1" [ "$rc" -eq 1 ]
expect denied "error surfaced" grep -q AccessDeniedException "$dir/stdout"
expect denied "no helm push" lacks "helm push"
expect denied "no create-repository" lacks "create-repository"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
