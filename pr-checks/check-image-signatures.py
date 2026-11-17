"""Image signature check of a PR: the images it adds to the built overlays, judged by
kyverno-cli with the admission policy the clusters run.

Usage:
  check-image-signatures.py list <policy> <head-manifests> <base-manifests>
  check-image-signatures.py verify <policy> <kyverno> [--enforce] < refs

list    prints the `<repository>@sha256:<digest>` refs in head and not in base whose
        repository the policy covers; nothing printed = nothing to verify. No network.
verify  reads those refs and runs `kyverno apply` over one Pod per ref. Exit 1 only with
        --enforce and a ref the policy rejects; without it a rejected ref is a warning.
        Kyverno itself failing is a warning either way: a registry or Rekor outage says
        nothing about the image.

kyverno-cli and not cosign, because the two disagree and only Kyverno's answer decides
what the cluster admits: Nexus#158 moved tbot-distroless to a digest signed only as a
Sigstore bundle, `cosign verify` accepted it, Kyverno found no signatures, and Pods were
denied under Enforce.

image-signatures-policy.yaml is `helm template t base/kyverno-image-signatures/chart`
of the private maestra-io/fluxcd, which this public workflow cannot read. Regenerate it
when that chart changes.

Not seen: a tag without a digest, and a digest kept apart from its repository in chart
values (`repository:` + `tag: x@sha256:...`).
"""

import json
import os
import re
import subprocess
import sys
import tempfile

# registry/path[:tag]@sha256:digest. The tag is dropped: the policy's patterns are
# <repository>@*, and a Pod's image is matched by repository and digest.
REF = re.compile(
    r"(?<![\w./-])((?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:/[a-z0-9._-]+)+)(?::[\w.-]+)?@(sha256:[0-9a-f]{64})\b"
)
COVERED = re.compile(r'^\s*- "([^"*]+)@\*"\s*$', re.M)
# Rules that only report; see the `audit` and `tags` modes of the chart.
AUDIT_RULES = ("-recovery-path", "-tag-refs")


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def refs(text: str) -> set[str]:
    return {f"{m.group(1)}@{m.group(2)}" for m in REF.finditer(text)}


def new_refs(policy: str, head: str, base: str) -> list[str]:
    covered = set(COVERED.findall(policy))
    return sorted(r for r in refs(head) - refs(base) if r.split("@")[0] in covered)


def pods(images: list[str]) -> str:
    return "\n---\n".join(
        json.dumps({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": f"image-{i}", "namespace": "default"},
            "spec": {"containers": [{"name": "c", "image": image}]},
        })
        for i, image in enumerate(images)
    )


def rejected(report: str) -> dict[str, str]:
    """Pod name -> message, for the Pods a rule that enforces failed."""
    text = report[report.index("{"):]
    doc, _ = json.JSONDecoder().raw_decode(text)
    bad: dict[str, str] = {}
    for result in doc.get("results") or []:
        if result.get("result") in ("fail", "error") and not str(result.get("rule", "")).endswith(AUDIT_RULES):
            for resource in result.get("resources") or []:
                bad.setdefault(resource["name"], str(result.get("message", "")))
    return bad


def verify(policy: str, kyverno: str, enforce: bool, images: list[str]) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "pods.yaml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(pods(images))
        try:
            run = subprocess.run(
                [kyverno, "apply", policy, "--resource", path, "--policy-report", "--output-format", "json"],
                capture_output=True, text=True, timeout=300,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"::warning title=image signatures not checked::kyverno did not run: {e}")
            return 0
    try:
        if run.returncode not in (0, 1):
            raise ValueError(f"exit {run.returncode}")
        bad = rejected(run.stdout)
    except (ValueError, KeyError, TypeError) as e:
        print(f"::warning title=image signatures not checked::kyverno gave no report: {e}")
        print(run.stderr[-2000:])
        return 0
    level = "error" if enforce else "warning"
    for i, image in enumerate(images):
        message = bad.get(f"image-{i}")
        if message is None:
            print(f"ok   {image}")
        else:
            print(f"::{level} title=image signature::{image} would be denied under Enforce: "
                  + " ".join(message.split()))
    return 1 if enforce and bad else 0


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[1] == "list":
        # One line per ref and no output at all without one: the workflow tests for an
        # empty file before it downloads Kyverno.
        for ref in new_refs(read(argv[2]), read(argv[3]), read(argv[4])):
            print(ref)
        return 0
    if len(argv) in (4, 5) and argv[1] == "verify" and argv[4:] in ([], ["--enforce"]):
        images = sorted({line.strip() for line in sys.stdin if line.strip()})
        return verify(argv[2], argv[3], len(argv) == 5, images) if images else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
