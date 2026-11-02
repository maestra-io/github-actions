#!/usr/bin/env python3
"""Prewarm external images in nora (see action.yml). `--self-test` runs the checks.

Env: IMAGES (newline list), FLATE_DIFF (path), NORA_URL, NORA_AUDIENCE, the runner's
ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}, GITHUB_STEP_SUMMARY.
"""
import json
import os
import sys
import urllib.error
import urllib.request

# Upstream host -> nora prefix. Same map as fluxcd
# base/kyverno-nora-pull-through/chart/values.yaml `registries`: a host missing
# here is not pulled through nora by the clusters, so it is not prewarmed either.
PREFIXES = {
    "docker.io": "docker-hub",
    "index.docker.io": "docker-hub",
    "registry-1.docker.io": "docker-hub",
    "mirror.gcr.io": "docker-hub",
    "ghcr.io": "ghcr",
    "quay.io": "quay",
    "registry.k8s.io": "k8s",
    "gcr.io": "gcr",
    "mcr.microsoft.com": "mcr",
    "docker.dragonflydb.io": "dragonfly",
    "public.ecr.aws": "ecr-public",
    "cgr.dev": "cgr",
    "reg.kyverno.io": "kyverno",
    "xpkg.upbound.io": "upbound",
    "xpkg.crossplane.io": "crossplane",
}
EXCLUDED = ("public.ecr.aws/g5f9s8a4/",)  # our own public ECR (Kyverno excludeImages)
NORA_HOST = "packages.maestra.io"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def nora_paths(image):
    """`<prefix>/<repo>/manifests/<ref>` for an external image, else []. A `tag@digest`
    asks for the tag first: nora dates a tag pull by the registry's own push date
    (`trust_upstream_dates`: Docker Hub, quay), which a digest pull cannot carry, and the
    digest pull after it finds the digest already dated."""
    image = image.strip()
    if not image or "$" in image or any(image.startswith(e) for e in EXCLUDED):
        return []
    name, _, digest = image.partition("@")
    slash, colon = name.rfind("/"), name.rfind(":")
    tag = name[colon + 1:] if colon > slash else ""
    name = name[:colon] if colon > slash else name
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, repo = first, rest
    else:
        host, repo = "docker.io", name
    if host == NORA_HOST:
        prefix, _, repo = repo.partition("/")
    else:
        prefix = PREFIXES.get(host)
    if not prefix or not repo:
        return []
    if prefix == "docker-hub" and "/" not in repo:
        repo = f"library/{repo}"
    refs = [tag, digest] if tag and digest else [digest or tag or "latest"]
    return [f"{prefix}/{repo}/manifests/{ref}" for ref in refs]


def images_in(obj, out):
    """Every string under an `image` key, anywhere in a manifest object."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "image" and isinstance(v, str):
                out.add(v)
            else:
                images_in(v, out)
    elif isinstance(obj, list):
        for v in obj:
            images_in(v, out)
    return out


def new_images(diff):
    """Images a `flate diff -o json` brings in: in an object's `new`, not in its `old`."""
    found = set()
    for change in diff.get("changes", []):
        found |= images_in(change.get("new"), set()) - images_in(change.get("old"), set())
    return found


def oidc_token(audience):
    url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")
    if not url:
        sys.exit("::error::no GitHub OIDC token: the job needs permissions: id-token: write")
    req = urllib.request.Request(
        f"{url}&audience={audience}",
        headers={"Authorization": f"bearer {os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["value"]


def prewarm(base, token, path):
    """One manifest GET. 200: served (observe, or already mature); 403 with
    x-nora-quarantine: held and recorded (enforce). Anything else: not recorded."""
    req = urllib.request.Request(
        f"{base}/v2/{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": ACCEPT},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.headers.get("x-nora-quarantine", "")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("x-nora-quarantine", "")
    except (urllib.error.URLError, TimeoutError) as e:
        return 0, str(e)


def main():
    images = {i.strip() for i in os.environ.get("IMAGES", "").splitlines() if i.strip()}
    if os.environ.get("FLATE_DIFF"):
        with open(os.environ["FLATE_DIFF"]) as f:
            images |= new_images(json.load(f))
    paths = list(dict.fromkeys(p for image in sorted(images) for p in nora_paths(image)))
    if not paths:
        print("no external images to prewarm")
        return
    base = os.environ.get("NORA_URL", f"https://{NORA_HOST}").rstrip("/")
    try:
        token = oidc_token(os.environ.get("NORA_AUDIENCE", NORA_HOST))
    except (urllib.error.URLError, TimeoutError, KeyError, ValueError) as e:
        print(f"::warning::nora prewarm: no GitHub OIDC token ({e}); {len(paths)} image(s) not prewarmed")
        return
    rows = []
    for path in paths:
        status, note = prewarm(base, token, path)
        ok = status == 200 or (status == 403 and note)
        if not ok:
            print(f"::warning::nora prewarm {path}: HTTP {status} {note}".rstrip())
        print(f"{status} {path} {note}".rstrip())
        rows.append(f"| `{path}` | {status} {note} |")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### nora prewarm\n\n| image | nora |\n|---|---|\n" + "\n".join(rows) + "\n")


def self_test():
    cases = {
        "nginx:1.27": ["docker-hub/library/nginx/manifests/1.27"],
        "timberio/vector:0.61.0-distroless-libc@sha256:1a34": [
            "docker-hub/timberio/vector/manifests/0.61.0-distroless-libc",
            "docker-hub/timberio/vector/manifests/sha256:1a34",
        ],
        "busybox@sha256:1a34": ["docker-hub/library/busybox/manifests/sha256:1a34"],
        "docker.io/library/alpine": ["docker-hub/library/alpine/manifests/latest"],
        "mirror.gcr.io/library/node:24-alpine": ["docker-hub/library/node/manifests/24-alpine"],
        "ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1": ["ghcr/cloudnative-pg/cloudnative-pg/manifests/1.30.1"],
        "registry.k8s.io/pause:3.10": ["k8s/pause/manifests/3.10"],
        "packages.maestra.io/quay/strimzi/operator:0.51.0": ["quay/strimzi/operator/manifests/0.51.0"],
        "public.ecr.aws/gravitational/teleport-distroless:18.11.4": ["ecr-public/gravitational/teleport-distroless/manifests/18.11.4"],
        "public.ecr.aws/g5f9s8a4/eventrouter:v1.0.28": [],
        "515260921971.dkr.ecr.us-west-2.amazonaws.com/x:1": [],
        "registry.deckhouse.io/deckhouse/ce:v1": [],
        "localhost:5000/x:1": [],
        "${IMAGE}": [],
        "": [],
    }
    for image, want in cases.items():
        got = nora_paths(image)
        assert got == want, f"{image!r}: {got!r} != {want!r}"
    diff = {"changes": [
        {"old": {"spec": {"template": {"spec": {"containers": [{"image": "a:1"}, {"image": "b:1"}]}}}},
         "new": {"spec": {"template": {"spec": {"containers": [{"image": "a:2"}, {"image": "b:1"}]}}}}},
        {"old": None, "new": {"spec": {"values": {"image": "c:1"}}}},
        {"old": {"spec": {"image": "d:1"}}, "new": None},
    ]}
    assert new_images(diff) == {"a:2", "c:1"}, new_images(diff)

    # Round trip against a stub: the OIDC request, then one GET per image with the JWT.
    import http.server
    import threading
    seen = []

    class Stub(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append((self.path, self.headers.get("Authorization")))
            if self.path.startswith("/token"):
                body, code, extra = b'{"value":"eyJ.stub.jwt"}', 200, {}
            elif "held" in self.path:
                body, code, extra = b"{}", 403, {"x-nora-quarantine": "pending"}
            else:
                body, code, extra = b"{}", 200, {}
            self.send_response(code)
            for k, v in extra.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    os.environ.update({
        "IMAGES": "nginx:1.27\nghcr.io/x/held:v1\nregistry.deckhouse.io/skip:1\nquay.io/a/b:v2@sha256:0f",
        "FLATE_DIFF": "", "NORA_URL": base, "NORA_AUDIENCE": "packages.maestra.io",
        "ACTIONS_ID_TOKEN_REQUEST_URL": f"{base}/token?api-version=2.0",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "req-token", "GITHUB_STEP_SUMMARY": "",
    })
    main()
    srv.shutdown()
    assert seen == [
        ("/token?api-version=2.0&audience=packages.maestra.io", "bearer req-token"),
        ("/v2/ghcr/x/held/manifests/v1", "Bearer eyJ.stub.jwt"),
        ("/v2/docker-hub/library/nginx/manifests/1.27", "Bearer eyJ.stub.jwt"),
        # tag@digest: the tag first, so nora can date it by the registry's push date
        ("/v2/quay/a/b/manifests/v2", "Bearer eyJ.stub.jwt"),
        ("/v2/quay/a/b/manifests/sha256:0f", "Bearer eyJ.stub.jwt"),
    ], seen
    print("self-test ok")


if __name__ == "__main__":
    self_test() if sys.argv[1:] == ["--self-test"] else main()
