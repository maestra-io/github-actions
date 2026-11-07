#!/usr/bin/env bash
# push-helm-chart-to-aws-ecr "cosign sign + verify chart" step (extracted from
# action.yml): signs the published digest unless its .sig tag exists, always
# verifies with the clusters' identity, fails on a missing digest or a failed
# sign/verify.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
yq -r '.runs.steps[] | select(.id=="sign") | .run' "${here}/../push-helm-chart-to-aws-ecr/action.yml" > "$dir/sign.sh"

mkdir -p "$dir/bin"
cat > "$dir/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "$2" in
  describe-images)
    case "$*" in
      *imageTag=sha256-*.sig*) [ "$STUB_SIGNED" = yes ] ;;
      *) [ "$STUB_DIGEST" = none ] && echo None || echo "sha256:abc" ;;
    esac ;;
  get-login-password) echo pw ;;
esac
STUB
cat > "$dir/bin/cosign" <<'STUB'
#!/usr/bin/env bash
echo "cosign $*" >> "$CALLS"
[ "$1" = login ] && { cat >/dev/null; exit 0; }
[ "$1" = sign ] && [ "${STUB_SIGN_FAIL:-}" = yes ] && exit 1
[ "$1" = verify ] && [ "${STUB_VERIFY_FAIL:-}" = yes ] && exit 1
exit 0
STUB
chmod +x "$dir/bin/aws" "$dir/bin/cosign"

fails=0
run() { # <STUB_SIGNED> <STUB_DIGEST> [env...]
  local signed="$1" digest="$2"; shift 2
  : > "$dir/calls"; : > "$dir/out"
  if env PATH="$dir/bin:$PATH" CALLS="$dir/calls" STUB_SIGNED="$signed" STUB_DIGEST="$digest" GITHUB_OUTPUT="$dir/out" \
     REGISTRY=reg REPOSITORY=helm-charts/mcf-upload VERSION=3.0.0 "$@" \
     bash "$dir/sign.sh" >"$dir/stdout" 2>&1; then rc=0; else rc=$?; fi
}
expect() { local case="$1" what="$2"; shift 2
  if "$@"; then echo "ok   $case: $what"; else echo "FAIL $case: $what"; cat "$dir/calls" "$dir/stdout"; fails=$((fails+1)); fi; }
has() { grep -q -- "$1" "$dir/calls"; }
lacks() { ! grep -q -- "$1" "$dir/calls"; }

run no sha
expect unsigned "rc 0" [ "$rc" -eq 0 ]
expect unsigned "signs the digest" has "cosign sign --yes reg/helm-charts/mcf-upload@sha256:abc"
expect unsigned "verifies with the maestra-io identity" has "cosign verify .*--certificate-identity-regexp ^https://github\\\\.com/maestra-io/ reg/helm-charts/mcf-upload@sha256:abc"
expect unsigned "digest output" grep -qx "digest=sha256:abc" "$dir/out"

run yes sha
expect signed "rc 0" [ "$rc" -eq 0 ]
expect signed "no sign" lacks "cosign sign"
expect signed "still verifies" has "cosign verify"

run no none
expect no-digest "rc != 0" [ "$rc" -ne 0 ]
expect no-digest "no sign" lacks "cosign sign"

run no sha STUB_SIGN_FAIL=yes
expect sign-fails "rc != 0" [ "$rc" -ne 0 ]

run yes sha STUB_VERIFY_FAIL=yes
expect verify-fails "rc != 0" [ "$rc" -ne 0 ]

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
