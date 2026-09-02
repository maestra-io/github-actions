#!/usr/bin/env bash
#
# Decide the next release tag for this repository from the commits that landed
# since the previous one, and print the decision as KEY=VALUE lines for
# $GITHUB_OUTPUT.
#
# Bump rules (Conventional Commits, with a deliberate fallback):
#
#   major  any subject of the form `<type>(<scope>)!:` or a body/footer line
#          `BREAKING CHANGE:` / `BREAKING-CHANGE:`
#   minor  any subject `feat:` / `feat(<scope>):`
#   patch  everything else — INCLUDING a range with no Conventional Commit in
#          it at all
#
# The fallback is the whole point. Only 24 of the last 50 subjects in this repo
# are Conventional Commits, so a tool that releases *only* on `feat:`/`fix:`
# (release-please, semantic-release) would cut no tag for more than half of our
# merges — which is exactly the "the tag lags main" bug this exists to fix.
# Here every push to main produces a tag; conventional subjects only decide how
# far it moves.
#
# Output (stdout, KEY=VALUE, one per line):
#   prev=v1.1.7          previous release tag ("" when the repo has none)
#   bump=patch           major|minor|patch|none
#   next=v1.1.8          the tag to create
#   release=true         false when HEAD already carries a semver tag
#
# Read-only: it never writes a ref. The caller creates the tag.

set -euo pipefail

head_ref="${1:-HEAD}"

semver_re='^v[0-9]+\.[0-9]+\.[0-9]+$'

# Highest semver tag that is an ANCESTOR of the ref. `--merged` matters: a tag
# someone pushed onto an unmerged branch must not become the baseline.
# Sorted by numeric field rather than `sort -V`, which BSD sort lacks.
highest_tag() {
  git tag --list 'v*' --merged "$head_ref" \
    | grep -E "$semver_re" \
    | sed 's/^v//' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 \
    | sed 's/^/v/'
}

# A tag already on HEAD means this commit was released (a re-run of the
# workflow, or a hand-cut tag). Re-tagging it would either fail or move a
# published tag; both are worse than doing nothing.
already="$(git tag --list 'v*' --points-at "$head_ref" | grep -E "$semver_re" | head -1 || true)"

prev="$(highest_tag || true)"

if [ -n "$already" ]; then
  printf 'prev=%s\nbump=none\nnext=%s\nrelease=false\n' "$prev" "$already"
  exit 0
fi

if [ -z "$prev" ]; then
  # First release of a repo that has never been tagged.
  printf 'prev=\nbump=minor\nnext=v0.1.0\nrelease=true\n'
  exit 0
fi

range="${prev}..${head_ref}"

subjects="$(git log --format=%s "$range")"
bodies="$(git log --format=%B "$range")"

bump="patch"
if printf '%s\n' "$subjects" | grep -qE '^[a-zA-Z]+(\([^)]*\))?!:' \
   || printf '%s\n' "$bodies" | grep -qE '^BREAKING[ -]CHANGE:'; then
  bump=major
elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
  bump=minor
fi

IFS=. read -r major minor patch <<EOF
${prev#v}
EOF

case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac

printf 'prev=%s\nbump=%s\nnext=v%s.%s.%s\nrelease=true\n' \
  "$prev" "$bump" "$major" "$minor" "$patch"
