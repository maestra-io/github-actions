#!/usr/bin/env bash
#
# Self-check for the packages token in dotnet-service-build.yml (and the layer-cache
# copy in service-build.yml). A BuildKit secret's value is not part of the layer cache
# key, so a GitLab-era Dockerfile that writes the token into NuGet.Config gets that
# layer replayed by the cache after the token expired, and the first later RUN that
# restores (publish -r <rid>: runtime packs) fails 401 (maestra-io/billing). Checks:
#   1. layer-cache: such a Dockerfile builds without the cache, a clean one with it;
#   2. token-files: the secret files carry the override / a minted token in NuGet's
#      env-credential format and are re-minted in the background;
#   3. end to end (docker, a fake feed that accepts only the CURRENT token): the
#      GitLab-era Dockerfile with the cache fails exactly like billing did, without
#      the cache it passes; after scripts/nuget-secret-mount-fix.sh it passes WITH the
#      cache (restore layer reused) and no layer holds a token; with its NuGet cache
#      mount a rebuild fetches no package, an empty mount fetches them with the current token;
#   4. nuget-mount-seed/extract (docker, two new builders = two fresh test runners): the
#      NuGet cache mount copied out of one builder and into the other leaves the second
#      build nothing to fetch; an empty mount is not saved.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/dotnet-service-build.yml"
sb="$here/../.github/workflows/service-build.yml"
fx="$here/../ci/fixtures/nuget-token-cache"
block() { sed -n "/# >>> $1/,/# <<< $1/p" "$2" | sed 's/^          //'; }
first() { awk -v b="# >>> $1" -v e="# <<< $1" 'index($0,b){n++} n==1{print} n==1&&index($0,e){exit}' "$2" | sed 's/^          //'; }
cache=$(first layer-cache "$wf"); files=$(first token-files "$wf")
[ -n "$cache" ] && [ -n "$files" ] || { echo "layer-cache/token-files block not found in $wf"; exit 1; }
# Every copy is the same code: <name> <file> <expected copies>
same() {
  local n; n=$(grep -c "# >>> $1" "$2")
  [ "$n" -eq "$3" ] || { echo "FAIL $1: $n copies in $2, want $3"; exit 1; }
  [ "$(block "$1" "$2")" = "$(for _ in $(seq 1 "$n"); do printf '%s\n' "$(first "$1" "$wf")"; done)" ] \
    || { echo "FAIL $1 copies differ in $2"; exit 1; }
}
same layer-cache "$wf" 4   # test, test base-image, images base-image, images
same layer-cache "$sb" 2
same token-files "$wf" 2

work=$(mktemp -d)
feed=""
builders=()
cleanup() {
  [ -z "$feed" ] || kill "$feed" 2>/dev/null || true
  for b in "${builders[@]}"; do docker buildx rm -f "$b" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT
eq() { [ "$1" = "$2" ] || { printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; exit 1; }; }

# ── 1. layer-cache ─────────────────────────────────────────────────────────────
# cache_for <dockerfile> <scopes> -> "<from lines joined by ' '>|<to>"
# docker stub: `buildx du` lists the nuget cache mount when DU_NUGET is set.
mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_ARGS"
[ -z "${DU_NUGET:-}" ] || echo 'Description:  cached mount /root/.nuget/packages from exec /bin/sh -c dotnet restore with id "/nuget"'
D
chmod +x "$work/bin/docker"
cache_for() {
  : > "$work/out"
  PATH="$work/bin:$PATH" DOCKER_ARGS="$work/docker.args" DOCKERFILE="$1" SCOPES="$2" GITHUB_OUTPUT="$work/out" bash -c "set -eo pipefail; $cache" >/dev/null
  from=$(awk '/^from<</{f=1;next} /^__CACHE__$/{f=0} f' "$work/out" | paste -sd' ' -)
  echo "${from}|$(sed -n 's/^to=//p' "$work/out")"
}
"$here/nuget-secret-mount-fix.sh" "$(cp "$fx/Dockerfile.gitlab" "$work/Dockerfile.fixed" && echo "$work/Dockerfile.fixed")" >/dev/null
nc='--mount=type=cache,id=nuget,target=/root/.nuget/packages,sharing=locked'
for r in 'dotnet restore App.csproj' 'dotnet build App.csproj -c Release --no-restore' 'dotnet publish'; do
  grep -qF -- "RUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private $nc $r" "$work/Dockerfile.fixed" \
    || { cat "$work/Dockerfile.fixed"; echo "FAIL nuget-secret-mount-fix: no secret + cache mount on '$r'"; exit 1; }
done
eq "$("$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.fixed")" "unchanged: $work/Dockerfile.fixed" "nuget-secret-mount-fix idempotent"
printf 'FROM sdk\r\nRUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN dotnet nuget update source maestra --username ci --password $(cat /run/secrets/PRIVATE_PACKAGES_TOKEN) --store-password-in-clear-text\r\nRUN dotnet restore && dotnet test --no-build\r\n' > "$work/Dockerfile.crlf"
"$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.crlf" >/dev/null
eq "$(cat "$work/Dockerfile.crlf")" "$(printf 'FROM sdk\r\nRUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_maestra %s dotnet restore && dotnet test --no-build\r\n' "$nc")" "nuget-secret-mount-fix: other source name, CRLF kept"
printf 'FROM sdk\nRUN --mount=type=secret,id=T dotnet nuget update source private --password $(cat /run/secrets/T) && dotnet restore\n' > "$work/Dockerfile.chained"
cp "$work/Dockerfile.chained" "$work/Dockerfile.chained.orig"
"$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.chained" | grep -q 'fix by hand' || { echo "FAIL nuget-secret-mount-fix: chained credential RUN not reported"; exit 1; }
cmp -s "$work/Dockerfile.chained" "$work/Dockerfile.chained.orig" || { echo "FAIL nuget-secret-mount-fix: chained credential RUN changed"; exit 1; }
# converted before #124 (api-mimic): the --no-restore build ran unmounted, the SDK workload check sent an empty Basic
printf 'FROM sdk\nRUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private dotnet restore\nRUN dotnet build -c Release --no-restore\nRUN ls\n' > "$work/Dockerfile.pre124"
"$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.pre124" >/dev/null
eq "$(cat "$work/Dockerfile.pre124")" "$(printf 'FROM sdk\nRUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private %s dotnet restore\nRUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private %s dotnet build -c Release --no-restore\nRUN ls' "$nc" "$nc")" "nuget-secret-mount-fix: pre-#124 Dockerfile upgraded"
eq "$("$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.pre124")" "unchanged: $work/Dockerfile.pre124" "nuget-secret-mount-fix: pre-#124 upgrade idempotent"
printf 'FROM sdk\n# RUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private dotnet restore\nRUN dotnet build\n' > "$work/Dockerfile.nofeed"
eq "$("$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.nofeed")" "unchanged: $work/Dockerfile.nofeed" "nuget-secret-mount-fix: no credential anywhere, untouched"
# NuGet cache mount: <name> <Dockerfile> <expected> ('' = untouched, a `fix by hand` line)
S='--mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private'
cm() { printf -- '--mount=type=cache,id=nuget,target=%s,sharing=locked' "$1"; }
mkdir -p "$work/ctx-cm"  # the build context the script reads project files from
cachecase() {  # a literal \r in <Dockerfile>/<expected> is a CR
  set -- "$1" "${2//\\r/$'\r'}" "${3//\\r/$'\r'}"
  printf '%s' "$2" > "$work/Dockerfile.cm"; cp "$work/Dockerfile.cm" "$work/Dockerfile.cm.orig"
  out=$(cd "$work/ctx-cm" && "$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.cm")
  if [ -z "$3" ]; then
    grep -q 'fix by hand' <<<"$out" || { echo "$out"; echo "FAIL cache mount $1: not reported"; exit 1; }
    cmp -s "$work/Dockerfile.cm" "$work/Dockerfile.cm.orig" || { cat "$work/Dockerfile.cm"; echo "FAIL cache mount $1: changed"; exit 1; }
  else
    eq "$(cat "$work/Dockerfile.cm")" "$3" "cache mount $1"
    eq "$(cd "$work/ctx-cm" && "$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.cm")" "unchanged: $work/Dockerfile.cm" "cache mount $1: idempotent"
  fi
}
# converted earlier (api-mimic): secret mounts only, the publish stage inherits the folder
cachecase secret-mounted "FROM sdk AS build
RUN $S dotnet restore
COPY . .
RUN $S dotnet build -c Release --no-restore
FROM build AS publish
RUN $S dotnet publish -o /dist --no-restore
FROM aspnet
COPY --from=publish /dist .
ENTRYPOINT [\"dotnet\", \"App.dll\"]
" "FROM sdk AS build
RUN $S $(cm /root/.nuget/packages) dotnet restore
COPY . .
RUN $S $(cm /root/.nuget/packages) dotnet build -c Release --no-restore
FROM build AS publish
RUN $S $(cm /root/.nuget/packages) dotnet publish -o /dist --no-restore
FROM aspnet
COPY --from=publish /dist .
ENTRYPOINT [\"dotnet\", \"App.dll\"]"
# DirectCRM: --packages from an ARG default
cachecase arg-packages "FROM sdk
ARG PackagesPath=/root/.nuget/packages
RUN $S dotnet restore ./a.csproj --packages \$PackagesPath
RUN $S dotnet publish ./a.csproj -o /dist --no-restore
" "FROM sdk
ARG PackagesPath=/root/.nuget/packages
RUN $S $(cm /root/.nuget/packages) dotnet restore ./a.csproj --packages \$PackagesPath
RUN $S $(cm /root/.nuget/packages) dotnet publish ./a.csproj -o /dist --no-restore"
cachecase nuget-packages-env "FROM sdk
ENV NUGET_PACKAGES=/nuget
RUN $S dotnet restore
RUN $S dotnet build --no-restore
" "FROM sdk
ENV NUGET_PACKAGES=/nuget
RUN $S $(cm /nuget) dotnet restore
RUN $S $(cm /nuget) dotnet build --no-restore"
# messaging: relative --packages against WORKDIR; the --no-restore RUNs read the same folder
cachecase relative-packages "FROM sdk AS build
WORKDIR /sln
RUN $S dotnet restore \"M.sln\" --packages .nuget
COPY . .
RUN $S dotnet build \"M.sln\" -c Release --no-restore
FROM build AS publish
RUN $S dotnet publish src/A/A.csproj -c Release -o /dist --no-restore
" "FROM sdk AS build
WORKDIR /sln
RUN $S $(cm /sln/.nuget) dotnet restore \"M.sln\" --packages .nuget
COPY . .
RUN $S $(cm /sln/.nuget) dotnet build \"M.sln\" -c Release --no-restore
FROM build AS publish
RUN $S $(cm /sln/.nuget) dotnet publish src/A/A.csproj -c Release -o /dist --no-restore"
# kraken: publish restores into -p:RestorePackagesPath (CLI property wins like --packages)
cachecase restore-packages-path "FROM sdk AS build
ARG P=/nuget
RUN $S dotnet publish src/A/A.csproj -c Release -p:RestorePackagesPath=/sln/.nuget -o /dist
FROM sdk AS b
ARG P=/nuget
RUN $S dotnet restore /p:Foo=1;RestorePackagesPath=\$P
RUN $S dotnet build --no-restore
" "FROM sdk AS build
ARG P=/nuget
RUN $S $(cm /sln/.nuget) dotnet publish src/A/A.csproj -c Release -p:RestorePackagesPath=/sln/.nuget -o /dist
FROM sdk AS b
ARG P=/nuget
RUN $S $(cm /nuget) dotnet restore /p:Foo=1;RestorePackagesPath=\$P
RUN $S $(cm /nuget) dotnet build --no-restore"
cachecase restore-packages-path-relative "FROM sdk
WORKDIR /sln
RUN $S dotnet restore --property:RestorePackagesPath=.nuget
" ""
cachecase two-packages-paths "FROM sdk
RUN $S dotnet restore --packages /a -p:RestorePackagesPath=/b
" ""
# <RestorePackagesPath> in a project file of the build context
printf '<Project><PropertyGroup><RestorePackagesPath>/sln/packages</RestorePackagesPath></PropertyGroup></Project>\n' > "$work/ctx-cm/Directory.Build.props"
cachecase props-literal "FROM sdk
RUN $S dotnet restore
RUN $S dotnet build --no-restore
" "FROM sdk
RUN $S $(cm /sln/packages) dotnet restore
RUN $S $(cm /sln/packages) dotnet build --no-restore"
cachecase props-cli-wins "FROM sdk
RUN $S dotnet restore --packages /p
" "FROM sdk
RUN $S $(cm /p) dotnet restore --packages /p"
printf '<Project><PropertyGroup><RestorePackagesPath>$(MSBuildThisFileDirectory)packages</RestorePackagesPath></PropertyGroup></Project>\n' > "$work/ctx-cm/Directory.Build.props"
cachecase props-msbuild-property "FROM sdk
RUN $S dotnet restore
" ""
mkdir -p "$work/ctx-cm/src/A"; printf '<Project><!-- <NUGET_PACKAGES>/x</NUGET_PACKAGES> --></Project>\n' > "$work/ctx-cm/src/A/A.csproj"
rm "$work/ctx-cm/Directory.Build.props"
cachecase props-commented-out "FROM sdk
RUN $S dotnet restore
" "FROM sdk
RUN $S $(cm /root/.nuget/packages) dotnet restore"
printf '<Project><PropertyGroup Condition="x"><NUGET_PACKAGES>/x</NUGET_PACKAGES></PropertyGroup></Project>\n' > "$work/ctx-cm/src/A/A.csproj"
cachecase props-conditional "FROM sdk
RUN $S dotnet restore
" ""
printf '<Project><Choose><When Condition="x"><PropertyGroup><RestorePackagesPath>/x</RestorePackagesPath></PropertyGroup></When></Choose></Project>\n' > "$work/ctx-cm/src/A/A.csproj"
cachecase props-choose-when "FROM sdk
RUN $S dotnet restore
" ""
rm -r "$work/ctx-cm/src"
cachecase non-root-user "FROM sdk
USER app
RUN $S dotnet restore
" ""
cachecase unresolved-packages "FROM sdk
ARG PackagesPath
RUN $S dotnet restore --packages \$PackagesPath
" ""
# the template's tests stage: `dotnet test --no-build` at container start reads the packages
# from the image (without them it silently runs zero tests): copied out of the mount
# only the <id>/<version> folders of the stage's obj/project.assets.json, not the whole mount
cp_tpl=$(cat <<'T'
RUN --mount=type=cache,id=nuget,target=/tmp/nuget-cache,sharing=locked set -e; find / \( -path /proc -o -path /sys -o -path /tmp/nuget-cache -o -path /usr/share/dotnet -o -path @D@ \) -prune -o -path '*/obj/project.assets.json' -print > /tmp/nuget-assets; [ -s /tmp/nuget-assets ] || { echo 'no obj/project.assets.json: no NuGet packages to copy' >&2; exit 1; }; while read -r f; do grep -q '"@D@/\{0,1\}"' "$f" || { echo "$f restores outside @D@" >&2; exit 1; }; done < /tmp/nuget-assets; while read -r f; do sed -n '/^ *"type": "package"/,/^ *"path": /s|^ *"path": "\([^"]*\)",*$|\1|p' "$f"; done < /tmp/nuget-assets | sort -u > /tmp/nuget-pkgs; while read -r p; do test -d "/tmp/nuget-cache/$p" || { echo "$p is not in the NuGet cache mount" >&2; exit 1; }; mkdir -p "@D@/$p"; cp -a "/tmp/nuget-cache/$p/." "@D@/$p/"; done < /tmp/nuget-pkgs; echo "copied $(wc -l < /tmp/nuget-pkgs) NuGet packages into @D@"; rm /tmp/nuget-assets /tmp/nuget-pkgs
T
)
cp_run() { printf '%s' "${cp_tpl//@D@/$1}"; }
# its package list: "type": "package" libraries only (a version may end in "proj"),
# also with "serviceable" between type and path; project references are skipped
sedexpr=${cp_tpl#*sed -n \'}; sedexpr=${sedexpr%%\' \"\$f\"*}
cat > "$work/project.assets.json" <<'J'
{
  "libraries": {
    "Example/1.0.0-proj": {
      "sha512": "x",
      "type": "package",
      "path": "example/1.0.0-proj",
      "files": [ "example.nuspec" ]
    },
    "Microsoft.Extensions.Logging/9.0.0": {
      "sha512": "x",
      "type": "package",
      "serviceable": true,
      "path": "microsoft.extensions.logging/9.0.0",
      "files": [ "lib/net9.0/Microsoft.Extensions.Logging.dll" ]
    },
    "Lib/1.0.0": {
      "type": "project",
      "path": "../Lib/Lib.csproj",
      "msbuildProject": "../Lib/Lib.csproj"
    }
  },
  "packageFolders": { "/root/.nuget/packages/": {} }
}
J
eq "$(sed -n "$sedexpr" "$work/project.assets.json" | sort -u | paste -sd' ' -)" "example/1.0.0-proj microsoft.extensions.logging/9.0.0" "runtime copy: package list from project.assets.json"
# "packageFolders" has no trailing slash when restore got `--packages .nuget` (segmentations)
grepexpr=${cp_tpl#*grep -q \'}; grepexpr=${grepexpr%%\' *}; grepexpr=${grepexpr//@D@//sln/.nuget}
for pf in '"/sln/.nuget/": {}' '"/sln/.nuget": {}'; do
  printf '  "packageFolders": {\n    %s\n' "$pf" > "$work/pf.json"
  grep -q "$grepexpr" "$work/pf.json" || { echo "FAIL runtime copy: packageFolders $pf not recognised"; exit 1; }
done
printf '  "packageFolders": {\n    "/root/.nuget/packages/": {}\n' > "$work/pf.json"
! grep -q "$grepexpr" "$work/pf.json" || { echo "FAIL runtime copy: another packages folder recognised"; exit 1; }
cachecase runtime-test "FROM sdk AS build
WORKDIR /sln
RUN $S dotnet restore
COPY . .
RUN $S dotnet build --no-restore
FROM build AS tests
WORKDIR /sln/src/Tests
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
FROM build AS publish
RUN $S dotnet publish -o /dist --no-restore
" "FROM sdk AS build
WORKDIR /sln
RUN $S $(cm /root/.nuget/packages) dotnet restore
COPY . .
RUN $S $(cm /root/.nuget/packages) dotnet build --no-restore
FROM build AS tests
WORKDIR /sln/src/Tests
$(cp_run /root/.nuget/packages)
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
FROM build AS publish
RUN $S $(cm /root/.nuget/packages) dotnet publish -o /dist --no-restore"
# one stage: the copy goes after its last dotnet RUN; relative --packages, CRLF kept
cachecase runtime-test-one-stage "FROM sdk\r
WORKDIR /sln\r
RUN $S dotnet restore --packages .nuget\r
RUN $S dotnet build --no-restore\r
CMD dotnet test --no-build\r
" "FROM sdk\r
WORKDIR /sln\r
RUN $S $(cm /sln/.nuget) dotnet restore --packages .nuget\r
RUN $S $(cm /sln/.nuget) dotnet build --no-restore\r
$(cp_run /sln/.nuget)\r
CMD dotnet test --no-build\r"
cachecase runtime-test-two-folders "FROM sdk AS build
RUN $S dotnet restore a.csproj --packages /a
RUN $S dotnet restore b.csproj --packages /b
FROM build AS tests
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
" ""
# PR 147's whole-mount copy is upgraded in place
old_cp() { printf 'RUN --mount=type=cache,id=nuget,target=/tmp/nuget-cache,sharing=locked mkdir -p %s && cp -a /tmp/nuget-cache/. %s/' "$1" "$1"; }
cachecase runtime-test-upgrade "FROM sdk AS build
RUN $S $(cm /root/.nuget/packages) dotnet restore
FROM build AS tests
$(old_cp /root/.nuget/packages)
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
" "FROM sdk AS build
RUN $S $(cm /root/.nuget/packages) dotnet restore
FROM build AS tests
$(cp_run /root/.nuget/packages)
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]"
# PR 149's copy (packageFolders with a trailing slash only) is upgraded in place, the current one is left alone
cachecase runtime-test-upgrade-149 "FROM sdk AS build
WORKDIR /sln
RUN $S $(cm /sln/.nuget) dotnet restore --packages .nuget
FROM build AS tests
$(t=${cp_tpl//'\{0,1\}'/}; printf '%s' "${t//@D@//sln/.nuget}")
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
" "FROM sdk AS build
WORKDIR /sln
RUN $S $(cm /sln/.nuget) dotnet restore --packages .nuget
FROM build AS tests
$(cp_run /sln/.nuget)
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]"
# a cache mount alone in a runtime stage is no package copy
cachecase runtime-test-mount-only "FROM sdk AS build
RUN $S dotnet restore
FROM build AS tests
RUN --mount=type=cache,id=nuget,target=/tmp/nuget-cache,sharing=locked ls /tmp/nuget-cache
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]
" "FROM sdk AS build
RUN $S $(cm /root/.nuget/packages) dotnet restore
FROM build AS tests
$(cp_run /root/.nuget/packages)
RUN --mount=type=cache,id=nuget,target=/tmp/nuget-cache,sharing=locked ls /tmp/nuget-cache
ENTRYPOINT [\"dotnet\", \"test\", \"--no-build\"]"
cachecase copy-from-packages "FROM sdk AS build
WORKDIR /sln
RUN $S dotnet restore --packages .nuget
FROM sdk
COPY --from=build /sln/.nuget /nuget
" ""
cachecase run-reads-packages "FROM sdk
RUN $S dotnet restore
RUN ls /root/.nuget/packages
" ""
cachecase bind-mounted "FROM sdk
WORKDIR /sln
RUN --mount=type=bind,source=.nuget,target=.nuget,rw=true $S dotnet restore --packages .nuget
" ""
# a fresh GitLab Dockerfile with a non-root stage: the token is fixed, the cache mount reported
printf 'FROM sdk\nUSER app\nRUN --mount=type=secret,id=T dotnet nuget update source private --password $(cat /run/secrets/T)\nRUN dotnet restore\n' > "$work/Dockerfile.user"
out=$("$here/nuget-secret-mount-fix.sh" "$work/Dockerfile.user")
grep -q 'USER app.*fix by hand' <<<"$out" && grep -q '^fixed: ' <<<"$out" || { echo "$out"; echo "FAIL non-root GitLab Dockerfile"; exit 1; }
eq "$(cat "$work/Dockerfile.user")" "$(printf 'FROM sdk\nUSER app\nRUN %s dotnet restore' "$S")" "non-root GitLab Dockerfile: secret mount, no cache mount"
sed 's/ --mount=type=cache[^ ]*//' "$work/Dockerfile.fixed" > "$work/Dockerfile.secretonly"
eq "$(cache_for "$fx/Dockerfile.gitlab" $'img\ntests')" "|" "GitLab-era Dockerfile: no cache"
eq "$(cache_for "$work/Dockerfile.secretonly" $'img\ntests')" "type=gha,scope=img type=gha,scope=tests|type=gha,mode=max,scope=img" "secret-mounted Dockerfile: cache"
eq "$(cache_for "$work/Dockerfile.secretonly" $'img\n')" "type=gha,scope=img|type=gha,mode=max,scope=img" "no docker-test-target"
eq "$(cache_for "$work/Dockerfile.secretonly" "tests")" "type=gha,scope=tests|type=gha,mode=max,scope=tests" "test job"
eq "$(cache_for "$work/Dockerfile.fixed" $'img\ntests')" "|" "NuGet cache mount: no gha cache (it never exports the mount, NETSDK1064)"
eq "$(sed -n 's/^nocache=//p' "$work/out")" "false" "NuGet cache mount without sticky disk: no --no-cache"
eq "$(STICKY=true cache_for "$work/Dockerfile.secretonly" $'img\ntests')" "|" "sticky disk: layers stay on the disk, no gha cache"
eq "$(sed -n 's/^nocache=//p' "$work/out")" "false" "sticky disk, secret-mounted Dockerfile: builder cache allowed"
: > "$work/docker.args"
eq "$(DU_NUGET=1 BUILDER=bk STICKY=true cache_for "$work/Dockerfile.fixed" img)" "|" "sticky disk with the NuGet cache mount"
eq "$(sed -n 's/^nocache=//p' "$work/out")" "false" "sticky disk, NuGet cache mount present: builder cache allowed"
grep -q -- '--builder bk' "$work/docker.args" || { cat "$work/docker.args"; echo "FAIL buildx du not asked on the sticky builder"; exit 1; }
eq "$(STICKY=true cache_for "$work/Dockerfile.fixed" img)" "|" "sticky disk without the NuGet cache mount"
eq "$(sed -n 's/^nocache=//p' "$work/out")" "true" "sticky disk, NuGet cache mount GC'd: --no-cache once"
eq "$(STICKY=true cache_for "$fx/Dockerfile.gitlab" img)" "|" "sticky disk, GitLab-era Dockerfile: no gha cache"
# --no-cache-filter on the token stage, not --no-cache: that would empty the NuGet cache mounts
eq "$(sed -n 's/^nocache=//p;s/^nocachefilter=/filter=/p' "$work/out" | paste -sd' ' -)" "false filter=build" "sticky disk, GitLab-era Dockerfile: the token stage re-runs"
printf 'FROM sdk AS base\nFROM base AS pdbuild\nRUN cp a b && dotnet nuget update source private --password x\nFROM sdk AS app\nRUN %s %s dotnet restore\n' "$S" "$nc" > "$work/Dockerfile.pushhub"
DU_NUGET=1 STICKY=true cache_for "$work/Dockerfile.pushhub" img >/dev/null
eq "$(sed -n 's/^nocache=//p;s/^nocachefilter=/filter=/p' "$work/out" | paste -sd' ' -)" "false filter=pdbuild" "sticky disk, token stage + NuGet cache mount elsewhere (PushHub)"
STICKY=true cache_for "$work/Dockerfile.pushhub" img >/dev/null
eq "$(sed -n 's/^nocache=//p;s/^nocachefilter=/filter=/p' "$work/out" | paste -sd' ' -)" "true filter=" "sticky disk, token stage + NuGet cache mount GC'd: --no-cache once"
printf 'FROM sdk AS build\nRUN dotnet nuget update source p --password x\nRUN %s dotnet restore\n' "$nc" > "$work/Dockerfile.tokmount"
DU_NUGET=1 STICKY=true cache_for "$work/Dockerfile.tokmount" img >/dev/null
eq "$(sed -n 's/^nocache=//p;s/^nocachefilter=/filter=/p' "$work/out" | paste -sd' ' -)" "true filter=" "sticky disk, token stage with its own NuGet cache mount: --no-cache"
for unnamed in 'FROM sdk\nRUN dotnet nuget update source p --password x\n' 'ARG NPM_TOKEN\nFROM node AS app\n'; do
  printf "$unnamed" > "$work/Dockerfile.unnamed"
  STICKY=true cache_for "$work/Dockerfile.unnamed" img >/dev/null
  eq "$(sed -n 's/^nocache=//p;s/^nocachefilter=/filter=/p' "$work/out" | paste -sd' ' -)" "true filter=" "sticky disk, token outside a named stage: --no-cache"
done
for persist in 'ARG PRIVATE_PACKAGES_TOKEN' \
               'RUN --mount=type=secret,id=T npm config set //packages.maestra.io/npm/:_authToken $(cat /run/secrets/T)' \
               'RUN --mount=type=secret,id=T poetry config http-basic.maestra token $(cat /run/secrets/T)' \
               '<add key="ClearTextPassword" value="x" />'; do
  printf 'FROM busybox\n%s\n' "$persist" > "$work/Dockerfile.p"
  eq "$(cache_for "$work/Dockerfile.p" img)" "|" "persists: $persist"
done
echo "ok layer-cache"

# ── 2. token-files ─────────────────────────────────────────────────────────────
tf="$work/rt/packages-token"
RUNNER_TEMP="$work/rt" OVERRIDE=tok-override AUDIENCE=aud bash -c "set -eo pipefail; $files"
eq "$(cat "$tf/PRIVATE_PACKAGES_TOKEN")" "tok-override" "override token file"
eq "$(cat "$tf/NUGET_CREDENTIALS")" "Username=ci;Password=tok-override" "override NuGet credentials"
mkdir -p "$work/bin"; echo 0 > "$work/n"
cat > "$work/bin/curl" <<'C'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_N") + 1 )); echo "$n" > "$CURL_N"; printf '%s\n' "$*" >> "$CURL_N.args"
[ -z "${CURL_FAIL:-}" ] || exit 22
printf '{"count":1,"value":"tok-%s"}' "$n"
C
chmod +x "$work/bin/curl"
# The background loop stops after the 3rd mint (sleep is stubbed).
PATH="$work/bin:$PATH" CURL_N="$work/n" RUNNER_TEMP="$work/rt2" OVERRIDE="" AUDIENCE=packages.example \
  ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/x?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
  bash -c "set -eo pipefail; sleep() { command sleep 0.1; [ \"\$(cat \"\$CURL_N\")\" -lt 3 ]; }; $files"
for _ in $(seq 1 50); do [ "$(cat "$work/n")" -ge 3 ] && break; command sleep 0.1; done
command sleep 0.3
eq "$(cat "$work/rt2/packages-token/NUGET_CREDENTIALS")" "Username=ci;Password=tok-3" "re-minted NuGet credentials"
eq "$(cat "$work/rt2/packages-token/PRIVATE_PACKAGES_TOKEN")" "tok-3" "re-minted token"
grep -q 'https://token.example/x?api-version=2.0&audience=packages.example' "$work/n.args" || { cat "$work/n.args"; echo "FAIL audience not requested"; exit 1; }
if PATH="$work/bin:$PATH" CURL_N="$work/n" CURL_FAIL=1 RUNNER_TEMP="$work/rt3" OVERRIDE="" AUDIENCE=a \
     ACTIONS_ID_TOKEN_REQUEST_URL="https://x/?a=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
     bash -c "set -eo pipefail; $files" >/dev/null 2>&1; then
  echo "FAIL token-files: a failed mint passed"; exit 1
fi
echo "ok token-files"

# ── 3. end to end ──────────────────────────────────────────────────────────────
port=18737
cp -R "$fx/." "$work/ctx/" 2>/dev/null || { mkdir -p "$work/ctx"; cp -R "$fx/." "$work/ctx/"; }
# Unique per invocation: the daemon keeps the layer cache and cache mounts of earlier invocations.
nonce="$$-$RANDOM"; A="tok-A-$nonce"; B="tok-B-$nonce"
sed "s/id=nuget,/id=nuget-$nonce,/" "$work/Dockerfile.fixed" > "$work/ctx/Dockerfile.fixed"
echo "$A" > "$work/token"
echo "<!-- $nonce -->" >> "$work/ctx/nuget.config" # and a layer chain of its own: no earlier token to replay
python3 -I "$fx/feed.py" "$port" "$work/token" "$work/feed.log" & feed=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; command sleep 0.1; done

# token <value>: the workflow's token files hold this token, and the feed accepts only it.
token() { echo "$1" > "$work/token"; RUNNER_TEMP="$work/e2e" OVERRIDE="$1" AUDIENCE=a bash -c "set -eo pipefail; $files"; }
# build <dockerfile> [docker flags]: a new commit (Program.cs changes), target publish.
build() {
  local df="$1"; shift
  echo "// $RANDOM$RANDOM" >> "$work/ctx/App/Program.cs"
  : > "$work/feed.log"
  docker buildx build --progress plain --load "$@" \
    --add-host host.docker.internal:host-gateway \
    --secret "id=PRIVATE_PACKAGES_TOKEN,src=$work/e2e/packages-token/PRIVATE_PACKAGES_TOKEN" \
    --secret "id=NUGET_CREDENTIALS,src=$work/e2e/packages-token/NUGET_CREDENTIALS" \
    -f "$work/ctx/$df" --target publish -t "local/selftest-token-cache:${df##*.}" "$work/ctx" >"$work/build.log" 2>&1
}
must() { build "$@" || { grep -E "error|401|CACHED|DONE" "$work/build.log" | tail -40; cat "$work/feed.log"; echo "FAIL build $*"; exit 1; }; }
leaks() { docker run --rm --entrypoint sh "local/selftest-token-cache:$1" -c "grep -rlE '$A|$B' /sln /root/.nuget/NuGet 2>/dev/null || true"; }

# GitLab-era: run 1 seeds the cache (token A), run 2 (token B, A has expired) reuses
# the NuGet.Config layer with A; publish restores Selftest.Publish -> 401.
token "$A"; must Dockerfile.gitlab
token "$B"
if build Dockerfile.gitlab; then tail -40 "$work/build.log"; echo "FAIL GitLab-era Dockerfile with the cache passed: the e2e no longer reproduces the expired-token replay"; exit 1; fi
grep -q '^401 .*selftest.publish' "$work/feed.log" || { tail -40 "$work/build.log"; cat "$work/feed.log"; echo "FAIL GitLab-era: no 401 on the publish restore"; exit 1; }
echo "ok GitLab-era Dockerfile + layer cache: publish restore 401 with the replayed token"
must Dockerfile.gitlab --no-cache
[ -n "$(leaks gitlab)" ] || { echo "FAIL leak check finds nothing in the GitLab-era image"; exit 1; }
echo "ok GitLab-era Dockerfile without the layer cache (what the workflow does): passes"
# Sticky disk: --no-cache-filter re-runs the token stage (and the publish stage FROM it)
# with the current token; a global --no-cache would empty the NuGet cache mounts.
C="tok-C-$nonce"; token "$C"; must Dockerfile.gitlab --no-cache-filter build
grep -q '^200 .*selftest.publish.1.0.0.nupkg' "$work/feed.log" || { cat "$work/feed.log"; echo "FAIL GitLab-era --no-cache-filter: publish did not restore"; exit 1; }
echo "ok GitLab-era Dockerfile + --no-cache-filter build (sticky disk): passes with the current token"

# Fixed: run 1 fills the NuGet cache mount; run 2 (new commit, token B) reuses the restore
# layer and fetches no package (publish finds Selftest.Publish in the mount); run 3 with an
# empty mount fetches every package with the current token. No token in any layer.
token "$A"; must Dockerfile.fixed
grep -q '^200 .*selftest.publish.1.0.0.nupkg' "$work/feed.log" || { cat "$work/feed.log"; echo "FAIL fixed: publish did not restore from the feed"; exit 1; }
token "$B"; must Dockerfile.fixed
if grep -q 'nupkg' "$work/feed.log"; then cat "$work/feed.log"; echo "FAIL fixed: a package was fetched again despite the cache mount"; exit 1; fi
grep -q '#[0-9]* CACHED' "$work/build.log" || { tail -40 "$work/build.log"; echo "FAIL fixed: no layer reused from the cache"; exit 1; }
echo "ok fixed Dockerfile + NuGet cache mount: a rebuild fetches no package"
# The mount id is not part of the layer cache key: an empty mount under cached layers is
# what a GC'd sticky mount looks like, hence --no-cache (the workflow does the same).
sed -i.bak "s/id=nuget-$nonce,/id=nuget-$nonce-2,/" "$work/ctx/Dockerfile.fixed"
must Dockerfile.fixed --no-cache
grep -q '^200 .*selftest.build.1.0.0.nupkg' "$work/feed.log" && grep -q '^200 .*selftest.publish.1.0.0.nupkg' "$work/feed.log" \
  || { cat "$work/feed.log"; echo "FAIL fixed: a new cache mount did not restore from the feed with the current token"; exit 1; }
eq "$(leaks fixed)" "" "no token in the fixed image"
echo "ok fixed Dockerfile: restores with the current token, no token in any layer"

# Runtime tests stage: the mount also holds an unrelated package; the image gets only the
# one obj/project.assets.json names (Selftest.Build), not the whole mount.
{ cat "$fx/Dockerfile.gitlab"; printf 'FROM build AS tests\nENTRYPOINT ["dotnet", "test", "--no-build"]\n'; } > "$work/ctx/Dockerfile.tests"
(cd "$work/ctx-cm" && "$here/nuget-secret-mount-fix.sh" "$work/ctx/Dockerfile.tests") >/dev/null
sed -i.bak "s/id=nuget,/id=nuget-$nonce-t,/" "$work/ctx/Dockerfile.tests"
printf 'FROM mcr.microsoft.com/dotnet/sdk:10.0\nRUN --mount=type=cache,id=nuget-%s-t,target=/c mkdir -p /c/unrelated.pkg/9.9.9 && echo x > /c/unrelated.pkg/9.9.9/x\n' "$nonce" > "$work/ctx/Dockerfile.prefill"
docker buildx build --progress plain -f "$work/ctx/Dockerfile.prefill" "$work/ctx" >"$work/build.log" 2>&1 || { tail -20 "$work/build.log"; echo "FAIL prefill"; exit 1; }
# a new csproj: the mount id is not part of the cache key, the restore must run into this mount
echo "<!-- $nonce-t -->" >> "$work/ctx/App/App.csproj"
docker buildx build --progress plain --load --add-host host.docker.internal:host-gateway \
  --secret "id=NUGET_CREDENTIALS,src=$work/e2e/packages-token/NUGET_CREDENTIALS" \
  -f "$work/ctx/Dockerfile.tests" --target tests -t local/selftest-token-cache:tests "$work/ctx" >"$work/build.log" 2>&1 \
  || { grep -E "^#[0-9]+ [0-9.]+ " "$work/build.log" | tail -20; echo "FAIL build tests stage"; exit 1; }
eq "$(docker run --rm --entrypoint sh local/selftest-token-cache:tests -c 'cd /root/.nuget/packages && find . -mindepth 2 -maxdepth 2 -type d | sort')" "./selftest.build/1.0.0" "runtime tests stage: only the restored packages copied"
echo "ok runtime tests stage: copies the packages of obj/project.assets.json, not the whole mount"
# ── 4. NuGet cache mount on the Magic Cache (test job, docker-test-target) ─────────
seed=$(block nuget-mount-seed "$wf"); extract=$(block nuget-mount-extract "$wf")
[ -n "$seed" ] && [ -n "$extract" ] || { echo "nuget-mount-seed/extract block not found in $wf"; exit 1; }
# Builders of their own (id=nuget as in the workflow, nothing shared with other runs).
for b in a b c; do
  builders+=("selftest-nuget-mount-$b-$nonce")
  docker buildx create --name "selftest-nuget-mount-$b-$nonce" --driver docker-container >/dev/null
done
cp "$work/Dockerfile.fixed" "$work/ctx/Dockerfile.mount"
# The docker-container driver has no host-gateway: the docker daemon resolves it.
gw=$(docker run --rm --add-host gw:host-gateway mcr.microsoft.com/azurelinux/busybox:1.36 awk '$2=="gw"{print $1; exit}' /etc/hosts)
mbuild() { # <builder>: a new commit, target publish
  echo "// $RANDOM$RANDOM" >> "$work/ctx/App/Program.cs"
  : > "$work/feed.log"
  docker buildx build --builder "$1" --progress plain --add-host "host.docker.internal:$gw" \
    --secret "id=NUGET_CREDENTIALS,src=$work/e2e/packages-token/NUGET_CREDENTIALS" \
    -f "$work/ctx/Dockerfile.mount" --target publish "$work/ctx" >"$work/build.log" 2>&1 \
    || { grep -E "error|401" "$work/build.log" | tail -20; cat "$work/feed.log"; echo "FAIL build on $1"; exit 1; }
}
D="$work/nuget-mount"
token "$A"; mbuild "${builders[0]}"
grep -q '^200 .*selftest.publish.1.0.0.nupkg' "$work/feed.log" || { cat "$work/feed.log"; echo "FAIL mount: the first runner did not restore from the feed"; exit 1; }
: > "$work/out"
DIR="$D" BUILDER="${builders[0]}" GITHUB_OUTPUT="$work/out" bash -c "set -eo pipefail; $extract" >"$work/build.log" 2>&1 \
  || { tail -20 "$work/build.log"; echo "FAIL nuget-mount-extract"; exit 1; }
eq "$(cat "$work/out")" "save=true" "nuget-mount-extract: saves a filled mount"
eq "$(cd "$D" && find . -mindepth 2 -maxdepth 2 -type d | sort | paste -sd' ' -)" "./selftest.build/1.0.0 ./selftest.publish/1.0.0" "nuget-mount-extract: the mount's packages"
DIR="$D" BUILDER="${builders[1]}" bash -c "set -eo pipefail; $seed" >"$work/build.log" 2>&1 \
  || { tail -20 "$work/build.log"; echo "FAIL nuget-mount-seed"; exit 1; }
token "$B"; mbuild "${builders[1]}"
if grep -q 'nupkg' "$work/feed.log"; then cat "$work/feed.log"; echo "FAIL mount: the seeded runner fetched a package again"; exit 1; fi
grep -q 'Restored .*App.csproj' "$work/build.log" || { tail -30 "$work/build.log"; echo "FAIL mount: the seeded runner did not run the restore"; exit 1; }
: > "$work/out"
DIR="$work/nuget-mount-empty" BUILDER="${builders[2]}" GITHUB_OUTPUT="$work/out" bash -c "set -eo pipefail; $extract" >"$work/build.log" 2>&1 \
  || { tail -20 "$work/build.log"; echo "FAIL nuget-mount-extract (empty)"; exit 1; }
eq "$(cat "$work/out")" "" "nuget-mount-extract: an empty mount is not saved"
echo "ok NuGet cache mount: copied out of one fresh builder and into another, the restore fetches no package"

docker rmi -f local/selftest-token-cache:gitlab local/selftest-token-cache:fixed local/selftest-token-cache:tests >/dev/null 2>&1 || true
echo "dotnet-service-build packages token: OK"
