#!/usr/bin/env bash
# Tests for the selftest-changes block of selftest.yml: on a PR the heavy blocks of the `shell`
# job (docker_cache: the docker cache e2e, dotnet_sdk: the real SDKs) run only when the PR changes
# what they read; a push, an empty diff or a missing base parent runs both (fail open).
# The drift guard reads the gated steps from the workflow itself: every action a gated step uses,
# every script it runs and every "$here/..." file those scripts read must turn that block on, so
# a new input of a heavy test cannot be skipped silently.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
wf="$root/.github/workflows/selftest.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

sed -n '/# >>> selftest-changes/,/# <<< selftest-changes/p' "$wf" | sed 's/^          //' > "$work/block.sh"
[ -s "$work/block.sh" ] || { echo "FAIL no selftest-changes block in $wf"; exit 1; }

# run <event> <commits: 1 = the files in the only commit, 2 = a base commit and a change commit> files...
# -> "docker_cache=<v> dotnet_sdk=<v>"
run() {
	local event=$1 commits=$2; shift 2
	rm -rf "$work/repo"; mkdir "$work/repo"
	(
		cd "$work/repo"
		git init -q . && git config user.email t@t && git config user.name t
		if [ "$commits" = 2 ]; then echo base > README.md; git add . && git commit -qm base; fi
		for f in "$@"; do mkdir -p "$(dirname "$f")"; echo change >> "$f"; done
		git add -A && git commit -qm change --allow-empty
		: > "$work/out"
		EVENT=$event GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY=/dev/null bash "$work/block.sh" >/dev/null
	)
	printf 'docker_cache=%s dotnet_sdk=%s' "$(sed -n 's/^docker_cache=//p' "$work/out")" "$(sed -n 's/^dotnet_sdk=//p' "$work/out")"
}

case_() { # name event commits want files...
	local name=$1 event=$2 commits=$3 want=$4; shift 4
	local got; got=$(run "$event" "$commits" "$@")
	if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: $got, want $want"; fail=1; fi
}

both='docker_cache=true dotnet_sdk=true'; none='docker_cache=false dotnet_sdk=false'
dc='docker_cache=true dotnet_sdk=false'; sdk='docker_cache=false dotnet_sdk=true'

case_ "push runs both" push 2 "$both" test-results-ingest/action.yml
case_ "PR without a base parent runs both" pull_request 1 "$both" test-results-ingest/action.yml
case_ "PR with an empty diff runs both" pull_request 2 "$both"
case_ "PR on test-results-ingest only skips both" pull_request 2 "$none" \
	test-results-ingest/action.yml test-results-ingest/convert.py scripts/test-test-results-ingest.sh
case_ "PR on an unrelated workflow skips both" pull_request 2 "$none" .github/workflows/mcf-build.yml
case_ "selftest.yml runs both" pull_request 2 "$both" .github/workflows/selftest.yml
case_ "dotnet-service-build.yml runs both" pull_request 2 "$both" .github/workflows/dotnet-service-build.yml
case_ "service-build.yml runs the docker cache e2e" pull_request 2 "$dc" .github/workflows/service-build.yml
case_ "dotnet-nora runs the real SDKs" pull_request 2 "$sdk" dotnet-nora/dotnet-nora.sh
case_ "a lookalike path does not match" pull_request 2 "$none" docs/dotnet-nora/README.md scripts/nuget-secret-mount-fix.sh.bak
case_ "one matching file among others" pull_request 2 "$sdk" README.md ci/fixtures/dotnet-test/Tests/Tests.csproj

# Drift guard. gated: "<flag> <action dir or script>" for every gated step of the workflow.
awk '
	function flush() { if (flag != "") for (i = 1; i <= n; i++) print flag, ref[i]; flag = ""; n = 0 }
	/^      - / { flush() }
	match($0, /steps\.changes\.outputs\.[a-z_]+/) { flag = substr($0, RSTART + 22, RLENGTH - 22) }
	match($0, /uses: \.\/[^ ]+/) { ref[++n] = substr($0, RSTART + 8, RLENGTH - 8) }
	match($0, /run: bash scripts\/[^ ]+/) { ref[++n] = substr($0, RSTART + 10, RLENGTH - 10) }
	END { flush() }
' "$wf" | sort -u > "$work/gated"
for flag in docker_cache dotnet_sdk; do
	grep -q "^$flag scripts/" "$work/gated" || { echo "FAIL no gated script for $flag found in $wf"; fail=1; }
done

# inputs: "<flag> <repo path>": the gated refs, plus the "$here/..." paths their scripts read
while read -r flag ref; do
	echo "$flag $ref"
	case "$ref" in
		scripts/*)
			# $here is scripts/: "$here/../x" is x, "$here/x" is scripts/x (a literal $here: SC2016)
			# shellcheck disable=SC2016
			{ grep -oE '"\$here/[^"$]+"' "$root/$ref" || true; } | sed 's/^"\$here\///; s/"$//' \
				| awk -v flag="$flag" '{ if (!sub(/^\.\.\//, "")) $0 = "scripts/" $0; print flag, $0 }' ;;
	esac
done < "$work/gated" | sort -u > "$work/inputs"

checked=0
while read -r flag path; do
	[ -e "$root/$path" ] || { echo "FAIL $path (read by a $flag step) does not exist"; fail=1; continue; }
	f=$path; [ -d "$root/$path" ] && f="$path/any.file"
	got=$(run pull_request 2 "$f")
	case " $got " in
		*" $flag=true "*) checked=$((checked + 1)) ;;
		*) echo "FAIL $f is read by a $flag step but leaves it off ($got)"; fail=1 ;;
	esac
done < "$work/inputs"
echo "ok   drift guard: $checked inputs of the gated steps turn their block on"
[ "$checked" -ge 8 ] || { echo "FAIL the drift guard found only $checked inputs"; fail=1; }

exit "$fail"
