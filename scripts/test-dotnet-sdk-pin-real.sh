#!/usr/bin/env bash
# Real-SDK check of the build SDK pin in dotnet-service-build.yml (test job), on the
# runner image's own SDKs: a net10.0 repo whose global.json says 10.0.100 with
# rollForward latestMajor must build with SDK 10, even when the image also ships a
# newer major (RunsOn ubuntu24-full added SDK 11 on 17.11.2026 and event-logs failed
# CA1860 under it). The SDK is read the way the build reads it: MSBuild's
# NETCoreSdkVersion of the project.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
block() { sed -n "/# $1: begin/,/# $1: end/p" "$wf" | sed 's/^          //'; }
set_prog=$(block sdk-set); pin_prog=$(block sdk-pin)
[ -n "$set_prog" ] && [ -n "$pin_prog" ] || { echo "sdk-set/sdk-pin not found in $wf"; exit 1; }
command -v dotnet >/dev/null || { echo "FAIL: no dotnet on this runner"; exit 1; }
dotnet --list-sdks
dotnet --list-sdks | grep -q '^10\.' || { echo "FAIL: the runner image has no SDK 10 to pin to"; exit 1; }

d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir "$d/w"
echo '{"sdk":{"version":"10.0.100","rollForward":"latestMajor"}}' > "$d/w/global.json"
printf '%s\n' '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>' > "$d/w/x.csproj"
sdk_of_build() { (cd "$d/w" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet msbuild x.csproj -getProperty:NETCoreSdkVersion); }

before=$(sdk_of_build)
: > "$d/out"
(cd "$d/w" && OVERRIDE="" SOLUTION="" GITHUB_OUTPUT="$d/out" bash -eo pipefail -c "$set_prog") >/dev/null
versions=$(sed -n '/^versions<<SDK_SET_EOF$/,/^SDK_SET_EOF$/p' "$d/out" | sed '1d;$d')
(cd "$d/w" && VERSIONS="$versions" BACKUP="$d/backup" GITHUB_OUTPUT="$d/out" bash -eo pipefail -c "$pin_prog")
pinned=$(jq -r .sdk.version "$d/w/global.json")
after=$(sdk_of_build)
echo "unpinned build SDK $before, pinned $pinned, build SDK $after"
[ "${after%%.*}" = 10 ] || { echo "FAIL: build SDK major ${after%%.*}, want 10"; exit 1; }
[ "$after" = "$pinned" ] || { echo "FAIL: build SDK $after is not the pinned $pinned"; exit 1; }
echo "dotnet-sdk-pin-real: OK"
