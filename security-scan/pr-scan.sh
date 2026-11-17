#!/usr/bin/env bash
# pr-scan.sh <gitleaks|trivy|opengrep>: the pull_request mode of security-scan.yml. Fails only
# on findings the PR INTRODUCES; findings already on the base branch never block a PR.
#
# Runs in the checkout of the PR's merge commit (what actions/checkout checks out on
# pull_request): HEAD is the merge, its first parent HEAD^1 the base it merges into.
#
#   gitleaks  `gitleaks git` over HEAD^1..HEAD: the PR's commits (their added lines), with the
#             central config, redacted. Needs the history down to the merge base (fetch-depth 0).
#   opengrep  `opengrep scan --baseline-commit HEAD^1`: only the files the PR changes are
#             scanned, and a match whose (rule id, path, matched lines) also matches at HEAD^1 is
#             dropped, so a finding moved by unrelated edits stays out (opengrep Diff_scan).
#   trivy     `trivy fs` of HEAD; when it has findings, `trivy fs` of HEAD^1 too (a git
#             worktree, DB not re-downloaded), and only the head findings whose key is not in
#             the base fail: vulnerability = (target, package, advisory id), secret = (target,
#             rule, redacted matched line). An old CVE never fails a PR; a bump into a new
#             HIGH/CRITICAL advisory or a newly added lockfile does. Skipping the base scan
#             when the head has no findings is exact: the difference is empty either way.
#
# Accepted findings as in the full scan: .gitleaksignore / gitleaks:allow, .trivyignore,
# nosemgrep. Env: GITLEAKS + GITLEAKS_CONFIG | TRIVY | OPENGREP + OPENGREP_RULES; OUT, a
# directory for the JSON reports (default: a temp dir). Exit 0 clean, 1 new findings, 2 broken.
set -euo pipefail
tool=${1:?usage: pr-scan.sh <gitleaks|trivy|opengrep>}
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$(mktemp -d)}
base=$(git rev-parse --verify -q 'HEAD^1') || { echo "pr-scan: HEAD has no parent commit: not a PR merge checkout" >&2; exit 2; }
echo "pr-scan $tool: base $base, head $(git rev-parse HEAD)"

case "$tool" in
gitleaks)
  # gitleaks exits 0 on a range git cannot resolve: resolve it first.
  n=$(git rev-list --count "$base..HEAD") || { echo "pr-scan: cannot list $base..HEAD (shallow clone?)" >&2; exit 2; }
  echo "scanning the $n commits of $base..HEAD"
  rc=0
  "${GITLEAKS:?}" git --no-banner --config "${GITLEAKS_CONFIG:?}" --log-opts="$base..HEAD" \
    --redact=100 --verbose --exit-code 1 . || rc=$?
  [ "$rc" -le 1 ] || exit 2
  exit "$rc" ;;

opengrep)
  rc=0
  "${OPENGREP:?}" scan --config "${OPENGREP_RULES:?}" --severity=ERROR --taint-intrafile \
    --no-rewrite-rule-ids --error --baseline-commit "$base" \
    --json-output="$OUT/opengrep.json" . || rc=$?
  [ "$rc" -le 1 ] || exit 2
  exit "$rc" ;;

trivy)
  "${TRIVY:?}" fs --severity HIGH,CRITICAL --exit-code 0 --format json --output "$OUT/trivy-head.json" .
  if ! python3 "$here/pr-diff.py" any "$OUT/trivy-head.json"; then
    echo "no HIGH/CRITICAL findings at head: nothing the PR could introduce"; exit 0
  fi
  wt=$(mktemp -d)/base
  git worktree add -q --detach "$wt" "$base"
  ( cd "$wt" && "$TRIVY" fs --severity HIGH,CRITICAL --exit-code 0 --skip-db-update --skip-java-db-update \
      --format json --output "$OUT/trivy-base.json" . )
  git worktree remove --force "$wt"
  python3 "$here/pr-diff.py" trivy "$OUT/trivy-base.json" "$OUT/trivy-head.json" ;;

*) echo "pr-scan: unknown tool $tool" >&2; exit 2 ;;
esac
