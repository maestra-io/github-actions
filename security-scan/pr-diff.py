#!/usr/bin/env python3
"""pr-diff.py: the trivy half of pr-scan.sh (pull_request mode of security-scan.yml).

  pr-diff.py any <head.json>               exit 0 when the trivy JSON has a finding, else 1
  pr-diff.py trivy <base.json> <head.json> [<base root> <head root>]
                                           print the head findings absent from the base; exit 1
                                           when there is one, else 0
  pr-diff.py opengrep <diff.json> <full.json> <base root> [<head root>]
                                           print the diff-scan (--baseline-commit) findings that are
                                           new; exit 1 when there is one, else 0. <full.json>: one
                                           full scan of the base copies (paths under <base root>)
                                           and the head copies of their files. Old: the same rule,
                                           path and matched lines at the base at least as often as
                                           at the head (a complete head count: no parse error in
                                           the file, no timeout of the rule); in a Dockerfile with
                                           a parse error at the base, the same instruction in the
                                           base copy's text, in a stage with the same USER lines
  pr-diff.py --self-test
  Exit 2 on an unreadable report (a crash never reads as 0 or 1).

Key of a finding, never a line number: vulnerability = (target, package, advisory id), so a
PR that leaves a vulnerable package alone (or bumps it within the same advisory) adds nothing;
secret = (target, rule id, sha256 of the matched lines read from the scanned tree under its root,
whitespace-normalised), so a secret moved within its file stays the old finding and a token
replaced by another of the same length is new (trivy's redacted Match cannot tell them apart; it
is the fallback when the file cannot be read). Secret values are never printed or stored: only
the hash, the rule, the file and the line number.

opengrep: --baseline-commit drops a head match only when its own scan of the base matches the
same lines. That scan can miss one the full scan finds (a taint match on a slow runner: the
moved sqli of test-security-scan-pr.sh case 4, 23.11.2026), and in a file opengrep cannot parse
at the base (1.33.1 stops at `RUN --mount=...,rw` and skips the lines after it) it has none, so
every match reads as new. A full scan of the base and head copies is the reference: a (rule, path,
matched lines) found at the base at least as often as at the head is old (an occurrence added by
the PR is new). In a Dockerfile with a parse error at the base (a timeout is not one), the base
copy's text stands in for its matches: the matched lines (whitespace-normalised, in a row) as an
instruction (not heredoc data, not a continuation line) in a stage with the same USER
instructions, at least as often as at the head, so a PR that removes the stage's USER or repeats
the CMD in a new stage still fails. A head copy the full scan did not finish (a parse error, a
timeout of the rule) gives no count: its findings stay new unless that text fallback holds.
"""
import hashlib, json, os, re, sys


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
    """Whitespace-normalised lines of root/path; None when unreadable or outside root (a report path is data)."""
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, path))
    if not full.startswith(root + os.sep):
        return None
    try:
        with open(full, "rb") as f:
            return [b" ".join(l.split()) for l in f.read().split(b"\n")]
    except OSError:
        return None


PARSE_ERRORS = {"Lexical error", "Syntax error", "Other syntax error", "AST builder error", "PartialParsing"}


HEREDOC = re.compile(rb"<<-?([\"']?)([A-Za-z_][A-Za-z0-9_]*)\1")


def instructions(lines):
    """Indexes of the (normalised) Dockerfile lines that start an instruction: not heredoc data,
    not a continuation line, not a comment."""
    starts, cont, ends = set(), False, []
    for i, l in enumerate(lines):
        if ends:
            if l == ends[0]:
                ends.pop(0)
            continue
        if l.startswith(b"#"):
            continue
        if l and not cont:
            starts.add(i)
        ends = [m.group(2) for m in HEREDOC.finditer(l)]
        cont = l.endswith(b"\\")
    return starts


def at(lines, want, starts):
    """Indexes where the instruction `want` (its lines) starts in `lines`."""
    return [i for i in sorted(starts) if tuple(lines[i:i + len(want)]) == want]


def stage_users(lines, i, starts):
    """The USER instructions of the Dockerfile stage (FROM to FROM) holding line index i."""
    first = lambda kw, js: [j for j in js if j in starts and lines[j].upper().startswith(kw)]
    start = max(first(b"FROM ", range(i + 1)) or [0])
    end = min(first(b"FROM ", range(i + 1, len(lines))) or [len(lines)])
    return tuple(lines[j] for j in first(b"USER ", range(start, end)))


def opengrep_new(diff_path, full_path, base_root, head_root="."):
    """(new findings, files not fully parsed at the base) for pr-scan.sh's opengrep mode."""
    with open(diff_path) as f:
        diff = json.load(f)
    with open(full_path) as f:
        full = json.load(f)
    base_root = os.path.abspath(base_root)
    def base_rel(p):  # path of a base copy relative to base_root; None for a head file
        r = os.path.relpath(os.path.abspath(p), base_root)
        return None if r == os.pardir or r.startswith(os.pardir + os.sep) else r
    def kind(e):
        t = e.get("type")
        return t[0] if isinstance(t, list) and t else t
    unparsed = {base_rel(e["path"]) for e in full.get("errors") or []
                if e.get("path") and kind(e) in PARSE_ERRORS and base_rel(e["path"])}
    def matched(root, path, r):
        return tuple((norm_lines(root, path) or [])[r["start"]["line"] - 1:r["end"]["line"]])
    # a head copy the full scan did not finish (parse error: whole file; timeout: that rule) has no complete count
    partial = {(os.path.normpath(e["path"]), None if kind(e) in PARSE_ERRORS else e.get("rule_id"))
               for e in full.get("errors") or [] if e.get("path") and not base_rel(e["path"])}
    count = {}  # (rule, path, matched lines) -> [occurrences at the base, at the head]
    for r in full.get("results") or []:
        rel = base_rel(r["path"])
        root, path = (base_root, rel) if rel else (head_root, os.path.normpath(r["path"]))
        count.setdefault((r["check_id"], path, matched(root, path, r)), [0, 0])[0 if rel else 1] += 1
    new = []
    for r in diff.get("results") or []:
        path = os.path.normpath(r["path"])
        want = matched(head_root, path, r)
        b, h = count.get((r["check_id"], path, want), [0, 0])
        if want and 0 < h <= b and not {(path, None), (path, r["check_id"])} & partial:
            continue  # the full scans have it as often at the base: --baseline-commit missed it
        if want and path in unparsed and "dockerfile" in os.path.basename(path).lower():
            # The base copy's text stands in for its matches: the same instruction in a stage with
            # the same USER instructions, at least as often as at the head.
            # ponytail: context other than the stage's USER lines (and `# escape=`) is not modelled
            had, has = norm_lines(base_root, path) or [], norm_lines(head_root, path) or []
            bs, hs = instructions(had), instructions(has)
            users = stage_users(has, r["start"]["line"] - 1, hs)
            b = sum(stage_users(had, i, bs) == users for i in at(had, want, bs))
            if b and sum(stage_users(has, i, hs) == users for i in at(has, want, hs)) <= b:
                continue
        new.append((r["check_id"], path, r["start"]["line"]))
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
    # the full scan of the base has the old CMD (line 3 there), the baseline did not drop it
    full_results = [og("missing-user", os.path.join(ob, "Dockerfile"), 3), og("missing-user", "Dockerfile", 4)]
    full_base = put("og-base-full.json", {"results": full_results, "errors": []})
    assert opengrep_new(diff_, full_base, ob, oh)[0] == [("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    assert main(["opengrep", diff_, unparsed, ob, oh]) == 1
    # ... but twice in the full scan of the head: one of them is new
    twice = put("og-full-twice.json", {"results": full_results + [og("missing-user", "Dockerfile", 4)], "errors": []})
    assert opengrep_new(diff_, twice, ob, oh)[0] == [("missing-user", "Dockerfile", 4), ("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    # ... or the full scan of the head did not finish that rule (or the file): its count is not complete
    for err in ({"type": "Timeout", "rule_id": "missing-user"}, {"type": ["PartialParsing", []]}):
        cut = put("og-full-cut.json", {"results": full_results, "errors": [dict(err, path="Dockerfile")]})
        assert opengrep_new(diff_, cut, ob, oh)[0] == [("missing-user", "Dockerfile", 4), ("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)], err
    other = put("og-full-other.json", {"results": full_results, "errors": [{"type": "Timeout", "rule_id": "sqli", "path": "Dockerfile"}]})
    assert opengrep_new(diff_, other, ob, oh)[0] == [("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    # only a parse error makes a file unparsed: a timeout does not
    timeout = put("og-base-timeout.json", {"results": [], "errors": [{"type": "Timeout", "path": os.path.join(ob, "Dockerfile")}]})
    assert opengrep_new(diff_, timeout, ob, oh)[0] == [("missing-user", "Dockerfile", 4), ("missing-user", "Dockerfile", 5), ("sqli", "app.py", 3)]
    # unparsed base, text fallback: a PR that removes the stage's USER, repeats the CMD in a new
    # stage, or turns heredoc data or a continuation line into the instruction is new
    for name, base_df, head_df, line in (
            ("user", 'FROM a\nUSER app\nRUN x,rw\nCMD ["x"]\n', 'FROM a\nRUN y,rw\nCMD ["x"]\n', 3),
            ("dup", 'FROM a\nRUN x,rw\nCMD ["x"]\n', 'FROM a\nRUN y,rw\nCMD ["x"]\nFROM a AS w\nCMD ["x"]\n', 5),
            ("heredoc", 'FROM a\nRUN x,rw\nCOPY <<EOF /t\nCMD ["x"]\nEOF\n', 'FROM a\nRUN y\nCMD ["x"]\n', 3),
            ("continued", 'FROM a\nRUN x,rw \\\n  CMD ["x"]\n', 'FROM a\nRUN y\nCMD ["x"]\n', 3),
            ("same", 'FROM a\nUSER app\nRUN x,rw\nCMD ["x"]\n', 'FROM a\nUSER app\nRUN y,rw\nCMD ["x"]\n', 4)):
        b_, h_ = os.path.join(d, name + "-b"), os.path.join(d, name + "-h")
        for root, body in ((b_, base_df), (h_, head_df)):
            os.makedirs(root, exist_ok=True)
            with open(os.path.join(root, "Dockerfile"), "w") as f:
                f.write(body)
        dd = put(name + "-diff.json", {"results": [og("missing-user", "Dockerfile", line)], "errors": []})
        un = put(name + "-full.json", {"results": [], "errors": [{"type": ["PartialParsing", []], "path": os.path.join(b_, "Dockerfile")}]})
        assert opengrep_new(dd, un, b_, h_)[0] == ([] if name == "same" else [("missing-user", "Dockerfile", line)]), name
    # a report path that leaves its root is never read
    ox = os.path.join(d, "ox")
    os.makedirs(ox, exist_ok=True)
    with open(os.path.join(ox, "Dockerfile"), "w") as f:
        f.write('CMD ["x"]\n')
    assert norm_lines(ox, "Dockerfile") == [b'CMD ["x"]', b""] and norm_lines(ob, "../ox/Dockerfile") is None
    print("pr-diff self-test ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # a crash is exit 2 (broken), never 1 (= no findings / new findings)
        print(f"pr-diff: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
