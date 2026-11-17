#!/usr/bin/env python3
"""Fail a PR whose Dockerfiles bring in a base image nora still holds in quarantine.

Usage: NORA_TOKEN=<token> check-base-images.py <head rev> <base rev>   (run in the repo)
       check-base-images.py --self-test

Renovate holds an external image 3 days only where the registry gives a release date
(Docker Hub). For mcr/ghcr/quay/... the 3-day control is nora's quarantine, and under
`observe` nothing blocks: a 15-hour-old .NET digest reached ~100 repos in one day
(issues-maestra#1649). This check is that block, on pull requests only.

Every `FROM`, `COPY/ADD --from=` and `RUN --mount=...,from=` image of every Dockerfile
in the PR head (Dockerfile*, *.Dockerfile, *.dockerfile, Containerfile*) is read, global
and stage ARG defaults substituted. A reference the base revision does not have is new;
only new references are judged, so a PR that leaves its images alone never turns red.
For each new packages.maestra.io/<prefix>/... reference nora is asked for its digest
(the tag when there is none) with `Cache-Control: only-if-cached`: nora answers from
what it holds and never asks the upstream, so this check never starts a digest's
3-day clock itself (nora docker-only-if-cached). nora is the authority:
- 200/403 + `x-nora-quarantine: new|pending`: held until `x-nora-quarantine-until`. Fails.
- 200 + `mature`, `exception` (a digest exception in fluxcd
  iota/us-iota-lw-kube-infra/nora/quarantine-exceptions.yaml, the break-glass), or no
  header (quarantine off): passes.
- 504: nora has never pulled it, its quarantine has not started. Fails.
- 403 without the header: refused by another curation rule. Fails.
- 404: no such image in nora. Fails.
- Anything else (no answer, 401, 5xx after retries) and a nora that ignores
  only-if-cached: an ERROR of the check, never a pass: fails with its own message.
A new tag-only reference fails as not pinned when every nora reference of the base
revision already carries a digest (the repo pins); otherwise its tag is asked.
Our images (ECR 515260921971, public.ecr.aws/g5f9s8a4) are exempt, as in the
Renovate externalImages preset; other registries are not pulled through nora and get
a warning only.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

NORA_HOST = "packages.maestra.io"
EXEMPT = (re.compile(r"^515260921971\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/"),
          re.compile(r"^public\.ecr\.aws/g5f9s8a4/"))
DOCKERFILE = re.compile(r"(^|/)(Dockerfile[^/]*|[^/]+\.[Dd]ockerfile|Containerfile[^/]*)$")
WORKFLOW = re.compile(r"(^\.github/workflows/[^/]+|(^|/)action)\.ya?ml$")
PINNED = re.compile(r"packages\.maestra\.io/[A-Za-z0-9._/-]+(?::[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}")
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
HELD = {"new", "pending"}
EXCEPTIONS = "fluxcd iota/us-iota-lw-kube-infra/nora/quarantine-exceptions.yaml"
VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?::?([-+])([^}]*))?\}|([A-Za-z_][A-Za-z0-9_]*))")


def subst(s, env):
    """${A}, $A, ${A:-x}, ${A:+x} from env; an unknown variable stays as written."""
    def one(m):
        name = m.group(1) or m.group(4)
        val = env.get(name)
        if m.group(2) == "-":
            return val if val else m.group(3)
        if m.group(2) == "+":
            return m.group(3) if val else ""
        return val if val is not None else m.group(0)
    return VAR.sub(one, s)


def arg_defaults(rest):
    """`ARG A=1 B="2" C` -> {A: 1, B: 2, C: None}."""
    out = {}
    for tok in re.findall(r'[^\s"\']+(?:=(?:"[^"]*"|\'[^\']*\'|\S*))?', rest):
        k, eq, v = tok.partition("=")
        out[k] = v.strip("\"'") if eq else None
    return out


def logical_lines(text):
    """(first line number, instruction) with comment lines dropped and `\\` joined."""
    out, buf, start = [], [], 0
    for n, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("#"):
            continue  # a comment, or a parser directive (# syntax=): not an instruction
        if not buf:
            start = n
        if line.rstrip().endswith("\\"):
            buf.append(line.rstrip()[:-1])
            continue
        buf.append(line)
        joined = " ".join(buf).strip()
        buf = []
        if joined:
            out.append((start, joined))
    if buf and " ".join(buf).strip():
        out.append((start, " ".join(buf).strip()))
    return out


def references(text):
    """[(line, image)] of every image a Dockerfile pulls (stages and `scratch` left out).
    ponytail: --build-arg overrides and heredoc bodies are not read; an ARG-built name
    that stays unresolved is returned with its `$` and reported, not asked."""
    globals_, stage_env, stages, refs = {}, None, set(), []

    def image(line, ref, env):
        ref = subst(ref.strip("\"'"), env)
        if not ref or ref.lower() == "scratch" or ref.lower() in stages or ref.isdigit():
            return
        refs.append((line, ref))

    for line, ins in logical_lines(text):
        word, _, rest = ins.partition(" ")
        word = word.upper()
        if word == "ARG":
            defaults = arg_defaults(rest)
            if stage_env is None:
                globals_.update({k: subst(v, globals_) if v else v for k, v in defaults.items()})
            else:
                for k, v in defaults.items():  # a bare ARG re-declares the global value
                    stage_env[k] = subst(v, stage_env) if v is not None else globals_.get(k)
        elif word == "FROM":
            toks = [t for t in rest.split() if not t.startswith("--")]
            if toks:
                image(line, toks[0], globals_)
            if len(toks) >= 3 and toks[1].lower() == "as":
                stages.add(toks[2].lower())
            stage_env = {}
        elif word in ("COPY", "ADD", "RUN"):
            env = {**globals_, **{k: v for k, v in (stage_env or {}).items() if v is not None}}
            for kind, val in re.findall(r"--(from|mount)=(\S+)", rest):
                if kind == "from":
                    image(line, val, env)
                else:  # --mount=type=bind,from=X,source=...
                    opts = dict(o.partition("=")[::2] for o in val.split(","))
                    if opts.get("from"):
                        image(line, opts["from"], env)
    return refs


def refs_of(path, text):
    """[(line, image)] of a Dockerfile, or the digest-pinned nora images a workflow or an
    action names (a job `container:`, mcf-build's DEPS_BASE). ponytail: a workflow image
    without a digest is not read, a bare `packages.maestra.io/...` there is mostly an index URL."""
    if DOCKERFILE.search(path):
        return references(text)
    if not WORKFLOW.search(path):
        return []
    return [(n, m) for n, line in enumerate(text.splitlines(), 1) for m in PINNED.findall(line)]


def split(ref):
    """(host, repo, tag, digest) of an image reference."""
    name, _, digest = ref.partition("@")
    slash, colon = name.rfind("/"), name.rfind(":")
    tag = name[colon + 1:] if colon > slash else ""
    name = name[:colon] if colon > slash else name
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        return first.lower(), rest, tag, digest
    return "docker.io", name, tag, digest


def nora_path(ref):
    """`<prefix>/<repo>/manifests/<digest|tag>` for a packages.maestra.io image, else None."""
    host, repo, tag, digest = split(ref)
    if host != NORA_HOST or "/" not in repo:
        return None
    prefix, _, rest = repo.partition("/")
    if prefix == "docker-hub" and "/" not in rest:
        repo = f"docker-hub/library/{rest}"
    return f"{repo}/manifests/{digest or tag or 'latest'}"


def ask(base, token, path, tries=3):
    """(status, headers, body) of one manifest HEAD; 0 = no answer. 5xx/no answer retried."""
    req = urllib.request.Request(f"{base}/v2/{path}", method="HEAD", headers={
        "Authorization": f"Bearer {token}", "Accept": ACCEPT, "Cache-Control": "only-if-cached"})
    for i in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.headers, b""
        except urllib.error.HTTPError as e:
            res = (e.code, e.headers, e.read())
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            res = (0, {}, str(e).encode())
        if res[0] != 0 and res[0] < 500 or res[0] == 504:
            return res
        if i + 1 < tries:
            time.sleep(2 * (i + 1))
    return res


def until_of(headers, body):
    t = headers.get("x-nora-quarantine-until")
    if not t:
        try:
            t = json.loads(body)["errors"][0]["detail"]["quarantine_until"]
        except (ValueError, KeyError, IndexError, TypeError):
            return None
    try:
        return dt.datetime.fromtimestamp(int(t), dt.timezone.utc)
    except (TypeError, ValueError, OverflowError):
        return None


def verdict(status, headers, body):
    """('ok'|'held'|'unseen'|'refused'|'missing'|'error', detail) of one nora answer."""
    q = (headers.get("x-nora-quarantine") or "").lower()
    if status in (200, 403) and q in HELD:
        until = until_of(headers, body)
        return "held", f"{until:%Y-%m-%d %H:%M} UTC" if until else "an unknown time (nora gives none)"
    if status == 200:
        return "ok", q or "served"
    if status == 504:
        return "unseen", ""
    if status == 403:
        return "refused", headers.get("x-nora-reason") or body.decode(errors="replace")[:200]
    if status == 404:
        return "missing", ""
    return "error", f"HTTP {status} {body.decode(errors='replace')[:200]}".strip()


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def dockerfiles(rev):
    """{path: text} of the Dockerfiles, workflows and actions at `rev`; {} for no such revision."""
    try:
        names = git("ls-tree", "-r", "-z", "--name-only", rev).decode().split("\0")
    except subprocess.CalledProcessError:
        return {}
    return {p: git("show", f"{rev}:{p}").decode(errors="replace")
            for p in names if DOCKERFILE.search(p) or WORKFLOW.search(p)}


def main(head, base, out=print):
    new_files, old_files = dockerfiles(head), dockerfiles(base)
    old = {ref for p, text in old_files.items() for _, ref in refs_of(p, text)}
    old_nora = [r for r in old if nora_path(r)]
    pins = bool(old_nora) and all("@" in r for r in old_nora)
    asks, failures = {}, 0
    for path, text in sorted(new_files.items()):
        for line, ref in refs_of(path, text):
            if ref in old or any(e.match(ref) for e in EXEMPT):
                continue
            at = f"file={path},line={line}"
            if "$" in ref:
                out(f"::warning {at}::{ref}: a build-arg the Dockerfile gives no default; not checked")
            elif not nora_path(ref):
                out(f"::warning {at}::{ref} is not pulled through {NORA_HOST}: nora's quarantine "
                    f"does not cover it. Use {NORA_HOST}/<prefix>/... (issues-maestra#1649)")
            elif "@" not in ref and pins:
                failures += 1
                out(f"::error {at},title=base image not pinned::{ref} has no @sha256 digest, and every "
                    f"other {NORA_HOST} image of this repo has one: pin it as <tag>@sha256:<digest>")
            else:
                asks.setdefault(nora_path(ref), []).append((at, ref))
    if not asks:
        out(f"base images: no new {NORA_HOST} image" + (", but see above" if failures else ""))
        return 1 if failures else 0
    token = os.environ.get("NORA_TOKEN")
    base_url = os.environ.get("NORA_URL", f"https://{NORA_HOST}").rstrip("/")
    if not token:
        out("::error title=nora check error::no nora token: the base-image check could not run")
        return 1
    # A nora that ignores only-if-cached would fetch an unseen digest from the upstream and
    # start its clock: ask for a digest that exists nowhere first; only 504 proves the probe.
    probe = next(iter(asks)).split("/manifests/")[0] + "/manifests/sha256:" + "0" * 64
    status, _, body = ask(base_url, token, probe)
    if status != 504:
        out(f"::error title=nora check error::nora answered HTTP {status} to an only-if-cached probe "
            f"(504 expected): {'nora is unreachable' if status in (0, 401) or status >= 500 else 'this nora ignores only-if-cached'}; "
            f"the base-image check could not run and fails closed. Re-run it; {body.decode(errors='replace')[:200]}")
        return 1
    for path, where in sorted(asks.items()):
        kind, detail = verdict(*ask(base_url, token, path))
        for at, ref in where:
            out(f"{kind:8} {ref}" + (f" ({detail})" if detail else ""))
            if kind == "ok":
                if detail == "exception":
                    out(f"::notice {at}::{ref} is held by nora's quarantine, admitted by a digest "
                        f"exception in {EXCEPTIONS}")
                continue
            failures += 1
            if kind == "held":
                out(f"::error {at},title=base image in nora quarantine::{ref} is held by nora's 3-day "
                    f"quarantine until {detail}. This is a wait, not a breakage: re-run this check after "
                    f"that time. Do not pin another digest to get past it; an emergency goes through a "
                    f"digest exception in {EXCEPTIONS}")
            elif kind == "unseen":
                out(f"::error {at},title=base image unknown to nora::nora has never pulled {ref}: its 3-day "
                    f"quarantine has not started. Pull it once (docker pull {ref}), then re-run this "
                    f"check when nora says it matured (3 days)")
            elif kind == "refused":
                out(f"::error {at},title=base image refused by nora::nora refuses {ref}: {detail}")
            elif kind == "missing":
                out(f"::error {at},title=base image not found::nora has no {ref} (HTTP 404)")
            else:
                out(f"::error {at},title=nora check error::nora gave no verdict on {ref} ({detail}): the "
                    f"base-image check could not run and fails closed. Re-run it")
    out(f"base images: {sum(map(len, asks.values()))} new {NORA_HOST} image(s), {failures} failing")
    return 1 if failures else 0


def self_test():
    import http.server
    import tempfile
    import threading

    df = r"""# syntax=docker/dockerfile:1
ARG REGISTRY=packages.maestra.io
ARG DOTNET=10.0
# FROM packages.maestra.io/mcr/commented/out:1
FROM --platform=$BUILDPLATFORM ${REGISTRY}/mcr/dotnet/sdk:${DOTNET}@sha256:aa AS build
ARG REGISTRY
ARG TOOLS=${REGISTRY}/ghcr/x/tools:2
COPY --from=build /a /b
COPY --from=0 /a /b
COPY --from=$TOOLS /bin/t /t
RUN --mount=type=cache,target=/c \
    --mount=type=bind,from=packages.maestra.io/quay/y/lib:3,source=/l,target=/l \
    make
FROM build as publish
FROM Build AS other
FROM scratch
FROM ${MISSING}/x:1
FROM ${MISSING:-docker.io}/library/nginx:1.27 AS web
COPY --from=nginx:1.27 /etc/nginx /etc/nginx
"""
    got = references(df)
    want = [(5, "packages.maestra.io/mcr/dotnet/sdk:10.0@sha256:aa"),
            (10, "packages.maestra.io/ghcr/x/tools:2"),
            (11, "packages.maestra.io/quay/y/lib:3"),
            (17, "${MISSING}/x:1"),
            (18, "docker.io/library/nginx:1.27"),
            (19, "nginx:1.27")]
    assert got == want, got
    assert references("from alpine:3\nrun --mount=from=packages.maestra.io/k8s/z:1 true\n") == \
        [(1, "alpine:3"), (2, "packages.maestra.io/k8s/z:1")]
    assert subst("${A:+set}${B:-dflt}$A", {"A": "1"}) == "setdflt1"
    for ref, want in {
        "packages.maestra.io/mcr/dotnet/aspnet:10.0@sha256:bf": "mcr/dotnet/aspnet/manifests/sha256:bf",
        "packages.maestra.io/mcr/dotnet/aspnet:10.0": "mcr/dotnet/aspnet/manifests/10.0",
        "packages.maestra.io/docker-hub/nginx": "docker-hub/library/nginx/manifests/latest",
        "packages.maestra.io/docker-hub/bitnami/redis:7": "docker-hub/bitnami/redis/manifests/7",
        "packages.maestra.io:443/x/y:1": None,
        "mcr.microsoft.com/dotnet/sdk:10.0": None,
        "nginx:1.27": None,
    }.items():
        assert nora_path(ref) == want, (ref, nora_path(ref))

    seen = []

    class Stub(http.server.BaseHTTPRequestHandler):
        def do_HEAD(self):
            p = self.path
            seen.append((p, self.headers.get("Cache-Control"), self.headers.get("Authorization")))
            hdr = {}
            if "sha256:" + "0" * 64 in p:
                code = 504 if "oldnora" not in p else 404
            elif "held" in p:
                code, hdr = 200, {"x-nora-quarantine": "pending", "x-nora-quarantine-until": "1794585600"}
            elif "enforced" in p:
                code, hdr = 403, {"x-nora-quarantine": "pending", "x-nora-quarantine-until": "1794585600"}
            elif "excepted" in p:
                code, hdr = 200, {"x-nora-quarantine": "exception"}
            elif "mature" in p:
                code, hdr = 200, {"x-nora-quarantine": "mature"}
            elif "unseen" in p:
                code = 504
            elif "blocked" in p:
                code, hdr = 403, {"x-nora-reason": "blocklist"}
            elif "gone" in p:
                code = 404
            elif "down" in p:
                code = 503
            else:
                code = 200
            self.send_response(code)
            for k, v in hdr.items():
                self.send_header(k, v)
            self.end_headers()

        def log_message(self, *_):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    os.environ.update({"NORA_URL": f"http://127.0.0.1:{srv.server_port}", "NORA_TOKEN": "t"})

    repo = tempfile.mkdtemp()
    os.chdir(repo)
    for c in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
        git(*c)

    def commit(files):
        git("rm", "-rq", "--ignore-unmatch", ".")
        for p, text in files.items():
            os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
        git("add", "-A")
        git("commit", "-q", "--allow-empty", "-m", "x")
        return git("rev-parse", "HEAD").decode().strip()

    d = "@sha256:" + "1" * 64
    n = "packages.maestra.io/mcr/"

    def run(base_files, head_files):
        b = commit(base_files)
        h = commit(head_files)
        lines = []
        rc = main(h, b, lines.append)
        return rc, "\n".join(lines)

    base = {"Dockerfile": f"FROM {n}mature:1{d}\n"}
    assert run(base, {"Dockerfile": f"FROM {n}held:1{d}\n"})[0] == 1
    rc, log = run(base, {"Dockerfile": f"FROM {n}held:1{d}\n"})
    assert "until 2026-11-13 16:00 UTC" in log and f"{n}held:1{d}" in log and "wait, not a breakage" in log, log
    assert ("/v2/mcr/held/manifests/sha256:" + "1" * 64, "only-if-cached", "Bearer t") in seen, seen
    assert run(base, {"Dockerfile": f"FROM {n}enforced:1{d}\n"})[0] == 1
    assert run(base, {"Dockerfile": f"FROM {n}mature:2{d}\n"})[0] == 0
    rc, log = run(base, {"Dockerfile": f"FROM {n}excepted:1{d}\n"})
    assert rc == 0 and "::notice" in log, log
    rc, log = run(base, {"Dockerfile": f"FROM {n}unseen:1{d}\n"})
    assert rc == 1 and "never pulled" in log, log
    assert run(base, {"Dockerfile": f"FROM {n}blocked:1{d}\n"})[0] == 1
    assert run(base, {"Dockerfile": f"FROM {n}gone:1{d}\n"})[0] == 1
    rc, log = run(base, {"Dockerfile": f"FROM {n}down:1{d}\n"})
    assert rc == 1 and "nora check error" in log and "fails closed" in log, log
    # unchanged references are not asked, even when held: a PR that leaves images alone passes
    held_base = {"Dockerfile": f"FROM {n}held:1{d}\nRUN true\n"}
    seen.clear()
    assert run(held_base, {"Dockerfile": f"FROM {n}held:1{d}\nRUN echo\n"})[0] == 0
    assert not seen, seen
    # a new file, a second Dockerfile, a multi-stage chain: every new image is asked
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:1{d}\n",
                         "deploy/worker.Dockerfile": f"FROM {n}mature:1{d} AS b\nCOPY --from={n}held:9{d} / /\n"})
    assert rc == 1 and "file=deploy/worker.Dockerfile,line=2" in log, log
    # a digest-pinned image in a workflow or an action (mcf-build DEPS_BASE, a job container)
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:1{d}\n",
                         ".github/workflows/build.yml": f"env:\n  DEPS_BASE: {n}held:2{d}\n  X: {n}simple/\n",
                         "x/action.yml": f"image: docker://{n}mature:7{d}\n"})
    assert rc == 1 and "file=.github/workflows/build.yml,line=2" in log and f"ok       {n}mature:7" in log, log
    assert refs_of("README.md", f"{n}held:2{d}") == []  # neither a Dockerfile nor a workflow
    # tag only: not pinned where the repo pins, asked where it does not
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:3\n"})
    assert rc == 1 and "not pinned" in log, log
    assert run({"Dockerfile": f"FROM {n}mature:1\n"}, {"Dockerfile": f"FROM {n}mature:3\n"})[0] == 0
    assert run({"Dockerfile": f"FROM {n}mature:1\n"}, {"Dockerfile": f"FROM {n}held:3\n"})[0] == 1
    # exempt and direct registries never ask nora; a direct one warns
    seen.clear()
    rc, log = run(base, {"Dockerfile": "FROM 515260921971.dkr.ecr.us-west-2.amazonaws.com/x:1\n"
                                       "FROM public.ecr.aws/g5f9s8a4/y:1\nFROM mcr.microsoft.com/dotnet/sdk:10.0\n"})
    assert rc == 0 and not seen and log.count("::warning") == 1, log
    # a nora that ignores only-if-cached, no token: errors of the check, never a pass
    rc, log = run(base, {"Dockerfile": f"FROM packages.maestra.io/oldnora/x:1{d}\n"})
    assert rc == 1 and "ignores only-if-cached" in log, log
    os.environ.pop("NORA_TOKEN")
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:4{d}\n"})
    assert rc == 1 and "no nora token" in log, log
    os.environ["NORA_TOKEN"] = "t"
    srv.shutdown()
    srv.server_close()
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:5{d}\n"})
    assert rc == 1 and "nora is unreachable" in log, log
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    else:
        sys.exit(__doc__)
