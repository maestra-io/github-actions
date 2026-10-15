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
# Every such RUN also gets the NuGet packages folder as a BuildKit cache mount (sticky
# disk: a restore layer invalidated by `COPY . .` fetches only the delta, DirectCRM PR 31):
#   RUN --mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_private --mount=type=cache,id=nuget,target=/root/.nuget/packages,sharing=locked dotnet restore
# target = the RUN's `--packages <dir>` (ARG/ENV defaults resolved, relative to WORKDIR)
# or `-p:RestorePackagesPath=<dir>` (absolute only: NuGet resolves it against the
# project); a --no-restore RUN reads the folder the last restore of its stage used;
# else a literal absolute <RestorePackagesPath>/<NUGET_PACKAGES> in a *.props/*.targets/
# *.csproj under the current directory (run the script from the build context root),
# else ENV NUGET_PACKAGES, else $HOME/.nuget/packages. Packages in the mount never reach a layer,
# so it is all or nothing per stage family (FROM <stage> chains): it is left out and
# reported (fix by hand) when a family has a non-root USER, an unresolvable path, a
# mount of its own on that folder, or a RUN without the mount / a COPY --from that
# reads the folder. A stage running dotnet at container start (the template's tests
# stage: CMD/ENTRYPOINT `dotnet test --no-build`, which without its packages silently
# runs zero tests) gets them copied out of the mount into its image, after its
# FROM/WORKDIR (or its last dotnet RUN): only the <id>/<version> folders its
# obj/project.assets.json files name (COPY_RUN below), not the whole mount, which on a
# sticky disk holds every version ever restored (54-354 s copies, unbounded images);
# the whole-mount `cp -a /tmp/nuget-cache/.` line of PR 147 is upgraded to it.
# Dockerfiles converted earlier get the cache mount on their next run.
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
import json, os, posixpath, re, shlex, sys

CRED = re.compile(r'^dotnet\s+nuget\s+update\s+source\s+([A-Za-z0-9_.-]+)\s.*--password\b', re.S)
MOUNTED = re.compile(r'id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_([A-Za-z0-9_]+)')
SECRET = re.compile(r'--mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_[A-Za-z0-9_]+')
DOTNET = re.compile(r'\bdotnet["\',\s]+(restore|build|publish|test|pack|msbuild|tool|workload|run)\b')
RESTORES = re.compile(r'\bdotnet["\',\s]+(restore|build|publish|test|pack|run)\b')  # rewrites obj/project.assets.json
NOREST = re.compile(r'--no-(restore|build)\b')
PKG = re.compile(r'--packages(?:=|\s+)("[^"]*"|\'[^\']*\'|\S+)')
# -p:/-property:/--property: RestorePackagesPath, also inside a `;` property list
RPP = re.compile(r'(?:--?|/)p(?:roperty)?:(?:[^\s=;]+=[^\s;]*;)*(?i:RestorePackagesPath)=("[^"]*"|\'[^\']*\'|[^\s;]+)')
MOUNT = re.compile(r'--mount=(\S+)')
VAR = re.compile(r'\$(?:\{(\w+)\}|(\w+))')
FLAG = re.compile(r'^--\S+\s*')
COPY_CACHE = '--mount=type=cache,id=nuget,target=/tmp/nuget-cache,sharing=locked'
# Copies only the packages of this stage's obj/project.assets.json files (their "path":
# <id>/<version>, lowercase), not the whole mount (every version the disk ever restored);
# fails when there is no assets file, one restored elsewhere, or a package is missing.
COPY_RUN = ('RUN ' + COPY_CACHE + " set -e; find / \\( -path /proc -o -path /sys -o -path /tmp/nuget-cache"
            " -o -path /usr/share/dotnet -o -path @D@ \\) -prune -o -path '*/obj/project.assets.json' -print"
            " > /tmp/nuget-assets; [ -s /tmp/nuget-assets ] || { echo 'no obj/project.assets.json: no NuGet"
            " packages to copy' >&2; exit 1; }; while read -r f; do grep -q '\"@D@/\"' \"$f\" || { echo"
            " \"$f restores outside @D@\" >&2; exit 1; }; done < /tmp/nuget-assets; while read -r f; do"
            " sed -n 's|^ *\"path\": \"\\([^\"/]*/[^\"/]*\\)\",*$|\\1|p' \"$f\"; done < /tmp/nuget-assets"
            " | sed '/proj$/d' | sort -u > /tmp/nuget-pkgs; while read -r p; do test -d \"/tmp/nuget-cache/$p\""
            " || { echo \"$p is not in the NuGet cache mount\" >&2; exit 1; }; mkdir -p \"@D@/$p\";"
            " cp -a \"/tmp/nuget-cache/$p/.\" \"@D@/$p/\"; done < /tmp/nuget-pkgs;"
            " echo \"copied $(wc -l < /tmp/nuget-pkgs) NuGet packages into @D@\"; rm /tmp/nuget-assets /tmp/nuget-pkgs")

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

def resolve(v, scope):
    """$X / ${X} from ARG/ENV defaults; None when anything stays unknown."""
    if v is None:
        return None
    out = VAR.sub(lambda m: scope.get(m.group(1) or m.group(2)) or '\0', v.strip('"\''))
    return None if '\0' in out or '$' in out else out

def words(s):
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()

class Stage:
    def __init__(self, idx, name, parent):
        self.idx, self.name, self.parent = idx, name, parent
        self.root = parent.root if parent else self
        self.env = dict(parent.env) if parent else {}
        self.user = parent.user if parent else 'root'
        self.wd = parent.wd if parent else '/'
        self.pkgdir = parent.pkgdir if parent else None  # where the last restore put packages
        self.args = {}
        self.at = None        # line a runtime package copy goes after: FROM/WORKDIR, then its last dotnet RUN
        self.copies = None    # that copy: 'new', or the line of an old whole-mount `cp -a`
    def scope(self):
        return {**self.args, **self.env}

def cache_target(cmd, st):
    """(packages dir the RUN reads/writes, None) or (None, why it cannot be told)."""
    if resolve(st.user, {}) not in ('root', '0'):
        return None, f'USER {st.user} is active (a cache mount is root-owned)'
    scope = st.scope()
    found = {}  # resolved path -> flag text
    for rx, flag in ((PKG, '--packages'), (RPP, '-p:RestorePackagesPath=')):
        for m in rx.finditer(cmd):
            raw = m.group(1); p = resolve(raw, scope)
            if p is None or p.startswith('~'):
                return None, f'{flag}{raw} cannot be resolved from an ARG/ENV default'
            if not p.startswith('/'):
                if rx is RPP:  # NuGet resolves it against the project's directory
                    return None, f'{flag}{raw} is relative to the project directory'
                if not st.wd:
                    return None, f'{flag} {raw} is relative to an unresolved WORKDIR'
                p = posixpath.join(st.wd, p)
            found[posixpath.normpath(p)] = flag
    if len(found) > 1:
        return None, 'several packages paths in one RUN (--packages / RestorePackagesPath)'
    if found:
        st.pkgdir = next(iter(found))
        return st.pkgdir, None
    if NOREST.search(cmd) and st.pkgdir:
        return st.pkgdir, None  # reads the folder project.assets.json names
    if RESTORES.search(cmd):
        st.pkgdir = None
    if PROPS:  # <RestorePackagesPath>/<NUGET_PACKAGES> in a project file of the build context
        return (PROPS, None) if PROPS.startswith('/') else (None, PROPS)
    if 'NUGET_PACKAGES' in scope:
        p = scope['NUGET_PACKAGES']
        if not p or not p.startswith('/'):
            return None, 'NUGET_PACKAGES cannot be resolved to an absolute path'
        return posixpath.normpath(p), None
    home = scope.get('HOME', '/root')
    if not home or not home.startswith('/'):
        return None, 'HOME cannot be resolved'
    return posixpath.normpath(home + '/.nuget/packages'), None

def props_packages():
    """<RestorePackagesPath>/<NUGET_PACKAGES> of the *.props/*.targets/*.csproj under the
    current directory (the build context): an absolute path, why not (str), or None."""
    vals = set()
    for top, dirs, names in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in ('.git', 'bin', 'obj', 'node_modules')]
        for n in names:
            if n.endswith(('.props', '.targets', '.csproj')):
                try:
                    x = re.sub(r'<!--.*?-->', '', open(os.path.join(top, n), errors='replace').read(), flags=re.S)
                except OSError:
                    continue
                for m in re.finditer(r'<(?:RestorePackagesPath|NUGET_PACKAGES)(\s[^>]*)?>([^<]*)<', x):
                    group = re.findall(r'<PropertyGroup\b[^>]*>', x[:m.start()])[-1:]
                    before = x[:m.start()]  # inside <Choose><When Condition=...> counts too
                    cond = bool((m.group(1) or '').strip()) or 'Condition' in ''.join(group) \
                        or before.count('<When') > before.count('</When>')
                    vals.add((os.path.join(top, n)[2:], m.group(2).strip(), cond))
    if not vals:
        return None
    paths = {v for _, v, _ in vals}
    f = sorted(vals)[0][0]
    if len(paths) > 1 or any(c for _, _, c in vals):
        return f'{f}: RestorePackagesPath/NUGET_PACKAGES set several ways or under a Condition'
    p = paths.pop()
    if '$' in p or not p.startswith('/'):
        return f'{f}: RestorePackagesPath/NUGET_PACKAGES {p} is not a literal absolute path'
    return posixpath.normpath(p)

def mount_targets(text, wd):
    """{target: type} of the --mount flags of a RUN."""
    out = {}
    for m in MOUNT.finditer(text):
        kv = dict(x.split('=', 1) if '=' in x else (x, '') for x in m.group(1).split(','))
        t = kv.get('target') or kv.get('dst') or kv.get('destination')
        if t:
            out[posixpath.normpath(posixpath.join(wd or '/', t))] = kv.get('type', 'bind')
    return out

def inside(p, d):
    return p == d or p.startswith(d.rstrip('/') + '/')

PROPS = props_packages()
for path in sys.argv[1:]:
    lines = open(path, newline='').read().splitlines(keepends=True)  # keep CRLF files CRLF
    drop, names, runs = set(), [], []
    stages, byname, gargs, st, hdr = [], {}, {}, None, False
    cands, later = [], []  # cands: [a, b, stage, dir, why, text]; later: (a, kind, stage, payload)
    for a, b in instructions(lines):
        text = joined(lines, a, b)
        kw, _, rest = text.partition(' ')
        kw = kw.upper()
        if kw == 'FROM':
            w = [x for x in rest.split() if not x.startswith('--')]
            name = w[2].lower() if len(w) > 2 and w[1].lower() == 'as' else None
            st = Stage(len(stages), name, byname.get(w[0].lower()) if w else None)
            stages.append(st); byname[str(st.idx)] = st; st.at = b; hdr = True
            if name:
                byname[name] = st
            continue
        if kw == 'ARG':
            for x in words(rest):
                k, eq, v = x.partition('=')
                if st is None:
                    gargs[k] = resolve(v, gargs) if eq else None
                else:
                    st.args[k] = resolve(v, st.scope()) if eq else gargs.get(k)
            continue
        if st is None:
            continue
        if kw == 'WORKDIR' and hdr:
            st.at = b
        hdr = False
        if kw == 'ENV':
            w = words(rest)
            pairs = [x.partition('=')[::2] for x in w] if w and '=' in w[0] else [(w[0], ' '.join(w[1:]))] if w else []
            scope = st.scope()
            for k, v in pairs:
                st.env[k] = resolve(v, scope)
            continue
        if kw == 'USER':
            st.user = (rest.split() or ['root'])[0].split(':')[0]
            continue
        if kw == 'WORKDIR':
            p = resolve(rest.strip(), st.scope())
            st.wd = posixpath.normpath(posixpath.join(st.wd or '/', p)) if p and (st.wd or p.startswith('/')) else None
            continue
        if kw in ('CMD', 'ENTRYPOINT'):
            if DOTNET.search(rest):
                later.append((a, 'start', st, None))
            continue
        if kw in ('COPY', 'ADD'):
            frm = re.search(r'--from=(\S+)', rest)
            if frm:
                body = FLAG.sub('', rest)
                while FLAG.match(body):
                    body = FLAG.sub('', body, count=1)
                try:
                    srcs = json.loads(body)[:-1] if body.startswith('[') else words(body)[:-1]
                except ValueError:
                    srcs = words(body)[:-1]
                later.append((a, 'copy', st, (frm.group(1).lower(), [resolve(x, st.scope()) for x in srcs])))
            continue
        if kw != 'RUN':
            continue
        cmd = text[4:].strip()
        while FLAG.match(cmd):
            cmd = FLAG.sub('', cmd, count=1)
        m = CRED.match(cmd)
        if m:
            if re.search(r'&&|\|\||;', cmd):
                print(f'credential RUN does more than update the source (fix by hand): {path}:{a + 1}')
                cands.append([a, b, st, None, 'the credential RUN above needs a hand fix first', text])
                continue
            names.append(m.group(1))
            drop.update(range(a, b + 1))
            k = a - 1  # the comment lines right above it explain it: drop them too
            while k >= 0 and lines[k].strip().startswith('#') and not lines[k].strip().startswith('###'):
                drop.add(k); k -= 1
        elif DOTNET.search(cmd):
            if 'id=NUGET_CREDENTIALS' not in text:
                runs.append(a)
            d, why = cache_target(cmd, st)
            cands.append([a, b, st, d, why, text]); st.at = b
        else:
            if COPY_CACHE in text and 'project.assets.json' in text:
                st.copies = 'new'
            elif COPY_CACHE in text and 'cp -a /tmp/nuget-cache/. ' in text and a == b:
                st.copies = a  # PR 147 copied the whole mount: upgraded below
            later.append((a, 'run', st, text))
    if re.search(r'--password', ''.join(l for i, l in enumerate(lines) if i not in drop)):
        print(f'still writes a password (fix by hand): {path}')
    if not names and (runs or cands):  # converted earlier: reuse the source names already mounted
        names = MOUNTED.findall(' '.join(joined(lines, a, b) for a, b in instructions(lines)))
    if not names:
        print(f'unchanged: {path}'); continue
    mounts = ' '.join(f'--mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_{n}'
                      for n in dict.fromkeys(names))
    for a in runs:
        lines[a] = re.sub(r'^(\s*RUN)\s+', lambda m: f'{m.group(1)} {mounts} ', lines[a], count=1, flags=re.I)

    # NuGet cache mount. Packages restored into it never reach a layer, so every RUN of
    # the stage family (FROM <stage> chains) that reads that folder must mount it too,
    # and nothing may read it outside a mount: else a family is left alone and reported.
    cached, copied, inserts = 0, 0, []
    for root in dict.fromkeys(c[2].root for c in cands):
        fam = [c for c in cands if c[2].root is root]
        dirs = {c[3] for c in fam if c[3]}
        first = min(c[0] for c in fam)
        why = [(c[0], c[4]) for c in fam if c[4]]
        for c in fam:
            other = {t: k for t, k in mount_targets(c[5], c[2].wd).items() if c[3] and t == c[3] and k != 'cache'}
            if other:
                why.append((c[0], f'it already mounts {c[3]} (type={other[c[3]]})'))
        starts = {s for a, kind, s, x in later if kind == 'start' and s.root is root}
        if starts and len(dirs) > 1:
            why.append((min(s.at for s in starts), 'a stage runs dotnet at container start and the family '
                        f'uses several packages folders ({", ".join(sorted(dirs))})'))
        for a, kind, s, x in later:
            if kind == 'run' and s.root is root and a > first and 'id=nuget' not in x and any(
                    d in x or (d.endswith('/.nuget/packages') and '.nuget/packages' in x) for d in dirs):
                why.append((a, 'a RUN without the mount reads the packages folder'))
            elif kind == 'copy' and byname.get(x[0]) is not None and byname[x[0]].root is root and any(
                    p is None or inside(posixpath.normpath(posixpath.join('/', p)), d) or inside(d, posixpath.normpath(posixpath.join('/', p)))
                    for p in x[1] for d in dirs):
                why.append((a, 'COPY --from takes the packages folder (or a parent) out of the stage'))
        if why:
            for a, w in dict(sorted(why)).items():
                print(f'no NuGet cache mount, {w} (fix by hand): {path}:{a + 1}')
            continue
        for a, b, s, d, _, text in fam:
            if re.search(r'--mount=type=cache,\S*(id=nuget[,\s]|target=' + re.escape(d) + r'[,\s])', text + ' ') or \
               any(t == d for t, k in mount_targets(text, s.wd).items()):
                continue  # already mounted
            cache = f'--mount=type=cache,id=nuget,target={d},sharing=locked'
            for i in range(b, a - 1, -1):
                hit = list(SECRET.finditer(lines[i]))
                if hit:
                    e = hit[-1].end(); lines[i] = f'{lines[i][:e]} {cache}{lines[i][e:]}'; break
            else:
                lines[a] = re.sub(r'^(\s*RUN)\s+', lambda m: f'{m.group(1)} {cache} ', lines[a], count=1, flags=re.I)
            cached += 1
        # A stage that runs `dotnet test --no-build` at container start reads the packages
        # from its own filesystem: copy them out of the mount into that image.
        for s in starts:
            if s.copies != 'new' and dirs:
                run = COPY_RUN.replace('@D@', next(iter(dirs)))
                if s.copies is None:
                    inserts.append((s.at, run))
                else:
                    lines[s.copies] = run + lines[s.copies][len(lines[s.copies].rstrip('\r\n')):]
                    copied += 1
    for i, run in inserts:
        nl = next((l[len(l.rstrip('\r\n')):] for l in lines if l.endswith('\n')), '\n')
        body = lines[i].rstrip('\r\n')
        lines[i] = f'{body}{nl}{run}{lines[i][len(body):]}'
        copied += 1
    if not drop and not runs and not cached and not copied:
        print(f'unchanged: {path}'); continue
    out = ''.join(l for i, l in enumerate(lines) if i not in drop)
    out = re.sub(r'(\r?\n){3,}', r'\1\1', out)
    open(path, 'w', newline='').write(out)
    print(f'fixed:     {path} (source {", ".join(dict.fromkeys(names))}, {len(runs)} RUN mounted, {cached} cache mount, {copied} runtime package copy)')
PY
