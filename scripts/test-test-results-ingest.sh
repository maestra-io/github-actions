#!/usr/bin/env bash
# Converter self-check: the two fixtures under test-results-ingest/testdata
# must yield 8 rows, 2 failed with a failure_hash, 2 skipped, and the GitHub context on each row.
set -euo pipefail
cd "$(dirname "$0")/.."
act=test-results-ingest
rows=$(GITHUB_HEAD_REF= GITHUB_REPOSITORY=maestra-io/x GITHUB_WORKFLOW=w GITHUB_JOB=j TEST_RESULTS_JOB_SUFFIX=-leg GITHUB_RUN_ID=1 \
  GITHUB_RUN_ATTEMPT=2 GITHUB_SHA=abc GITHUB_REF_NAME=main GITHUB_EVENT_NAME=push \
  python3 -I "$act/test-results-to-jsonl.py" "$act/testdata" 2>/dev/null)
n=$(wc -l <<<"$rows" | tr -d ' ')
failed=$(jq -r 'select(.outcome=="failed") | .failure_hash' <<<"$rows" | grep -c '^[0-9a-f]\{16\}$' || true)
skipped=$(jq -r 'select(.outcome=="skipped") | .test_id' <<<"$rows" | wc -l | tr -d ' ')
ctx=$(jq -r 'select(.repo=="maestra-io/x" and .job=="j-leg" and .run_attempt=="2" and .sha=="abc" and .branch=="main") | .test_id' <<<"$rows" | wc -l | tr -d ' ')
times=$(jq -r '._time' <<<"$rows" | grep -c '^20[0-9][0-9]-' || true)
echo "rows=$n failed_with_hash=$failed skipped=$skipped with_context=$ctx with_time=$times"
[ "$n" = 8 ] && [ "$failed" = 2 ] && [ "$skipped" = 2 ] && [ "$ctx" = 8 ] && [ "$times" = 8 ] || { echo "FAIL"; exit 1; }
echo OK
