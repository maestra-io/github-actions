#!/usr/bin/env python3
"""Fail a PR whose Dockerfiles, compose files, workflows or Kubernetes manifests bring in
an image nora still holds in quarantine.

Usage: NORA_TOKEN=<token> check-base-images.py <head rev> <base rev>   (run in the repo)
       check-base-images.py --self-test

Renovate holds an external image 3 days only where the registry gives a release date
(Docker Hub). For mcr/ghcr/quay/... the 3-day control is nora's quarantine: `enforce` for
docker since 2026-11-23 13:57Z (fluxcd#30428), so a held digest that merges gets 403 in the
build or on the node. This check stops it before the merge, on pull requests only
(issues-maestra#1649).

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
Renovate externalImages preset, and so is `local/...`, a base image the same build
makes first (service-build `base-image`). A new image from any other registry
(docker.io, ghcr.io, mcr, quay, ...) is not pulled through nora, so no quarantine
covers it: it fails, naming its packages.maestra.io/<prefix>/ path. A bare name
(`FROM upstream`) is a stage or a named build context and only warns.
Compose files (docker-compose*.y*ml, compose*.y*ml, any depth) and workflows/actions are
read for `image:` values (compose `${VAR:-default}` / `${VAR-default}` take the default)
and, in workflows/actions, for any digest-pinned packages.maestra.io image; only
packages.maestra.io references are judged there (ai-assistant-rnd PR 107 merged a held
minio digest through docker-compose.yml, 23.11.2026). They are asked by their tag when
they carry no digest, and never change the Dockerfile not-pinned rule.
Kubernetes manifests, kustomizations and Helm values (any other changed *.y*ml, outside
.github/, .gitlab*, .circleci/, tests/, lock files) are read for what a cluster pulls: a string
`image:` or `*Image:` value (Deployment, CronJob, HelmRelease values `nginxImage`), a
`{repository, tag|digest}` mapping (+ `registry`; + `image` as the last path segment),
a kustomization `images:` entry (`name`/`newName` + `newTag`|`digest`). Under fluxcd's use-nora-pull-through (Kyverno)
the cluster pulls an upstream image as packages.maestra.io/<prefix>/..., so such a
reference is asked in that form (KYVERNO, the policy's own map); a host the policy leaves
alone (our ECR, trow, excludeImages) is not this check's business. Only images new to
that file are judged (an image promoted from another overlay is new there), by tag when
they carry no digest. ponytail: Kyverno's namespace exclusions and the opt-out annotation
are not read, an image without a tag or digest (a kustomize placeholder, a chart default)
and a `{{ }}` template are skipped: fluxcd's own Diff check judges the rendered charts.
"""
import datetime as dt
import fnmatch
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
          re.compile(r"^public\.ecr\.aws/g5f9s8a4/"), re.compile(r"^local/"))
# upstream registry -> nora docker prefix (fluxcd iota/us-iota-lw-kube-infra/nora/helm-release.yaml
# `docker.upstreams`; the same map as maestra-io/soc github-supply.ts DOCKER_PREFIX)
PREFIX = {"docker.io": "docker-hub", "index.docker.io": "docker-hub", "registry-1.docker.io": "docker-hub",
          "ghcr.io": "ghcr", "quay.io": "quay", "registry.k8s.io": "k8s", "k8s.gcr.io": "k8s", "gcr.io": "gcr",
          "mirror.gcr.io": "mirror-gcr", "mcr.microsoft.com": "mcr", "docker.dragonflydb.io": "dragonfly",
          "public.ecr.aws": "ecr-public", "cgr.dev": "cgr", "reg.kyverno.io": "kyverno", "xpkg.upbound.io": "upbound",
          "xpkg.crossplane.io": "crossplane", "europe-west1-docker.pkg.dev": "gar-europe-west1"}
DOCKERFILE = re.compile(r"(^|/)(Dockerfile[^/]*|[^/]+\.[Dd]ockerfile|Containerfile[^/]*)$")
WORKFLOW = re.compile(r"(^\.github/workflows/[^/]+|(^|/)action)\.ya?ml$")
COMPOSE = re.compile(r"(^|/)(docker-)?compose[^/]*\.ya?ml$")
IMAGE_KEY = re.compile(r"^\s*(?:-\s+)?image:\s*[\"']?(?:docker://)?([^\s\"'#]+)")
# fluxcd base/kyverno-nora-pull-through/chart/values.yaml `registries`, `excludeImages` and
# `dockerHubPrefix` @ main b74980c0cc (last change, 2026-11-16): the hosts use-nora-pull-through rewrites
# to packages.maestra.io/<prefix>/ (mirror.gcr.io is Docker Hub there, unlike nora's own
# upstreams above). fluxcd is private and callers' GITHUB_TOKEN cannot read it: a host added
# there is added here next.
KYVERNO = {"docker.io": "docker-hub", "index.docker.io": "docker-hub", "registry-1.docker.io": "docker-hub",
           "mirror.gcr.io": "docker-hub", "ghcr.io": "ghcr", "quay.io": "quay", "registry.k8s.io": "k8s",
           "gcr.io": "gcr", "mcr.microsoft.com": "mcr", "docker.dragonflydb.io": "dragonfly",
           "public.ecr.aws": "ecr-public", "cgr.dev": "cgr", "reg.kyverno.io": "kyverno",
           "xpkg.upbound.io": "upbound", "xpkg.crossplane.io": "crossplane",
           "europe-west1-docker.pkg.dev": "gar-europe-west1"}
KYVERNO_EXCLUDE = ("public.ecr.aws/g5f9s8a4/*",)
MERGE = "tag:yaml.org,2002:merge"
MANIFEST = re.compile(r"\.ya?ml$")
# CI configs, lock files, and chart/kustomize test fixtures (tests/, *_test.yaml): never deployed
NOT_MANIFEST = re.compile(r"(^|/)(\.github/|\.gitlab|\.circleci/|tests?/)|(^|/)[^/]*(-lock|_test)\.ya?ml$")
IMAGE_REF = re.compile(r"^[a-z0-9][a-z0-9._-]*(?::[0-9]+)?(?:/[a-z0-9._-]+)*"
                       r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(?:@sha256:[0-9a-f]{64})?$")
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
    """[(line, image)] of a Dockerfile; for a compose file, a workflow or an action the
    packages.maestra.io images of its `image:` keys, and in a workflow or an action also every
    digest-pinned nora image (mcf-build's DEPS_BASE). ponytail: a workflow image without a
    digest is read only under `image:`, a bare `packages.maestra.io/...` elsewhere is mostly an
    index URL; compose `.env` files and `${VAR:?err}` are not read (the ref stays with its `$`)."""
    if DOCKERFILE.search(path):
        return references(text)
    compose = COMPOSE.search(path)
    if not compose and not WORKFLOW.search(path):
        return []
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        found = [] if compose else PINNED.findall(line)
        m = IMAGE_KEY.match(line)
        if m and "${{" not in m.group(1):
            ref = subst(m.group(1), {})
            if NORA_HOST in ref:
                found.append(ref)
        out += [(n, r) for r in dict.fromkeys(found)]
    return out


def manifest_refs(text):
    """[(line, image)] a Kubernetes manifest, kustomization or Helm values file names."""
    import yaml  # PyYAML: base-images.yml installs it when the runner lacks it
    try:
        docs = list(yaml.compose_all(text, Loader=yaml.SafeLoader))
    except yaml.YAMLError:
        return []  # a Helm template, not YAML yet: its values file holds the images
    out = []

    def scalar(node):  # a non-empty, non-null scalar (`tag: null` is the chart's appVersion)
        return isinstance(node, yaml.ScalarNode) and node.value.strip() and node.tag != "tag:yaml.org,2002:null"

    def keep(node, ref):
        ref = ref.strip()
        if "{{" in ref:
            return
        if "$" in ref:  # Flux postBuild: warned when it names a host nora serves
            if any(h in ref for h in (NORA_HOST, *KYVERNO)):
                out.append((node.start_mark.line + 1, ref))
            return
        name = ref.partition("@")[0]
        if IMAGE_REF.match(ref) and ("@" in ref or name.rfind(":") > name.rfind("/")):
            out.append((node.start_mark.line + 1, ref))

    def merged(node):
        """{key: value node} a mapping takes from its `<<` merge keys; the first source wins."""
        out = {}
        for k, v in node.value:
            if isinstance(k, yaml.ScalarNode) and k.tag == MERGE:
                for src in reversed(v.value if isinstance(v, yaml.SequenceNode) else [v]):
                    if isinstance(src, yaml.MappingNode):
                        out.update(merged(src))
                        out.update((kk.value, vv) for kk, vv in src.value
                                   if isinstance(kk, yaml.ScalarNode) and kk.tag != MERGE)
        return out

    def walk(node, parent=""):
        if isinstance(node, yaml.SequenceNode):
            for n in node.value:
                walk(n, parent)
            return
        if not isinstance(node, yaml.MappingNode):
            return
        pairs = [(k.value, v) for k, v in node.value if isinstance(k, yaml.ScalarNode) and k.tag != MERGE]
        n = {**merged(node), **dict(pairs)}  # `<<: *defaults` under the mapping's own keys
        s = {k: v.value.strip() for k, v in n.items() if scalar(v)}
        tag = f":{s['tag']}" if s.get("tag") else ""
        digest = f"@{s['digest']}" if s.get("digest") else ""
        if s.get("repository") and (tag or digest):  # Helm values, CRs
            # {repository: docker.io/library, image: rabbitmq, tag}: the name is split in two
            name = s["repository"] + (f"/{s['image']}" if s.get("image") else "")
            keep(n["repository"], (f"{s['registry']}/" if s.get("registry") else "") + name + tag + digest)
        elif parent == "images" and s.get("name") and (s.get("newTag") or digest):  # kustomization
            new_tag = f":{s['newTag']}" if s.get("newTag") else ""
            keep(n.get("newName") or n["name"], s.get("newName", s["name"]) + new_tag + digest)
        for k, v in pairs:
            if scalar(v) and k.lower().endswith("image"):
                keep(v, v.value)
            else:
                walk(v, k)

    for doc in docs:
        if doc is not None:
            walk(doc)
    return list(dict.fromkeys(out))  # an alias walks its anchor's nodes again


def pulled_as(ref):
    """The packages.maestra.io reference a cluster pulls for a manifest image: nora's own as
    written, an upstream one as use-nora-pull-through rewrites it, None when it is left alone."""
    if any(fnmatch.fnmatchcase(ref, g) for g in KYVERNO_EXCLUDE):
        return None
    host, repo, tag, digest = split(ref)
    if host == NORA_HOST:
        return ref
    prefix = KYVERNO.get(host)
    if not prefix:
        return None
    if prefix == "docker-hub" and "/" not in repo:
        repo = f"library/{repo}"
    return f"{NORA_HOST}/{prefix}/{repo}" + (f":{tag}" if tag else "") + (f"@{digest}" if digest else "")


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


def direct_fix(ref):
    """The packages.maestra.io reference for an image pulled straight from its registry."""
    host, repo, tag, digest = split(ref)
    prefix = PREFIX.get(host)
    if not prefix:
        return f"{NORA_HOST}/<prefix>/... (nora has no prefix for {host} yet)"
    if prefix == "docker-hub" and "/" not in repo:
        repo = f"library/{repo}"
    return f"{NORA_HOST}/{prefix}/{repo}" + (f":{tag}" if tag else "") + (f"@{digest}" if digest else "")


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
            for p in names if DOCKERFILE.search(p) or WORKFLOW.search(p) or COMPOSE.search(p)}


def manifests(head, base):
    """{path: (head text, base text)} of the changed YAML files that are not workflows or
    compose files: Kubernetes manifests, kustomizations, Helm values."""
    try:
        names = git("diff", "--name-only", "-z", "--diff-filter=d", base, head).decode().split("\0")
    except subprocess.CalledProcessError:  # no base revision: every file is new
        names = git("ls-tree", "-r", "-z", "--name-only", head).decode().split("\0")
    out = {}
    for p in names:
        if not MANIFEST.search(p) or NOT_MANIFEST.search(p) or COMPOSE.search(p) or WORKFLOW.search(p):
            continue
        try:
            old = git("show", f"{base}:{p}").decode(errors="replace")
        except subprocess.CalledProcessError:
            old = ""
        out[p] = (git("show", f"{head}:{p}").decode(errors="replace"), old)
    return out


def main(head, base, out=print):
    new_files, old_files = dockerfiles(head), dockerfiles(base)
    old_by_file = {p: [ref for _, ref in refs_of(p, text)] for p, text in old_files.items()}
    old = {ref for refs in old_by_file.values() for ref in refs}
    # the not-pinned rule reads Dockerfiles and digest-pinned workflow images, as before
    # compose and workflow `image:` keys were read: their tag-only images never relax it
    old_nora = [r for p, refs in old_by_file.items() for r in refs if nora_path(r)
                and (DOCKERFILE.search(p) or (WORKFLOW.search(p) and "@" in r))]
    pins = bool(old_nora) and all("@" in r for r in old_nora)
    asks, failures = {}, 0
    for path, text in sorted(new_files.items()):
        for line, ref in refs_of(path, text):
            if ref in old or any(e.match(ref) for e in EXEMPT):
                continue
            at = f"file={path},line={line}"
            if "$" in ref:
                out(f"::warning {at}::{ref}: a variable the file gives no default; not checked")
            elif not nora_path(ref) and not re.search(r"[/:@]", ref):
                out(f"::warning {at}::{ref}: a stage or a named build context, not checked")
            elif not nora_path(ref):
                failures += 1
                out(f"::error {at},title=base image not through nora::{ref} is pulled straight from its "
                    f"registry, around nora's 3-day quarantine: use {direct_fix(ref)} (issues-maestra#1649)")
            elif "@" not in ref and pins and DOCKERFILE.search(path):
                failures += 1
                out(f"::error {at},title=base image not pinned::{ref} has no @sha256 digest, and every "
                    f"other {NORA_HOST} image of this repo has one: pin it as <tag>@sha256:<digest>")
            else:
                asks.setdefault(nora_path(ref), []).append((at, ref))
    for path, (text, old_text) in sorted(manifests(head, base).items()):
        before = {ref for _, ref in manifest_refs(old_text)}
        for line, ref in manifest_refs(text):
            at = f"file={path},line={line}"
            if ref in before:
                continue
            if "$" in ref:
                out(f"::warning {at}::{ref}: a variable the file gives no default; not checked")
            elif pulled_as(ref):
                asks.setdefault(nora_path(pulled_as(ref)), []).append((at, pulled_as(ref)))
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
    # compose files at any depth (ai-assistant-rnd PR 107: a held minio digest, plain and as a
    # ${VAR:-default}); only nora images, a direct one is not this check's business
    m = "packages.maestra.io/cgr/chainguard/"
    cbase = {"Dockerfile": f"FROM {n}mature:1{d}\n",
             "docker-compose.yml": f"services:\n  minio:\n    image: {m}mature-minio{d}\n",
             "tests_functional/tests/docker-compose.yml":
                 f"services:\n  minio:\n    image: ${{TEST_MINIO_IMAGE:-{m}mature-minio{d}}}\n"}
    rc, log = run(cbase, {**cbase, "docker-compose.yml": f"services:\n  minio:\n    image: {m}held-minio{d}\n"})
    assert rc == 1 and "file=docker-compose.yml,line=3,title=base image in nora quarantine" in log, log
    rc, log = run(cbase, {**cbase, "tests_functional/tests/docker-compose.yml":
                          f"services:\n  minio:\n    # x\n    image: \"${{TEST_MINIO_IMAGE:-{m}held-minio{d}}}\"\n"})
    assert rc == 1 and "file=tests_functional/tests/docker-compose.yml,line=4" in log and "until 2026-11-13" in log, log
    seen.clear()
    rc, log = run(cbase, {**cbase, "deploy/compose.override.yaml":
                          f"services:\n  db:\n    image: postgres:17\n  x:\n    image: ${{X_IMAGE}}\n"
                          f"  y:\n    image: {m}y:${{TAG}}\n  z:\n    image: {m}mature-z{d}\n"})
    assert rc == 0 and "file=deploy/compose.override.yaml,line=7" in log and "postgres" not in log, log
    assert [p for p, *_ in seen if "mature-z" in p], seen
    assert refs_of("docs/compose.md", f"image: {m}held{d}") == []
    # an unchanged held compose image is not new; a tag-only one is asked, never "not pinned"
    held_c = {**cbase, "docker-compose.yml": f"services:\n  minio:\n    image: {m}held-minio{d}\n"}
    assert run(held_c, {**held_c, "Dockerfile": f"FROM {n}mature:1{d}\nRUN true\n"})[0] == 0
    rc, log = run(cbase, {**cbase, "compose.yaml": f"services:\n  a:\n    image: {m}mature-a:1\n"})
    assert rc == 0 and "not pinned" not in log, log
    # a tag-only compose image in the base does not relax the Dockerfile not-pinned rule
    tag_c = {**cbase, "compose.yaml": f"services:\n  a:\n    image: {m}mature-a:1\n"}
    rc, log = run(tag_c, {**tag_c, "Dockerfile": f"FROM {n}mature:3\n"})
    assert rc == 1 and "not pinned" in log, log
    # workflow job `services:` / `container:` images: tag-only nora images are read too
    rc, log = run(base, {**base, ".github/workflows/ci.yml":
                         f"jobs:\n  t:\n    container:\n      image: {n}mature:8{d}\n    services:\n"
                         f"      db:\n        image: '{n}held-pg:17'\n      r:\n        image: ${{{{ inputs.img }}}}\n"})
    assert rc == 1 and "file=.github/workflows/ci.yml,line=7" in log and f"ok       {n}mature:8{d}" in log, log
    assert log.count(f"{n}mature:8{d}") == 1, log  # one line, one ask: PINNED and image: agree
    # Kubernetes manifests: upstream names as Kyverno's use-nora-pull-through rewrites them
    # (ai-assistant-rnd PR 107 also moved a cgr.dev digest in a HelmRelease's `nginxImage`)
    h = "sha256:" + "2" * 64
    hr = f"""apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
spec:
  values:
    container:
      nginxImage: cgr.dev/chainguard/nginx:latest@{{}}
      image:
        repository: docker.io/darthsim/imgproxy
        tag: v4.0.14
        digest: {h}
"""
    mbase = {**base, "kustomization/base/helm-release-imgproxy.yaml": hr.format("sha256:" + "3" * 64)}
    seen.clear()
    rc, log = run(mbase, {**mbase, "kustomization/base/helm-release-imgproxy.yaml": hr.format(h).replace(
        "chainguard/nginx", "chainguard/held-nginx")})
    assert rc == 1 and "file=kustomization/base/helm-release-imgproxy.yaml,line=6,title=base image in nora quarantine" \
        in log and f"packages.maestra.io/cgr/chainguard/held-nginx:latest@{h}" in log, log
    assert ("/v2/cgr/chainguard/held-nginx/manifests/" + h, "only-if-cached", "Bearer t") in seen, seen
    assert not [p for p, *_ in seen if "imgproxy" in p], seen  # unchanged in the file: not asked
    rc, log = run(mbase, {**mbase, "kustomization/base/helm-release-imgproxy.yaml": hr.format(h)})
    assert rc == 0 and "ok       packages.maestra.io/cgr/chainguard/nginx:latest@" in log, log
    # {repository, tag|digest} (+ registry), a kustomization `images:` entry, a plain Deployment
    seen.clear()
    rc, log = run(mbase, {**mbase, "deploy/values.yaml":
                          f"redis:\n  image:\n    registry: docker.io\n    repository: bitnami/held-redis\n    tag: '7.4'\n"
                          f"pg:\n  image:\n    repository: ghcr.io/cloudnative-pg/held-pg\n    tag: 17\n    digest: {h}\n"
                          f"mq:\n  image:\n    repository: docker.io/library\n    image: held-mq\n    tag: '3.13@{h}'\n",
                          "kustomization/overlays/omega/kustomization.yaml":
                          f"images:\n  - name: app\n    newName: quay.io/x/held-k\n    digest: {h}\n"
                          "  - name: 515260921971.dkr.ecr.us-west-2.amazonaws.com/svc\n    newTag: '1.2'\n",
                          "kustomization/base/cronjob.yaml":
                          "kind: CronJob\nspec:\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n"
                          f"            - name: c\n              image: mcr.microsoft.com/dotnet/held-runtime:10.0@{h}\n"
                          f"            - name: m\n              image: mirror.gcr.io/library/held-busybox:1.37\n"})
    for want in ("file=deploy/values.yaml,line=4", "file=deploy/values.yaml,line=8", "file=deploy/values.yaml,line=13",
                 "file=kustomization/overlays/omega/kustomization.yaml,line=3",
                 "file=kustomization/base/cronjob.yaml,line=9", "file=kustomization/base/cronjob.yaml,line=11"):
        assert f"{want},title=base image in nora quarantine" in log, (want, log)
    for want in ("/v2/docker-hub/bitnami/held-redis/manifests/7.4", f"/v2/ghcr/cloudnative-pg/held-pg/manifests/{h}",
                 f"/v2/docker-hub/library/held-mq/manifests/{h}",
                 f"/v2/quay/x/held-k/manifests/{h}", f"/v2/mcr/dotnet/held-runtime/manifests/{h}",
                 "/v2/docker-hub/library/held-busybox/manifests/1.37"):
        assert any(p == want for p, *_ in seen), (want, seen)
    assert rc == 1 and not [p for p, *_ in seen if "svc" in p], seen
    # YAML merge keys: `<<: *defaults` supplies the repository, the mapping its own tag
    rc, log = run(mbase, {**mbase, "deploy/merge.yaml":
                          "defaults: &d {repository: ghcr.io/x/base, tag: '1'}\n"
                          "image: {<<: *d, repository: ghcr.io/x/held-merge}\nother: {<<: [*d], tag: '2'}\n"})
    assert rc == 1 and "file=deploy/merge.yaml,line=2,title=base image in nora quarantine" in log, log
    assert "packages.maestra.io/ghcr/x/held-merge:1 " in log and "packages.maestra.io/ghcr/x/base:2 " in log, log
    # an image already in another file is still new to this one (an omicron digest promoted to omega)
    held_m = {**mbase, "kustomization/overlays/omicron/values.yaml": f"image: ghcr.io/x/held-a:1@{h}\n"}
    rc, log = run(held_m, {**held_m, "kustomization/overlays/omega/values.yaml": f"image: ghcr.io/x/held-a:1@{h}\n"})
    assert rc == 1 and "file=kustomization/overlays/omega/values.yaml,line=1" in log and "omicron" not in log, log
    # left alone: hosts Kyverno does not rewrite, its excludeImages, no tag/digest, null tags,
    # templates, test fixtures, CI configs, a file that is not YAML yet; a ${VAR} warns
    seen.clear()
    rc, log = run(mbase, {**mbase, "k/a.yaml":
                          "a:\n  image: 515260921971.dkr.ecr.us-west-2.amazonaws.com/x:1\n"
                          "b:\n  image: public.ecr.aws/g5f9s8a4/held:1\nc:\n  image: registry.example.com/held:1\n"
                          "d:\n  image: app\ne:\n  image:\n    repository: ghcr.io/x/held\n    tag: null\n"
                          "f:\n  image: \"{{ .Values.image }}\"\ng:\n  defaultImage: ghcr.io/x/held:${TAG}\n"
                          "h:\n  repository: maestra-io/github-actions\n  ref: main\n",
                          "chart/tests/values.yaml": "image: busybox-held:1\n",
                          "chart/templates/d.yaml": "{{- if .Values.x }}\nimage: ghcr.io/x/held:1\n{{- end }}\n",
                          ".gitlab-ci.yml": "image: held-python:3.12\n"})
    assert rc == 0 and not seen and "file=k/a.yaml,line=16" in log and log.count("::warning") == 1, log
    # tag only: not pinned where the repo pins, asked where it does not
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:3\n"})
    assert rc == 1 and "not pinned" in log, log
    assert run({"Dockerfile": f"FROM {n}mature:1\n"}, {"Dockerfile": f"FROM {n}mature:3\n"})[0] == 0
    assert run({"Dockerfile": f"FROM {n}mature:1\n"}, {"Dockerfile": f"FROM {n}held:3\n"})[0] == 1
    # exempt and direct registries never ask nora; ours and local/ pass, a direct one fails
    seen.clear()
    rc, log = run(base, {"Dockerfile": "FROM 515260921971.dkr.ecr.us-west-2.amazonaws.com/x:1\n"
                                       "FROM public.ecr.aws/g5f9s8a4/y:1\nFROM local/base:latest\n"})
    assert rc == 0 and not seen and "::" not in log, log
    uv = "ghcr.io/astral-sh/uv:0.13.9@sha256:" + "d" * 64
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:1{d}\nRUN --mount=type=bind,from={uv},source=/uv,target=/uv true\n"
                                       "FROM mcr.microsoft.com/dotnet/sdk:10.0\nCOPY --from=nginx:1.27 / /\nFROM registry.example.com/x/y:1\n"})
    assert rc == 1 and not seen and log.count("title=base image not through nora") == 4, log
    assert "file=Dockerfile,line=2" in log and f"use {NORA_HOST}/ghcr/astral-sh/uv:0.13.9@sha256:" in log, log
    assert f"use {NORA_HOST}/mcr/dotnet/sdk:10.0 " in log and f"use {NORA_HOST}/docker-hub/library/nginx:1.27 " in log, log
    assert "no prefix for registry.example.com yet" in log, log
    # a bare name is a stage or a named build context (bake `contexts`): it warns, never fails
    rc, log = run(base, {"Dockerfile": f"FROM {n}mature:1{d}\nFROM upstream\n"})
    assert rc == 0 and "named build context" in log, log
    # a direct image the base already has is not new: a PR that leaves it alone passes
    assert run({"Dockerfile": f"FROM {uv}\n"}, {"Dockerfile": f"FROM {uv}\nRUN true\n"})[0] == 0
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
