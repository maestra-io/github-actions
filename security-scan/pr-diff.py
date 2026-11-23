#!/usr/bin/env python3
"""pr-diff.py: the trivy half of pr-scan.sh (pull_request mode of security-scan.yml).

  pr-diff.py any <head.json>               exit 0 when the trivy JSON has a finding, else 1
  pr-diff.py trivy <base.json> <head.json> [<base root> <head root>]
                                           print the head findings absent from the base; exit 1
                                           when there is one, else 0
  pr-diff.py opengrep <diff.json> <base.json> <base root> [<head root>]
                                           print the diff-scan (--baseline-commit) findings that are
                                           new; exit 1 when there is one, else 0. In a file the scan
                                           of the base copies (<base.json>, paths under <base root>)
                                           could not fully parse, a finding whose matched lines the
                                           base copy has verbatim is old
  pr-diff.py --self-test
  Exit 2 on an unreadable report (a crash never reads as 0 or 1).

Key of a finding, never a line number: vulnerability = (target, package, advisory id), so a
PR that leaves a vulnerable package alone (or bumps it within the same advisory) adds nothing;
secret = (target, rule id, sha256 of the matched lines read from the scanned tree under its root,
whitespace-normalised), so a secret moved within its file stays the old finding and a token
replaced by another of the same length is new (trivy's redacted Match cannot tell them apart; it
is the fallback when the file cannot be read). Secret values are never printed or stored: only
the hash, the rule, the file and the line number.

opengrep: --baseline-commit drops a head match only when the scan of the base matches the same
lines, so in a file opengrep cannot parse at the base (1.33.1 stops at `RUN --mount=...,rw` and
skips the lines after it) every match reads as new, even on lines the PR never touched. There
the base copy's text stands in for its matches: a finding whose matched lines (whitespace-
normalised) the base copy has in a row is old.
"""
import hashlib, json, os, sys


def raw_lines(root, target, start, end):
    """sha256 of lines start..end of root/target, whitespace-normalised; None if unreadable."""
    if not root or not start:
        return None
    try:
        with open(os.path.join(root, target), "rb") as f:
            lines = f.read().split(b"\n")[start - 1:(end or start)]
    except OSError:
        return None
    return hashlib.sha256(b" ".join(b" ".join(l.split()) for l in lines)).hexdigest()


def findings(path, root=None):
    with open(path) as f:
        doc = json.load(f)
    for r in doc.get("Results") or []:
        t = r.get("Target", "")
        for v in r.get("Vulnerabilities") or []:
            key = ("vuln", t, v.get("PkgName", ""), v.get("VulnerabilityID", ""))
            yield key, f"{v.get('Severity')} {v.get('VulnerabilityID')} {v.get('PkgName')} {v.get('InstalledVersion')} in {t}"
        for s in r.get("Secrets") or []:
            ident = raw_lines(root, t, s.get("StartLine"), s.get("EndLine")) or " ".join(str(s.get("Match", "")).split())
            key = ("secret", t, s.get("RuleID", ""), ident)
            yield key, f"{s.get('Severity')} secret {s.get('RuleID')} in {t}:{s.get('StartLine')}"


def norm_lines(root, path):
    """Whitespace-normalised lines of root/path; None when it resolves outside root (a report path is data)."""
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, path))
    if not full.startswith(root + os.sep):
        return None
    with open(full, "rb") as f:
        return [b" ".join(l.split()) for l in f.read().split(b"\n")]


def opengrep_new(diff_path, base_path, base_root, head_root="."):
    """(new findings, files not fully parsed at the base) for pr-scan.sh's opengrep mode."""
    with open(diff_path) as f:
        diff = json.load(f)
    with open(base_path) as f:
        base = json.load(f)
    base_root = os.path.abspath(base_root)
    unparsed = {os.path.relpath(os.path.abspath(e["path"]), base_root)
                for e in base.get("errors") or [] if e.get("path")}
    new = []
    for r in diff.get("results") or []:
        path, start, end = os.path.normpath(r["path"]), r["start"]["line"], r["end"]["line"]
        if path in unparsed:
            # ponytail: same text = old, so a PR that only removes the context (a USER line above
            # an old CMD) passes in such a file; the full scan of main still reports it
            want = (norm_lines(head_root, path) or [])[start - 1:end]
            had = norm_lines(base_root, path) or []
            if want and any(had[i:i + len(want)] == want for i in range(len(had) - len(want) + 1)):
                continue
        new.append((r["check_id"], path, start))
    return new, unparsed


def new_findings(base, head):
    old = {k for k, _ in base}
    return [(k, text) for k, text in head if k not in old]


def main(argv):
    if argv[:1] == ["any"]:
        return 0 if any(True for _ in findings(argv[1])) else 1
    if argv[:1] == ["trivy"]:
        roots = argv[3:5] if len(argv) >= 5 else [None, None]
        head = list(findings(argv[2], roots[1]))
        new = new_findings(findings(argv[1], roots[0]), head)
        print(f"trivy: {len(head)} HIGH/CRITICAL findings at head, {len(head) - len(new)} already on the base, {len(new)} introduced by this PR")
        for _, text in sorted(set(new)):
            print(f"  NEW {text}")
        return 1 if new else 0
    if argv[:1] == ["opengrep"]:
        new, unparsed = opengrep_new(*argv[1:5])
        for p in sorted(unparsed):
            print(f"opengrep: {p} is not fully parsed at the base: its findings are compared with the base copy's text")
        print(f"opengrep: {len(new)} finding(s) introduced by this PR")
        for rule, path, line in sorted(set(new)):
            print(f"  NEW {rule} in {path}:{line}")
        return 1 if new else 0
    if argv[:1] == ["--self-test"]:
        return self_test()
    print(__doc__, file=sys.stderr)
    return 2


def self_test():
    import os, tempfile
    def doc(vulns=(), secrets=()):
        return {"Results": [{"Target": "requirements.txt", "Vulnerabilities": [
            {"PkgName": p, "InstalledVersion": ver, "VulnerabilityID": cve, "Severity": "HIGH"} for p, ver, cve in vulns]},
            {"Target": "app/config.py", "Secrets": [
                {"RuleID": r, "Match": m, "StartLine": ln, "Severity": "CRITICAL"} for r, m, ln in secrets]}]}
    d = tempfile.mkdtemp()
    def put(name, o):
        p = os.path.join(d, name)
        with open(p, "w") as f:
            json.dump(o, f)
        return p
    base = put("base.json", doc([("pyyaml", "5.3", "CVE-2020-14343")], [("aws-access-key-id", "key = ****", 3)]))
    # unchanged findings, the secret moved down the file, the package bumped within the advisory
    same = put("same.json", doc([("pyyaml", "5.3.1", "CVE-2020-14343")], [("aws-access-key-id", "key  =  ****", 40)]))
    newcve = put("newcve.json", doc([("pyyaml", "5.3", "CVE-2020-14343"), ("django", "3.2.0", "CVE-2021-35042")]))
    newsecret = put("newsecret.json", doc([], [("aws-access-key-id", "key = ****", 3), ("github-pat", "token = ****", 9)]))
    empty = put("empty.json", {"Results": [{"Target": "go.sum"}]})
    assert main(["trivy", base, same]) == 0
    assert main(["trivy", base, newcve]) == 1
    assert main(["trivy", base, newsecret]) == 1
    assert main(["trivy", empty, newcve]) == 1
    assert main(["any", empty]) == 1 and main(["any", base]) == 0
    import subprocess
    bad = put("bad.json", None)
    with open(bad, "w") as f:
        f.write("{truncated")
    for args in (["any", bad], ["any", os.path.join(d, "missing.json")], ["trivy", base, bad]):
        assert subprocess.run([sys.executable, __file__, *args], capture_output=True).returncode == 2, args
    # raw-line identity: same redacted Match, different token -> new; same token moved -> old
    for side, tok, ln in (("b", "AAAA", 2), ("h1", "AAAA", 5), ("h2", "BBBB", 2)):
        os.makedirs(os.path.join(d, side, "app"), exist_ok=True)
        with open(os.path.join(d, side, "app", "config.py"), "w") as f:
            f.write("\n" * (ln - 1) + f"key = {tok}\n")
    sb = put("sb.json", doc([], [("aws-access-key-id", "key = ****", 2)]))
    sh1 = put("sh1.json", doc([], [("aws-access-key-id", "key = ****", 5)]))
    sh2 = put("sh2.json", doc([], [("aws-access-key-id", "key = ****", 2)]))
    for doc_ in (sb, sh1, sh2):  # EndLine as trivy writes it
        o = json.load(open(doc_)); o["Results"][1]["Secrets"][0]["EndLine"] = o["Results"][1]["Secrets"][0]["StartLine"]; json.dump(o, open(doc_, "w"))
    assert main(["trivy", sb, sh1, os.path.join(d, "b"), os.path.join(d, "h1")]) == 0
    assert main(["trivy", sb, sh2, os.path.join(d, "b"), os.path.join(d, "h2")]) == 1
    # opengrep: Dockerfile unparsed at the base -> base text decides; app.py parsed -> diff verdict
    ob, oh = os.path.join(d, "ob"), os.path.join(d, "oh")
    for root, body in ((ob, "FROM a\nRUN x\nCMD  [\"x\"]\n"), (oh, "FROM b\nRUN y\n\nCMD [\"x\"]\nCMD [\"y\"]\n")):
        os.makedirs(root, exist_ok=True)
        with open(os.path.join(root, "Dockerfile"), "w") as f:
            f.write(body)
    def og(rule, path, line):
        return {"check_id": rule, "path": path, "start": {"line": line}, "end": {"line": line}}
    old_cmd, new_cmd, sqli = og("missing-user", "Dockerfile", 4), og("missing-user", "Dockerfile", 5), og("sqli", "app.py", 3)
    diff_ = put("og-diff.json", {"results": [old_cmd, new_cmd, sqli], "errors": []})
    unparsed = put("og-base-unparsed.json", {"results": [], "errors": [{"type": ["PartialParsing", []], "path": os.path.join(ob, "Dockerfile")}]})
    parsed = put("og-base-parsed.json", {"results": [], "errors": []})
    assert opengrep_new(diff_, unparsed, ob, oh)[0] == [("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    assert opengrep_new(diff_, parsed, ob, oh)[0] == [("missing-user", "Dockerfile", 4), ("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    assert main(["opengrep", diff_, unparsed, ob, oh]) == 1
    # a report path that leaves the roots is never read: the same file on both sides would read as old
    ox = os.path.join(d, "ox")
    os.makedirs(ox, exist_ok=True)
    with open(os.path.join(ox, "Dockerfile"), "w") as f:
        f.write('CMD ["x"]\n')
    escape = put("og-diff-escape.json", {"results": [og("missing-user", "../ox/Dockerfile", 1)], "errors": []})
    unparsed_escape = put("og-base-escape.json", {"results": [], "errors": [{"path": os.path.join(ox, "Dockerfile")}]})
    assert opengrep_new(escape, unparsed_escape, ob, oh)[0] == [("missing-user", "../ox/Dockerfile", 1)]
    print("pr-diff self-test ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # a crash is exit 2 (broken), never 1 (= no findings / new findings)
        print(f"pr-diff: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
