#!/usr/bin/env bash
#
# Stop a Dockerfile from writing the packages token into an image layer
# (dotnet-service-build.yml header, Registry token). The GitLab-era
#   RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN \
#       dotnet nuget update source private --username ci --password $(cat ...) ...
# stores the token in NuGet.Config; a secret's value is not part of the cache key,
# so the layer cache replays it in later builds after it expired (401 as soon as a
# later step restores). This removes that RUN and mounts the token on every RUN
# that runs dotnet restore/build/publish/test/pack/... instead, --no-restore ones too (a
# build target may still reach the feed: segmentations' `dotnet tool install`):
#   RUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private dotnet restore
# (NUGET_CREDENTIALS = `Username=ci;Password=<token>`, NuGet's env credential format).
# A credential RUN that also does something else is reported, not touched.
# A Dockerfile converted before #124 (only the restore RUN mounted) gets the mount on
# its other dotnet RUNs, same source: a --no-restore build without it lets the SDK's
# workload-manifest check send an empty Basic credential, nora locks the runner out.
# Idempotent: a second run changes nothing.
#
# Usage: nuget-secret-mount-fix.sh [file...]   (default: every Dockerfile* in the tree)
set -euo pipefail

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find . -path ./.git -prune -o -type f \( -name 'Dockerfile*' -o -name '*.Dockerfile' \) -print0)
fi
[ "${#files[@]}" -gt 0 ] || exit 0

python3 -I - "${files[@]}" <<'PY'
import re, sys

CRED = re.compile(r'^dotnet\s+nuget\s+update\s+source\s+([A-Za-z0-9_.-]+)\s.*--password\b', re.S)
MOUNTED = re.compile(r'id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_([A-Za-z0-9_]+)')
DOTNET = re.compile(r'\bdotnet["\',\s]+(restore|build|publish|test|pack|msbuild|tool|workload|run)\b')
FLAG = re.compile(r'^--\S+\s*')

def instructions(lines):
    """[(first, last)] line ranges of logical instructions (comments/blanks excluded)."""
    out, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        if not s or s.startswith('#'):
            i += 1; continue
        j = i
        while lines[j].rstrip('\n').rstrip().endswith('\\') and j + 1 < len(lines):
            j += 1
            while j + 1 < len(lines) and (not lines[j].strip() or lines[j].strip().startswith('#')):
                j += 1  # blank or comment line inside a continuation
        out.append((i, j)); i = j + 1
    return out

def joined(lines, a, b):
    t = ' '.join(l.rstrip('\n').rstrip().rstrip('\\') for l in lines[a:b + 1] if not l.strip().startswith('#'))
    return re.sub(r'\s+', ' ', t).strip()

for path in sys.argv[1:]:
    lines = open(path, newline='').read().splitlines(keepends=True)  # keep CRLF files CRLF
    drop, names, runs = set(), [], []
    for a, b in instructions(lines):
        text = joined(lines, a, b)
        if not re.match(r'(?i)RUN\s', text):
            continue
        cmd = text[4:].strip()
        while FLAG.match(cmd):
            cmd = FLAG.sub('', cmd, count=1)
        m = CRED.match(cmd)
        if m:
            if re.search(r'&&|\|\||;', cmd):
                print(f'credential RUN does more than update the source (fix by hand): {path}:{a + 1}')
                continue
            names.append(m.group(1))
            drop.update(range(a, b + 1))
            k = a - 1  # the comment lines right above it explain it: drop them too
            while k >= 0 and lines[k].strip().startswith('#') and not lines[k].strip().startswith('###'):
                drop.add(k); k -= 1
        elif DOTNET.search(cmd) and 'id=NUGET_CREDENTIALS' not in text:
            runs.append(a)
    if re.search(r'--password', ''.join(l for i, l in enumerate(lines) if i not in drop)):
        print(f'still writes a password (fix by hand): {path}')
    if not names and runs:  # converted before #124: reuse the source names already mounted
        names = MOUNTED.findall(''.join(lines))
    if not names:
        print(f'unchanged: {path}'); continue
    mounts = ' '.join(f'--mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_{n}'
                      for n in dict.fromkeys(names))
    for a in runs:
        lines[a] = re.sub(r'^(\s*RUN)\s+', lambda m: f'{m.group(1)} {mounts} ', lines[a], count=1, flags=re.I)
    out = ''.join(l for i, l in enumerate(lines) if i not in drop)
    out = re.sub(r'(\r?\n){3,}', r'\1\1', out)
    open(path, 'w', newline='').write(out)
    print(f'fixed:     {path} (source {", ".join(dict.fromkeys(names))}, {len(runs)} RUN mounted)')
PY
