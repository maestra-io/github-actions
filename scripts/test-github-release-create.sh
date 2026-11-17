#!/usr/bin/env bash
#
# Self-check for the release-create block of service-build.yml, dotnet-service-build.yml
# and mcf-build.yml (between the github-release-create markers) against a fake `gh`. GitHub
# refuses GITHUB_TOKEN a new tag on a commit whose .github/workflows differ from the
# default branch tip (auth-jwt-operator 1.1.6, 16.11.2026): the block must fail and name
# the newer commit and the workflow files, and stay silent about it on other failures.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for wf in service-build dotnet-service-build mcf-build; do
  # indentation differs (mcf-build has it inside an else), bash does not care
  prog=$(sed -n '/# >>> github-release-create/,/# <<< github-release-create/p' "$here/../.github/workflows/$wf.yml" | sed 's/^ *//')
  [ -n "$prog" ] || { echo "github-release-create block not found in $wf.yml"; exit 1; }
  [ "$wf" = service-build ] && first="$prog" || [ "$first" = "$prog" ] || { echo "FAIL: the block in $wf.yml differs from service-build.yml"; exit 1; }
done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
# fake gh: FAKE_CREATE=ok|403, FAKE_HEAD = default branch tip (empty: API down),
# FAKE_WF = the workflow files changed between the two (already --jq'd).
echo "$*" >> "$(dirname "$0")/calls"
case "$1 $2" in
  "release create") [ "$FAKE_CREATE" = ok ] && exit 0
    echo "HTTP 403: Resource not accessible by integration (https://api.github.com/repos/o/r/releases)" >&2; exit 1 ;;
  "api repos/o/r/commits/HEAD") [ -n "$FAKE_HEAD" ] && echo "$FAKE_HEAD" && exit 0; exit 1 ;;
  "api repos/o/r/compare/"*) echo "$FAKE_WF" ;;
  *) echo "unexpected gh $*" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/gh"
sha=0123456789abcdef0123456789abcdef01234567
new=fedcba9876543210fedcba9876543210fedcba98
run() { # FAKE_CREATE FAKE_HEAD FAKE_WF -> "rc <::error line or ->"
  rm -f "$tmp/bin/calls"
  rc=0; FAKE_CREATE="$1" FAKE_HEAD="$2" FAKE_WF="$3" TAG=1.1.6 GITHUB_SHA="$sha" GITHUB_REPOSITORY=o/r \
    PATH="$tmp/bin:$PATH" bash -c "set -eo pipefail; $prog" >"$tmp/log" 2>&1 || rc=$?
  echo "$rc $(grep '^::error::' "$tmp/log" || echo -)"
}
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n---\n' "$3" "$1" "$2"; cat "$tmp/log"; exit 1; }; }
eq "$(run ok "" "")" "0 -" "created"
grep -q -- "--target $sha" "$tmp/bin/calls" || { echo "FAIL: the release does not target GITHUB_SHA"; exit 1; }
[ "$(wc -l < "$tmp/bin/calls")" -eq 1 ] || { echo "FAIL: created, yet more gh calls"; exit 1; }
eq "$(run 403 "$new" ".github/workflows/security-scan.yml")" \
  "1 ::error::release 1.1.6 not created: the default branch moved to fedcba9 and changed .github/workflows/security-scan.yml since 0123456, and GITHUB_TOKEN may not tag a commit whose workflow files differ from the default branch tip. The release of fedcba9 (its own run) supersedes this one; to release 0123456 itself, create release 1.1.6 by hand with a token that has the workflows permission." \
  "403, main moved with a workflow change -> fail, named"
grep -q '^HTTP 403' "$tmp/log" || { echo "FAIL: gh's own error is not shown"; exit 1; }
eq "$(run 403 "$new" "")" "1 -" "403, main moved without a workflow change -> fail, no drift claim"
eq "$(run 403 "$sha" "")" "1 -" "403 on the tip itself -> fail, no drift claim"
if grep -q compare "$tmp/bin/calls"; then echo "FAIL: compared the tip with itself"; exit 1; fi
eq "$(run 403 "" "")" "1 -" "403, API down -> fail, no drift claim"
echo "github-release-create: ok"
