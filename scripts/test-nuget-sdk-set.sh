#!/usr/bin/env bash
# Self-check for the "pick .NET SDKs" program inlined in nuget-package-publish.yml
# (a reusable workflow cannot read this repository's files, so the test runs the
# workflow's own copy): TFMs from csproj/props in any layout, scoped to the
# solution's directory plus Directory.Build.* above it, bin/obj ignored,
# netstandard/netfx ignored, explicit override wins.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/nuget-package-publish.yml"
prog=$(sed -n '/# sdk-set: begin/,/# sdk-set: end/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "sdk-set program not found in $wf"; exit 1; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT

run() { # $1 = repo dir, $2 = override, $3 = solution-file; prints the versions output
  : > "$d/out"
  (cd "$1" && OVERRIDE="$2" SOLUTION="${3:-}" GITHUB_OUTPUT="$d/out" bash -eo pipefail -c "$prog" >/dev/null)
  sed -n '/^versions<<SDK_SET_EOF$/,/^SDK_SET_EOF$/p' "$d/out" | sed '1d;$d'
}
check() { # $1 = name, $2 = want, $3 = got
  [ "$2" = "$3" ] || { printf '%s: want [%s] got [%s]\n' "$1" "$2" "$3"; exit 1; }
}

r="$d/repo"; mkdir -p "$r/src/Lib" "$r/src/Tests" "$r/src/Win" "$r/src/Lib/bin/Release" "$r/obj"
printf '<Project><PropertyGroup>\r\n<TargetFramework>net8.0</TargetFramework>\r\n</PropertyGroup></Project>\r\n' > "$r/Directory.Build.props"
cat > "$r/src/Lib/Lib.csproj" <<'X'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
  <TargetFrameworks>netstandard2.0; net6.0 ;net10.0</TargetFrameworks>
</PropertyGroup></Project>
X
cat > "$r/src/Tests/Tests.csproj" <<'X'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>
  <TargetFramework Condition="'$(X)' == ''">net9.0</TargetFramework>
  <TargetFrameworks>
    net11.0;
    net8.0
  </TargetFrameworks>
</PropertyGroup></Project>
X
echo '<Project><PropertyGroup><TargetFrameworks>net48;net8.0-windows</TargetFrameworks></PropertyGroup></Project>' > "$r/src/Win/Win.fsproj"
echo '<Project><PropertyGroup><TargetFramework>net7.0</TargetFramework></PropertyGroup></Project>' > "$r/src/Lib/bin/Release/Stale.csproj"
echo '<Project><PropertyGroup><TargetFramework>net5.0</TargetFramework></PropertyGroup></Project>' > "$r/obj/Stale.props"

check "mixed TFMs" $'6.0.x\n8.0.x\n9.0.x\n10.0.x\n11.0.x' "$(run "$r" "")"
# Scoped to the solution's tree + Directory.Build.* above it: src/Tests (9, 11, 8)
# and src/Win are outside src/Lib.
check "solution scope" $'6.0.x\n8.0.x\n10.0.x' "$(run "$r" "" src/Lib/Lib.sln)"
check "override" $'7.0.x\n9.0.100' "$(run "$r" $'7.0.x\n9.0.100')"
mkdir "$d/none"; check "no projects" "" "$(run "$d/none" "")"
gj() { grep -x 'global-json=.*' "$d/out" | cut -d= -f2; }

# global.json with rollForward and a version setup-dotnet calls partial ("10.0.0"):
# its major joins the set and the file is not handed to setup-dotnet.
g="$d/gj"; mkdir -p "$g/src"
echo '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' > "$g/src/A.csproj"
echo '{"sdk":{"version":"10.0.0","rollForward":"latestFeature"}}' > "$g/global.json"
check "partial global.json version" $'8.0.x\n10.0.x' "$(run "$g" "")"; check "partial global.json skipped" false "$(gj)"
echo '{"sdk":{"version":"8.0.100","rollForward":"latestMajor"}}' > "$g/global.json"
check "full global.json version" '8.0.x' "$(run "$g" "")"; check "full global.json passed" true "$(gj)"
echo '{"sdk":{"version":"10.0.0"}}' > "$g/global.json"
check "no rollForward" '8.0.x' "$(run "$g" "")"; check "no rollForward passed" true "$(gj)"
echo '{"sdk":{"version":"10.0.100-rc.1.25451.107","rollForward":"latestMajor"}}' > "$g/global.json"
check "prerelease" '8.0.x' "$(run "$g" "")"; check "prerelease passed" true "$(gj)"
echo "nuget-sdk-set: OK"
