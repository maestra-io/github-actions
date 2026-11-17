#!/usr/bin/env bash
# .NET SDKs from nora (issues-maestra#1649) in place of actions/setup-dotnet, which downloads
# them and the release metadata from builds.dotnet.microsoft.com. Same inputs: DOTNET_VERSION
# (setup-dotnet syntax, one per line: 10.0.x, 10.0, 10, 10.x, 10.0.4xx, 10.0.404) and
# GLOBAL_JSON (a global.json: its sdk.version under its rollForward). Each is resolved to the
# newest SDK in sdks.txt that satisfies it, fetched from nora raw with the job's OIDC session
# token, checked against the sha256 pinned there and unpacked into $DOTNET_INSTALL_DIR
# (default /usr/share/dotnet, as setup-dotnet; $HOME/.dotnet when that is not writable), next
# to the SDKs already there; the directory goes on PATH and into DOTNET_ROOT. Nothing reaches
# Microsoft: a version sdks.txt does not list fails here instead.
# DOTNET_NORA_RESOLVE_ONLY=1 prints the resolved versions and stops (scripts/test-dotnet-nora.sh).
set -euo pipefail
here="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")" && pwd)}"
list="$here/sdks.txt"
fail() { echo "::error::dotnet-nora: $*" >&2; exit 1; }

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
# newest first: on an empty directory the first SDK's `dotnet` host stays (cp -n below)
[ "${#versions[@]}" -eq 0 ] || mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -u -t. -k1,1nr -k2,2nr -k3,3nr)
if [ "${DOTNET_NORA_RESOLVE_ONLY:-}" = 1 ]; then
  [ "${#versions[@]}" -eq 0 ] || printf '%s\n' "${versions[@]}"
  exit 0
fi
if [ "${#versions[@]}" -eq 0 ]; then echo "dotnet-nora: no dotnet-version and no global.json SDK: nothing installed"; exit 0; fi
[ "$(uname -m)" = x86_64 ] || fail "only linux-x64 SDKs are hosted (this runner: $(uname -s) $(uname -m))"

dir="${DOTNET_INSTALL_DIR:-/usr/share/dotnet}"
if ! { [ -d "$dir" ] && [ -w "$dir" ]; } && ! { [ ! -e "$dir" ] && mkdir -p "$dir" 2>/dev/null; }; then
  echo "dotnet-nora: $dir is not writable, installing into $HOME/.dotnet"
  dir="$HOME/.dotnet"; mkdir -p "$dir"
fi

# shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
. "$here/../nora-session/nora-session.sh"
token=""
tmp="${RUNNER_TEMP:-/tmp}/dotnet-nora"; mkdir -p "$tmp"
base="${NORA_URL%/}/raw/src/builds.dotnet.microsoft.com/dotnet/Sdk"
for v in "${versions[@]}"; do
  if [ -d "$dir/sdk/$v" ]; then echo "dotnet-nora: SDK $v already in $dir"; continue; fi
  [ -n "$token" ] || token=$(nora_token "$NORA_URL" "$NORA_AUDIENCE") || fail "no nora token (the job needs permissions: id-token: write)"
  echo "::add-mask::$token"
  sum=$(awk -v v="$v" '$1 == v { print $2 }' "$list")
  url="$base/$v/dotnet-sdk-$v-linux-x64.tar.gz"
  f="$tmp/dotnet-sdk-$v.tar.gz"
  # the credential reaches curl as a config on stdin, never on its command line
  printf 'user = "token:%s"\n' "$token" | curl -fsS --retry 3 --connect-timeout 15 -K - -o "$f" "$url" \
    || fail "GET $url failed"
  got=$(sha256sum "$f" | cut -d' ' -f1)
  [ "$got" = "$sum" ] || { rm -f "$f"; fail "SDK $v from $url: sha256 $got, sdks.txt pins $sum"; }
  # Staged next to $dir, then merged: versioned directories (host/fxr/<v>, shared/*/<v>,
  # packs, templates) are overwritten, so a retry repairs an interrupted merge; top-level
  # files (the `dotnet` host) are kept when present (the image's is newer); sdk/<v> moves
  # in last, so its presence means a complete install.
  stage="$dir/.dotnet-nora-$v"
  rm -rf "$stage" "$stage.sdk"; mkdir -p "$stage"
  tar -xzf "$f" -C "$stage" || { rm -rf "$stage"; fail "SDK $v: unpacking failed"; }
  rm -f "$f"
  mv "$stage/sdk/$v" "$stage.sdk"
  find "$stage" -mindepth 1 -maxdepth 1 -type f -exec cp -an {} "$dir"/ \;
  find "$stage" -mindepth 1 -maxdepth 1 -type d -exec cp -a {} "$dir"/ \;
  mkdir -p "$dir/sdk"
  mv "$stage.sdk" "$dir/sdk/$v"
  rm -rf "$stage"
  echo "dotnet-nora: SDK $v from $url (sha256 $sum) into $dir"
done
echo "$dir" >> "$GITHUB_PATH"
echo "DOTNET_ROOT=$dir" >> "$GITHUB_ENV"
{ echo 'versions<<DOTNET_NORA_EOF'; printf '%s\n' "${versions[@]}"; echo 'DOTNET_NORA_EOF'; } >> "$GITHUB_OUTPUT"
PATH="$dir:$PATH" dotnet --list-sdks
