#!/usr/bin/env bash
#
# End-to-end test for ci/next-version.sh: builds throwaway git repositories with
# real commits and real tags and asserts the tag the release workflow would cut.
#
# Real repos rather than a stubbed `git log`, because every interesting case in
# this script is a git question — is the tag an ancestor, does HEAD already
# carry one, does 1.1.10 sort above 1.1.9 — and a stub answers those the way I
# assumed rather than the way git does.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../next-version.sh"

fails=0

# Build a repo from a spec: lines of `tag <name>` or `commit <subject>`.
# A subject may carry an embedded body after a literal `\n`.
make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m "initial"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "tag "*)    git -C "$dir" tag -a "${line#tag }" -m "${line#tag }" ;;
      "commit "*) git -C "$dir" commit -q --allow-empty -m "$(printf '%b' "${line#commit }")" ;;
    esac
  done
  echo "$dir"
}

check() {
  local name="$1" want="$2" spec="$3"
  local dir got
  dir="$(printf '%s\n' "$spec" | make_repo)"
  got="$(cd "$dir" && bash "$script" | grep '^next=' | cut -d= -f2)"
  rm -rf "$dir"
  if [ "$got" = "$want" ]; then
    echo "ok   ${name}: ${got}"
  else
    echo "::error::${name}: expected ${want}, got ${got}"
    fails=$((fails + 1))
  fi
}

check "no tags at all -> first release" v0.1.0 \
'commit chore: something'

check "non-conventional subjects still get a patch" v1.1.8 \
'tag v1.1.7
commit os-update: apt-mark must wait for the dpkg lock
commit ecr: add mirror-to-secondary-ecr composite'

check "fix: is a patch" v1.1.8 \
'tag v1.1.7
commit fix(ansible-run): read-only checks must not share the lane'

check "feat: anywhere in the range wins over patches" v1.2.0 \
'tag v1.1.7
commit fix(os-update): explicit --ref on the dispatch
commit feat(terraform): per-row runs_on
commit os-update: stage skips the plan job'

check "bang marks a breaking change" v2.0.0 \
'tag v1.1.7
commit feat(ansible-run): optional second Vault source
commit feat(terraform)!: drop the teleport tunnel input'

check "BREAKING CHANGE: in the body marks it too" v2.0.0 \
'tag v1.1.7
commit refactor(os-update): rename the mode input\n\nBREAKING CHANGE: mode=stage is now mode=prepare'

check "squash-merge (#NN) suffix does not hide the type" v1.2.0 \
'tag v1.1.7
commit feat(ansible-pr): per-row runs_on in the check matrix (#34)'

check "a merge commit contributes nothing but still gets a patch" v1.1.8 \
'tag v1.1.7
commit Merge pull request #19 from maestra-io/fix/rolling-target'

# `sort -V` is absent on BSD sort and `sort -n` on the whole string would rank
# 1.1.10 below 1.1.9. This is the case that catches a regression to either.
check "double-digit patch sorts above single-digit" v1.1.11 \
'tag v1.1.9
commit chore: one
tag v1.1.10
commit chore: two'

check "already-tagged HEAD is reused, not re-cut" v1.1.7 \
'commit chore: one
tag v1.1.7'

# A tag that is NOT an ancestor of HEAD must not become the baseline: it would
# make the next release jump to a line nobody merged.
echo -n "ok   unmerged tag is ignored: "
d="$(mktemp -d)"
git -C "$d" init -q -b main
git -C "$d" config user.email t@example.com
git -C "$d" config user.name test
git -C "$d" commit -q --allow-empty -m initial
git -C "$d" tag -a v1.1.7 -m v1.1.7
git -C "$d" checkout -q -b side
git -C "$d" commit -q --allow-empty -m "feat: unmerged work"
git -C "$d" tag -a v9.0.0 -m v9.0.0
git -C "$d" checkout -q main
git -C "$d" commit -q --allow-empty -m "chore: on main"
got="$(cd "$d" && bash "$script" | grep '^next=' | cut -d= -f2)"
rm -rf "$d"
if [ "$got" = "v1.1.8" ]; then
  echo "$got"
else
  echo
  echo "::error::unmerged tag is ignored: expected v1.1.8, got ${got}"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "::error::${fails} case(s) failed"
  exit 1
fi
echo "all cases passed"
