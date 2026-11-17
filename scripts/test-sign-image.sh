#!/usr/bin/env bash
#
# Self-check for sign-image/sign-image.sh against fake cosign, curl, docker and aws:
# the best-effort contract (status output, warnings, exit code) with the SBOM made in
# the background, and that syft gets no SYFT_REGISTRY_AUTH_* (it redacts those values
# from the SBOM: pkg:nuget/*******SDK.Core).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
stub() { cat > "$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
stub sleep <<'SH'
#!/usr/bin/env bash
exit 0
SH
stub aws <<'SH'
#!/usr/bin/env bash
echo fake-ecr-password
SH
# the "downloaded" binary is the fake cosign itself: the script puts it first on PATH
stub curl <<'SH'
#!/usr/bin/env bash
[ "${FAKE_CURL:-ok}" = ok ] || exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "$(dirname "$0")/cosign" "$2"; shift; done
SH
stub sha256sum <<'SH'
#!/usr/bin/env bash
[ "${FAKE_SHA:-ok}" = ok ]
SH
stub cosign <<'SH'
#!/usr/bin/env bash
echo "cosign $*" >> "$FAKE_LOG"
case " $* " in *" ${FAKE_COSIGN_FAIL:-no-such-word} "*) exit 1 ;; esac
SH
stub docker <<'SH'
#!/usr/bin/env bash
[ "$1" = run ] || exit 0
echo "docker $*" >> "$FAKE_LOG"
if env | grep -q '^SYFT_REGISTRY_AUTH'; then echo SYFT_ENV >> "$FAKE_LOG"; fi
for a in "$@"; do
  case "$a" in
    *:/docker-config:ro) grep -q '"auth":"' "${a%%:*}/config.json" || echo NO_AUTH >> "$FAKE_LOG" ;;
    registry:*"${FAKE_SYFT_FAIL:-no-such-ref}"*) exit 1 ;;
  esac
done
echo '{"components":[{"name":"a"}]}'
SH
a=123456789012.dkr.ecr.us-west-2.amazonaws.com/a@sha256:$(printf '1%.0s' {1..64})
b=123456789012.dkr.ecr.us-west-2.amazonaws.com/b@sha256:$(printf '2%.0s' {1..64})
run() { # env assignments...: prints "rc status"
  : > "$tmp/out"; : > "$tmp/log"; : > "$tmp/path"
  local rc=0
  env "$@" PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/out" GITHUB_PATH="$tmp/path" \
    SYFT_IMAGE=syft bash "$here/../sign-image/sign-image.sh" > "$tmp/stdout" 2>&1 || rc=$?
  echo "$rc $(cat "$tmp/out")"
}
fail() { printf 'FAIL %s\n---\n' "$1"; cat "$tmp/stdout" "$tmp/log"; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
has() { grep -qF -- "$1" "$2" || fail "$3: no '$1' in $2"; }
hasnt() { if grep -qF -- "$1" "$2"; then fail "$3: '$1' in $2"; fi; }

# run() goes in a plain statement, not $(...): the files it leaves are read afterwards
check() { local want=$1 what=$2 got; shift 2; run "$@" > "$tmp/result"; got=$(cat "$tmp/result"); eq "$got" "$want" "$what"; }

check "0 status=sbom+signature" "one ref" SIGN_REFS="$a" SBOM=true
has "cosign sign --yes $a" "$tmp/log" "signed"
has "cosign attest --yes --type cyclonedx" "$tmp/log" "attested"
has "registry:$a" "$tmp/log" "syft pulled the digest"
hasnt SYFT_ENV "$tmp/log" "no SYFT_REGISTRY_AUTH_* in the environment"
hasnt SYFT_REGISTRY_AUTH "$tmp/log" "no SYFT_REGISTRY_AUTH_* in the docker args"
hasnt NO_AUTH "$tmp/log" "auth in the throwaway docker config"
has sign-image-bin "$tmp/path" "cosign stays on the job PATH"

check "0 status=signature" "sbom: false" SIGN_REFS="$a" SBOM=false
hasnt "docker run" "$tmp/log" "sbom: false runs no syft"
hasnt "cosign attest" "$tmp/log" "sbom: false attests nothing"

check "0 status=signature" "syft fails" SIGN_REFS="$a" SBOM=true FAKE_SYFT_FAIL=/a@
hasnt "cosign attest" "$tmp/log" "no SBOM, no attestation"
has "got 'signature', wanted 'sbom+signature'" "$tmp/stdout" "syft failure warns"

check "0 status=signature" "attest fails" SIGN_REFS="$a" SBOM=true FAKE_COSIGN_FAIL=attest
check "0 status=none" "sign fails" SIGN_REFS="$a" SBOM=true FAKE_COSIGN_FAIL=sign
hasnt "cosign attest" "$tmp/log" "no signature, no attestation"

check "0 status=none" "cosign download fails" SIGN_REFS="$a" SBOM=true FAKE_CURL=fail
has "cosign could not be installed" "$tmp/stdout" "download failure warns"
check "0 status=none" "cosign sha256 mismatch" SIGN_REFS="$a" SBOM=true FAKE_SHA=bad
hasnt "cosign sign" "$tmp/log" "a binary with the wrong sha256 never runs"

check "0 status=signature" "second SBOM fails: the weakest wins" SIGN_REFS="$a $b" SBOM=true FAKE_SYFT_FAIL=/b@
has "$a: sbom+signature" "$tmp/stdout" "first ref keeps its attestation"
has "$b: signature" "$tmp/stdout" "second ref is signature only"

check "1 " "malformed ref fails" SIGN_REFS=not-a-digest SBOM=true
check "1 " "no ref fails" SIGN_REFS= SBOM=true
echo "ok: sign-image"
