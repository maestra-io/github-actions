#!/usr/bin/env bash
# .NET SDKs from nora (issues-maestra#1649) in place of actions/setup-dotnet, which downloads
# them and the release metadata from builds.dotnet.microsoft.com. Same inputs: DOTNET_VERSION
# (setup-dotnet syntax, one per line: 10.0.x, 10.0, 10, 10.x, 10.0.4xx, 10.0.404) and
# GLOBAL_JSON (a global.json: its sdk.version under its rollForward). Each is resolved to the
# newest SDK in sdks.txt that satisfies it, fetched from nora raw with the job's OIDC session
# token, checked against the sha256 pinned there and unpacked whole into its own directory in
# the runner tool cache ($RUNNER_TOOL_CACHE/dotnet-nora/<version>, with a <version>.complete
# marker). The unpacked tree is pinned too (the third column of sdks.txt: tree_digest below). An
# SDK already complete there (an earlier job's on a reused instance) is used, with nothing
# fetched, only when its tree is that pin; any other tree (a tampered file, an added one) is
# reinstalled from the verified archive, and a freshly unpacked tree that is not the pin fails the
# step. The job's dotnet root is then built fresh in $RUNNER_TEMP/dotnet-nora-root from hard links
# into the verified trees (copies across file systems), newest SDK first (its `dotnet` host), and
# goes on PATH and into DOTNET_ROOT. Only the SDKs asked for are in it, never the runner image's:
# list every SDK the job needs (a test runtime comes with its SDK). Nothing reaches Microsoft: a
# version sdks.txt does not list fails here instead.
# DOTNET_NORA_RESOLVE_ONLY=1 prints the resolved versions and stops (scripts/test-dotnet-nora.sh).
# DOTNET_NORA_TREE=<archive> prints the tree pin of a verified archive (unpacked as install does;
# GNU tools, linux) and stops: how the third column of sdks.txt is made.
# DOTNET_NORA_PLAN=1 writes cache-key (empty when every SDK is complete in the tool cache) to
# $GITHUB_OUTPUT and stops. DOTNET_NORA_CACHE_DIR: archives restored from the runner cache
# (RunsOn Magic Cache, S3 next to the runners) are used from there when their sha256 is the
# pin, anything else is deleted and fetched from nora; fetched archives are kept there for the
# cache save, and save=true is written to $GITHUB_OUTPUT.
set -euo pipefail
here="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")" && pwd)}"
list="$here/sdks.txt"
fail() { echo "::error::dotnet-nora: $*" >&2; exit 1; }
umask 022 # the exec bits of the unpacked tree are part of its pin

# tree_digest <dir>: sha256 over every entry's type, path and symlink target, the owner-exec bit of
# every file and the sha256 of every file's content (nora-tool/nora-tool.sh has the same function).
# Anything added, removed, rewritten or made executable changes it; mtimes and owners do not.
tree_digest() {
  ( cd "$1" && LC_ALL=C find . -mindepth 1 -printf '%y %p %l\n' | LC_ALL=C sort \
      && LC_ALL=C find . -type f -perm -u+x -printf 'x %p\n' | LC_ALL=C sort \
      && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) | sha256sum | cut -d' ' -f1
}
if [ -n "${DOTNET_NORA_TREE:-}" ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  tar -xzf "$DOTNET_NORA_TREE" -C "$t" || fail "$DOTNET_NORA_TREE: unpacking failed"
  tree_digest "$t"; exit 0
fi

listed() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list" | awk '{ print $1 }'; }
newest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }
# pick <major> <minor|-> <band|-> <floor x.y.z|->: the newest listed version with that
# major (and minor, and feature band = hundreds of the patch) that is >= floor.
pick() {
  listed | awk -F. -v M="$1" -v m="$2" -v b="$3" -v f="$4" '
    BEGIN { if (f != "-") { split(f, F, "."); fv = F[1] * 1e8 + F[2] * 1e5 + F[3] } else fv = -1 }
    $1 == M && (m == "-" || $2 == m) && (b == "-" || int($3 / 100) == b) && ($1 * 1e8 + $2 * 1e5 + $3) >= fv' | newest
}

# setup-dotnet syntax → one version
resolve_spec() {
  local s=$1 v
  if [[ $s =~ ^([0-9]+)(\.x)?$ ]]; then v=$(pick "${BASH_REMATCH[1]}" - - - )
  elif [[ $s =~ ^([0-9]+)\.([0-9]+)(\.x)?$ ]]; then v=$(pick "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" - -)
  elif [[ $s =~ ^([0-9]+)\.([0-9]+)\.([0-9])xx$ ]]; then v=$(pick "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" -)
  elif [[ $s =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then v=$(listed | grep -Fx "$s" || true)
  else fail "dotnet-version '$s': only N, N.x, N.M, N.M.x, N.M.Fxx or an exact SDK version are served"
  fi
  [ -n "$v" ] || fail "no SDK for '$s' in dotnet-nora/sdks.txt: add it there and to maestra-io/dockerfiles .github/raw-uploads/dotnet.txt"
  echo "$v"
}

# global.json sdk.version + rollForward → one version (the rule dotnet applies, newest match)
resolve_global_json() {
  local f=$1 g v rf M m p
  # dotnet accepts // and /* */ comments in global.json; strings are kept as they are
  g=$(python3 -I -c '
import json, re, sys
s = re.sub(r"\"(?:\\.|[^\"\\])*\"|//[^\n]*|/\*.*?\*/", lambda m: m.group(0) if m.group(0)[0] == "\"" else "", open(sys.argv[1]).read(), flags=re.S)
print(json.dumps(json.loads(s)))' "$f" 2>/dev/null) || fail "$f is not valid JSON (with comments)"
  v=$(jq -r '.sdk.version // "" | tostring' <<<"$g")
  [ -n "$v" ] || return 0
  rf=$(jq -r '.sdk.rollForward // "latestPatch"' <<<"$g")
  [[ $v =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "$f sdk.version '$v' is not a release SDK version"
  M=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} p=${BASH_REMATCH[3]}
  case "$rf" in
    patch|latestPatch) v=$(pick "$M" "$m" "$((p / 100))" "$v") ;;
    feature|latestFeature) v=$(pick "$M" "$m" - "$v") ;;
    # The newest of the same major: the target frameworks decide the build SDK (the
    # workflows' pin), so nothing newer is fetched while the requested major serves.
    minor|latestMinor) v=$(pick "$M" - - "$v") ;;
    # ...and a higher major when the requested one has nothing at or above sdk.version.
    major|latestMajor) v=$(pick "$M" - - "$v")
      [ -n "$v" ] || v=$(listed | awk -F. -v M="$M" '$1 > M' | newest) ;;
    disable) v=$(listed | grep -Fx "$v" || true) ;;
    *) fail "$f rollForward '$rf' is not a global.json policy" ;;
  esac
  [ -n "$v" ] || fail "no SDK satisfies $f (sdk.version ${M}.${m}.${p}, rollForward $rf) in dotnet-nora/sdks.txt: add one there and to maestra-io/dockerfiles .github/raw-uploads/dotnet.txt"
  echo "$v"
}

versions=()
while IFS= read -r s; do
  s="${s//[[:space:]]/}"
  [ -n "$s" ] || continue
  v=$(resolve_spec "$s") || exit 1
  versions+=("$v")
done <<<"${DOTNET_VERSION:-}"
if [ -n "${GLOBAL_JSON:-}" ] && [ -f "$GLOBAL_JSON" ]; then
  v=$(resolve_global_json "$GLOBAL_JSON") || exit 1
  [ -z "$v" ] || versions+=("$v")
fi
# newest first: the first SDK's `dotnet` host stays in the job's root (cp --update=none below)
[ "${#versions[@]}" -eq 0 ] || mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -u -t. -k1,1nr -k2,2nr -k3,3nr)
if [ "${DOTNET_NORA_RESOLVE_ONLY:-}" = 1 ]; then
  [ "${#versions[@]}" -eq 0 ] || printf '%s\n' "${versions[@]}"
  exit 0
fi
if [ "${#versions[@]}" -eq 0 ]; then echo "dotnet-nora: no dotnet-version and no global.json SDK: nothing installed"; exit 0; fi
[ "$(uname -m)" = x86_64 ] || fail "only linux-x64 SDKs are hosted (this runner: $(uname -s) $(uname -m))"

# Each SDK in its own directory of the tool cache (a cold install per version at a time on a host)
tc="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}/dotnet-nora"
if ! { mkdir -p "$tc" 2>/dev/null && [ -w "$tc" ]; }; then tc="${RUNNER_TEMP:-/tmp}/dotnet-nora-sdks"; mkdir -p "$tc"; fi
complete() { [ -f "$tc/$1.complete" ] && [ -d "$tc/$1/sdk/$1" ]; }
pin() { sed -e 's/#.*//' "$list" | awk -v v="$1" -v c="$2" '$1 == v { print $c }'; }

if [ "${DOTNET_NORA_PLAN:-}" = 1 ]; then
  # The key names the SDKs still to install and hashes their pins: a re-pinned archive
  # never matches an older entry.
  pins=$(for v in "${versions[@]}"; do complete "$v" || awk -v v="$v" '$1 == v' "$list"; done)
  key=""
  [ -z "$pins" ] || key="dotnet-nora-sdk-linux-x64-$(awk '{ print $1 }' <<<"$pins" | paste -sd+ -)-$(sha256sum <<<"$pins" | cut -c1-16)"
  echo "cache-key=$key" >> "$GITHUB_OUTPUT"
  echo "dotnet-nora: cache key '${key}'"
  exit 0
fi

# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
. "$here/../nora-session/nora-session.sh"
token=""
cache="${DOTNET_NORA_CACHE_DIR:-}"
tmp="${cache:-${RUNNER_TEMP:-/tmp}/dotnet-nora}"; mkdir -p "$tmp"
base="${NORA_URL%/}/raw/src/builds.dotnet.microsoft.com/dotnet/Sdk"
# The job's own dotnet root, built fresh: nothing an earlier job left runs in it.
root="${RUNNER_TEMP:-/tmp}/dotnet-nora-root"
rm -rf "$root"; mkdir -p "$root"
for v in "${versions[@]}"; do
  sum=$(pin "$v" 2) tree=$(pin "$v" 3)
  [[ $tree =~ ^[0-9a-f]{64}$ && $tree != "$sum" ]] || fail "SDK $v has no tree pin (third column) in sdks.txt"
  d="$tc/$v"
  # held until the SDK is linked into the root: no other job replaces it in between
  if command -v flock >/dev/null; then exec 9>"$tc/.$v.lock"; flock 9; fi
  got_tree=""
  if complete "$v"; then got_tree=$(tree_digest "$d") || got_tree=unreadable; fi
  if [ "$got_tree" = "$tree" ]; then
    echo "dotnet-nora: SDK $v already in the tool cache ($d, tree sha256 $tree), nothing fetched"
  else
    [ -z "$got_tree" ] || echo "::warning::dotnet-nora: $d is not the pinned tree (tree sha256 $got_tree, sdks.txt pins $tree): reinstalling it from the verified archive"
    url="$base/$v/dotnet-sdk-$v-linux-x64.tar.gz"
    f="$tmp/dotnet-sdk-$v.tar.gz"
    # A cached archive is another copy of an executable: used only when its sha256 is the pin
    # in this action's sdks.txt, else dropped and fetched from nora (and checked) as on a miss.
    if [ -n "$cache" ] && [ -s "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ]; then
      echo "dotnet-nora: SDK $v archive from the runner cache (sha256 $sum), nothing fetched from nora"
    else
      [ ! -e "$f" ] || { echo "::warning::dotnet-nora: cached SDK $v archive is not the sha256 pin, fetching it from nora"; rm -f "$f"; }
      [ -n "$token" ] || token=$(nora_token "$NORA_URL" "$NORA_AUDIENCE") || fail "no nora token (the job needs permissions: id-token: write)"
      echo "::add-mask::$token"
      # the credential reaches curl as a config on stdin, never on its command line
      printf 'user = "token:%s"\n' "$token" | curl -fsS --retry 3 --connect-timeout 15 -K - -o "$f" "$url" \
        || fail "GET $url failed"
      got=$(sha256sum "$f" | cut -d' ' -f1)
      [ "$got" = "$sum" ] || { rm -f "$f"; fail "SDK $v from $url: sha256 $got, sdks.txt pins $sum"; }
      echo "dotnet-nora: SDK $v archive fetched from $url"
      [ -z "$cache" ] || echo "save=true" >> "$GITHUB_OUTPUT"
    fi
    # unpacked next to its final place, checked, moved in whole, then marked complete
    rm -rf "$d" "$d.nora" "$d.complete"; mkdir -p "$d.nora"
    tar -xzf "$f" -C "$d.nora" || { rm -rf "$d.nora"; fail "SDK $v: unpacking failed"; }
    [ -n "$cache" ] || rm -f "$f"
    got_tree=$(tree_digest "$d.nora")
    [ "$got_tree" = "$tree" ] || { rm -rf "$d.nora"; fail "SDK $v unpacked to tree sha256 $got_tree, sdks.txt pins $tree"; }
    mv "$d.nora" "$d"; touch "$d.complete"
    echo "dotnet-nora: SDK $v (sha256 $sum, tree sha256 $tree) into $d"
  fi
  # Newest first: the first SDK's top-level files (the `dotnet` host) stay; versioned
  # directories shared by two SDKs (host/fxr/<v>, shared/*/<v>) are the same release.
  # A job that rewrites a linked file rewrites the tool cache's copy: the next job's tree
  # check reinstalls it.
  cp -al --update=none "$d/." "$root/" 2>/dev/null || cp -R --update=none "$d/." "$root/" \
    || fail "SDK $v: linking into $root failed"
  exec 9>&-
done
echo "$root" >> "$GITHUB_PATH"
echo "DOTNET_ROOT=$root" >> "$GITHUB_ENV"
{ echo 'versions<<DOTNET_NORA_EOF'; printf '%s\n' "${versions[@]}"; echo 'DOTNET_NORA_EOF'; } >> "$GITHUB_OUTPUT"
PATH="$root:$PATH" dotnet --list-sdks
