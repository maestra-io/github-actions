#!/usr/bin/env python3
"""rules-bundle.py <rules dir> <out dir>: an opengrep config dir with one rule file per directory.

opengrep validates each config file in its own semgrep-core call: the ~1450 files of the
semgrep-rules security selection take ~3.5 min to load on pool=small, their ~310 directories
about a third of that. The directories are kept: <out dir>/<dir>/rules.yaml holds the rules of
<rules dir>/<dir>/*.yaml in file name order.
Rule ids: opengrep runs one rule per id, the one it reads last (with --no-rewrite-rule-ids
semgrep-rules has 70 ids on 191 rules, tainted-sql-string in 13 directories), so a rule whose
id another rule also has gets <dir>.<id> (dots for slashes), <dir>.<file stem>.<id> when that
id is twice in one directory: python.flask.security.injection.tainted-sql-string,
csharp.lang.security.ssrf.http-client.ssrf. That is the id opengrep itself would give it
without --no-rewrite-rule-ids, and `nosemgrep: <id>` keeps matching: opengrep compares the
comment's id to the rule id or to its last dot-separated parts (Rule_ID.ends_with).
The text is not re-serialised (a YAML round trip can change scalars): the `rules:` sequence of
each file is re-indented to one column and appended. The one difference: a block scalar that
ends a file without a final newline gets one (3 patterns in semgrep-rules; a pattern's trailing
newline does not change what it matches). Source files as opengrep reads a config dir: *.yaml,
minus *.test.yaml (rule test fixtures).
  rules-bundle.py --self-test
"""
import os, re, sys

COL = 4  # the deepest item column in semgrep-rules


ID = re.compile(r"( *(?:- +)?id: *)(\S+)(.*)$")


def items(path, text):
    """The lines of the `rules:` sequence of one rule file, its items moved to column COL."""
    lines = text.split("\n")[:-1] if text.endswith("\n") else text.split("\n")  # no blank line added after a |+ scalar
    head = [i for i, l in enumerate(lines) if l and not l[0].isspace() and not l.startswith(("#", "-"))]
    if [lines[i].rstrip() for i in head] != ["rules:"]:
        sys.exit(f"rules-bundle: {path}: not a single top-level `rules:` key")
    body = lines[head[0] + 1:]
    first = next((m for l in body for m in [re.match(r"( *)-( |$)", l)] if l.strip() and not l.lstrip().startswith("#")), None)
    if not first or len(first.group(1)) > COL:
        sys.exit(f"rules-bundle: {path}: no rule list at column 0..{COL}")
    pad = " " * (COL - len(first.group(1)))
    return [pad + l if l else l for l in body]


def rule_ids(path, lines):
    """[(line index, id)] of the rules in items() lines: an `id:` key at the column of the item's keys."""
    out, key = [], None
    for i, l in enumerate(lines):
        if not l.strip() or l.lstrip().startswith("#"):
            continue
        m = re.match(r" {%d}-( *)(\S?)" % COL, l)
        if m:
            key = COL + 1 + len(m.group(1)) if m.group(2) else -1  # -1: the keys start on the next line
            out.append(None)
            if not m.group(2):
                continue
        elif key == -1:
            key = len(l) - len(l.lstrip())
        m = ID.match(l)
        if m and len(m.group(1)) - len(m.group(1).lstrip(" -")) == key:
            if out[-1] is not None:
                sys.exit(f"rules-bundle: {path}: two ids in one rule")
            out[-1] = (i, m.group(2).strip("'\""))
    if None in out:
        sys.exit(f"rules-bundle: {path}: a rule without an `id:` key")
    return out


def bundle(root):
    """{output file path relative to the out dir: text}"""
    files = {}  # {(dir, file name): [(line index, id)], items() lines}
    for d, dirs, names in os.walk(root):
        dirs.sort()
        for f in sorted(names):
            if f.endswith(".yaml") and not f.endswith(".test.yaml"):
                p = os.path.join(d, f)
                with open(p, encoding="utf-8") as fh:
                    lines = items(p, fh.read())
                files[os.path.relpath(d, root), f] = rule_ids(p, lines), lines
    seen = {}
    for (d, f), (ids, _) in files.items():
        for _, i in ids:
            seen.setdefault(i, []).append(d)
    out, final = {}, set()
    for (d, f), (ids, lines) in files.items():
        prefix = [] if d == "." else d.split(os.sep)
        for n, i in ids:
            if len(seen[i]) > 1:
                new = ".".join(prefix + [f[:-5]] * (seen[i].count(d) > 1) + [i])
                m = ID.match(lines[n])
                lines[n] = m.group(1) + new + m.group(3)
                i = new
            if i in final:
                sys.exit(f"rules-bundle: {d}/{f}: rule id {i} is not unique")
            final.add(i)
        name = os.path.join(d, "rules.yaml")
        out[name] = out.get(name, "rules:") + "".join("\n" + l for l in lines)
    return {k: v + "\n" for k, v in out.items()}


def self_test():
    import tempfile
    d = tempfile.mkdtemp()
    for name, text in (("a/x.yaml", "# c\nrules:\n- id: a\n  pattern: |\n    f(\n      $X)\n"),
                       ("a/y.yaml", "rules:\n  - id: b\n\n    pattern: g()\n    metadata:\n      id: a\n"),
                       ("a/w.yaml", "rules:\n- message: m\n  id: 'b' # c\n- id: c\n  patterns:\n  - id: x\n"),
                       ("a/b/z.yaml", "rules:\n -\n    id: a\n"),
                       ("a/b/z.test.yaml", "rules:\n- id: fixture\n")):
        os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
    got = bundle(d)
    assert got == {"a/rules.yaml": "rules:\n    - message: m\n      id: a.w.b # c\n    - id: c\n      patterns:\n      - id: x\n"
                                   "    - id: a.a\n      pattern: |\n        f(\n          $X)\n"
                                   "    - id: a.y.b\n\n      pattern: g()\n      metadata:\n        id: a\n",
                   "a/b/rules.yaml": "rules:\n    -\n       id: a.b.a\n"}, got
    print("rules-bundle self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        for name, text in bundle(sys.argv[1]).items():
            os.makedirs(os.path.dirname(os.path.join(sys.argv[2], name)))
            with open(os.path.join(sys.argv[2], name), "w", encoding="utf-8") as f:
                f.write(text)
    else:
        sys.exit(__doc__)
