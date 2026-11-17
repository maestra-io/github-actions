#!/usr/bin/env bash
# The check-encoding action: every tracked file of the workspace with one of EXTENSIONS
# must be UTF-8 (ASCII included), through pr-checks/check-encoding.py. Env: COMMAND,
# EXTENSIONS, TARGET_ENCODING (the action inputs). Inputs the old image accepted but this
# check cannot honour fail loudly instead of passing silently.
set -euo pipefail
case "${COMMAND:-check}" in
	check) ;;
	fix) echo "::error::check-encoding: command 'fix' is not supported; convert the files listed by 'check' to UTF-8 in the repository"; exit 1 ;;
	*) echo "::error::check-encoding: unknown command '${COMMAND}' (check)"; exit 1 ;;
esac
# The check accepts exactly UTF-8 (ASCII is a subset): the list must name utf-8 and
# nothing but ASCII besides it (an ASCII-only list would be a stricter check).
utf8=0
IFS=, read -r -a encodings <<< "${TARGET_ENCODING:-utf-8,ASCII}"
for e in "${encodings[@]}"; do
	e=$(tr -d '[:space:]' <<< "$e" | tr '[:upper:]' '[:lower:]')
	case "$e" in
		utf-8|utf8) utf8=1 ;;
		ascii|us-ascii|'') ;;
		*) echo "::error::check-encoding: target_encoding '$e' is not supported: the check accepts UTF-8 (ASCII included) only"; exit 1 ;;
	esac
done
[ "$utf8" = 1 ] || { echo "::error::check-encoding: target_encoding '${TARGET_ENCODING}' must include utf-8"; exit 1; }
cd "${GITHUB_WORKSPACE:-$PWD}"
exec python3 -I "${BASH_SOURCE[0]%/*}/../pr-checks/check-encoding.py" "${EXTENSIONS:-txt,xml,json,config,cs,csproj,sln}"
