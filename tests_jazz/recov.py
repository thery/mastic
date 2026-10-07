#!/usr/bin/env python3
"""Tests for the error-resilient Jasmin parser (Mastic), on top of main.exe.

  recov.py show FILE...           what main.exe prints: errors underlined, AST
  recov.py fuzz [options] FILE... simulate editing: damage valid programs and
                                  check what the parser recovers

The hand-written cases and the fuzzing of test/ are cram tests (cases.t,
fuzz.t), run by dune runtest.
"""
import argparse, collections, concurrent.futures, json, os, random, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
def _exe():
    """main.exe in the dune _build tree above this directory"""
    d, rel = HERE, []
    while not os.path.isdir(os.path.join(d, "_build")):
        d, base = os.path.split(d)
        if not base:
            sys.exit("recov.py: no _build directory found, run dune build first")
        rel.insert(0, base)
    return os.path.join(d, "_build", "default", *rel, "main.exe")


EXE = os.environ.get("RECOV_EXE") or _exe()
TIMEOUT = 5



def union_length(spans):
    total, end = 0, None
    for b, e in sorted(spans):
        if end is None or b > end:
            total += e - b
            end = e
        elif e > end:
            total += e - end
            end = e
    return total


class Decl:
    """an item, as main.exe -raw prints it: kind, span, the item without locations"""
    def __init__(self, raw, path):
        kind, b, e, norm = raw.split("\t", 3)
        self.kind = kind  # Item | Error
        self.b, self.e = int(b), int(e)
        self.norm = norm


class Result:
    def __init__(self, status, lines=(), path=None):
        self.status = status  # ok | crash | timeout
        self.errors, self.completions, self.decls, self.exn = [], [], [], None
        self.spans = []  # (kind, start, end) of the error nodes
        self.measure = None  # (expected, recovered, matched) nodes, see main.ml
        for l in lines:
            tag, _, rest = l.partition("\t")
            if tag == "E":
                off, st = rest.split("\t")
                self.errors.append(("parse", int(off), "state " + st))
            elif tag == "L":
                off, msg = rest.split("\t", 1)
                self.errors.append(("lex", int(off), msg))
            elif tag == "C":
                off, txt = rest.split("\t", 1)
                self.completions.append((int(off), txt))
            elif tag == "D":
                self.decls.append(Decl(rest, path))
            elif tag == "S":
                k, b, e = rest.split("\t")
                self.spans.append((k, int(b), int(e)))
            elif tag == "M":
                self.measure = tuple(int(x) for x in rest.split("\t"))
            elif tag == "X":
                self.exn = rest

    @property
    def error_decls(self):
        return [d for d in self.decls if d.kind == "Error"]


def run(path, include=None, against=None):
    cmd = [EXE, "-raw", path] + (["-against", against] if against else [])
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, errors="replace")
    except subprocess.TimeoutExpired:
        return Result("timeout", path=path)
    lines = p.stdout.splitlines()
    if p.returncode != 0:
        r = Result("crash", lines, path)
        if r.exn is None:
            r.exn = (p.stderr.strip().splitlines() or ["exit %d" % p.returncode])[-1]
        return r
    return Result("ok", lines, path)


# ---------------------------------------------------------------- show / check

def linecol(text, off):
    line = text.count("\n", 0, off) + 1
    return "%d:%d" % (line, off - (text.rfind("\n", 0, off) + 1))


def show(path, include=None):
    """the readable output of main.exe: source with errors underlined, AST"""
    cmd = [EXE, path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT, errors="replace")
    except subprocess.TimeoutExpired:
        return "TIMEOUT\n"
    return p.stdout + ("" if p.returncode == 0 else "exit %d\n" % p.returncode)


# ---------------------------------------------------------------- fuzz

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[A-Za-z_0-9]+|<<r|>>r|[<>=!]=[su]?|<<|>>[su]?|&&|\|\||->|::|#\[|\S')
COMMENT = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)


def tokens(text):
    """(start, end) of the tokens, roughly, skipping comments"""
    comments = [m.span() for m in COMMENT.finditer(text)]
    out = []
    for m in TOKEN.finditer(text):
        if any(a <= m.start() < b for a, b in comments):
            continue
        out.append((m.start(), m.end()))
    return out


def mutations(text, rng, per_kind):
    """yield (kind, damaged_start, damaged_end, new_text); the damage is [a, b) in the original"""
    toks = tokens(text)
    if not toks:
        return
    lines, pos = [], 0
    for l in text.splitlines(keepends=True):
        if l.strip() and not l.lstrip().startswith("//"):
            lines.append((pos, pos + len(l)))
        pos += len(l)

    def pick(xs, n):
        return rng.sample(xs, min(n, len(xs)))

    for a, _ in pick(toks, per_kind):  # typing in progress: the file stops here
        yield "truncate", a, len(text), text[:a]
    for a, b in pick(toks, per_kind):
        yield "del-token", a, b, text[:a] + text[b:]
    for a, b in pick(lines, per_kind):
        yield "del-line", a, b, text[:a] + text[b:]
    for _ in range(per_kind if len(lines) > 2 else 0):
        i = rng.randrange(len(lines))
        j = min(len(lines) - 1, i + rng.randint(1, 5))
        a, b = lines[i][0], lines[j][1]
        yield "del-chunk", a, b, text[:a] + text[b:]
    closers = [(a, b) for a, b in toks if text[a:b] in (")", "]", "}", ";")]
    for a, b in pick(closers, per_kind):
        yield "del-closer", a, b, text[:a] + text[b:]
    for a, b in pick(toks, per_kind):  # start of a new token being typed
        yield "half-token", a + (b - a) // 2, b, text[:a + (b - a) // 2] + text[b:]


def fuzz_file(args):
    path, seed, per_kind, keep_dir = args
    text = open(path, encoding="utf-8", errors="replace").read()
    orig = run(path, None, path)  # against itself: the number of nodes
    if orig.status != "ok" or orig.errors or orig.error_decls or not orig.decls:
        return path, None, []
    decls = orig.decls
    if any(d.b is None for d in decls):
        return path, None, []
    # an item owns the text up to the next one
    owns = [(d.b if i else 0, decls[i + 1].b if i + 1 < len(decls) else len(text)) for i, d in enumerate(decls)]
    rng = random.Random("%s:%d" % (os.path.basename(path), seed))
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, (kind, a, b, new) in enumerate(mutations(text, rng, per_kind)):
            mpath = os.path.join(tmp, "m%d.jazz" % n)
            open(mpath, "w").write(new)
            r = run(mpath, None, path)
            hit = [i for i, (s, e) in enumerate(owns) if s < max(b, a + 1) and a < e]
            expected = [i for i in range(len(decls)) if i not in hit]
            found = collections.Counter(d.norm for d in r.decls)
            lost = []
            for i in expected:
                if found[decls[i].norm] > 0:
                    found[decls[i].norm] -= 1
                else:
                    lost.append(i)
            near = set()
            for i in hit:
                near |= {i - 1, i + 1}
            row = dict(file=os.path.basename(path), kind=kind, a=a, b=b, status=r.status,
                       exn=r.exn, decls=len(decls), hit=len(hit), expected=len(expected),
                       lost_near=sum(1 for i in lost if i in near),
                       lost_far=sum(1 for i in lost if i not in near),
                       errors=len(r.errors), error_decls=len(r.error_decls),
                       # text inside errors: item errors, instruction errors, and smaller ones
                       error_chars=union_length([(b, e) for _, b, e in r.spans]),
                       item_errors=sum(1 for k, _, _ in r.spans if k == "item"),
                       instr_errors=sum(1 for k, _, _ in r.spans if k == "instr"),
                       small_errors=sum(1 for k, _, _ in r.spans if k not in ("item", "instr")),
                       damage=b - a, size=len(new), measure=r.measure,
                       nodes=orig.measure[0] if orig.measure else 0)
            # the part of the file outside errors; nothing when the parser fails
            row["parsed"] = 1 - row["error_chars"] / max(1, len(new)) if r.status == "ok" else 0.0
            if keep_dir and (r.status != "ok" or row["lost_far"]):
                name = "%s.%s.%d.jazz" % (os.path.basename(path)[:-5], kind, n)
                open(os.path.join(keep_dir, name), "w").write(new)
                row["kept"] = name
            rows.append(row)
    return path, len(decls), rows


def fuzz(files, seed, per_kind, jobs, keep_dir, out_json):
    if keep_dir:
        os.makedirs(keep_dir, exist_ok=True)
    rows, skipped = [], []
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for path, n, rs in ex.map(fuzz_file, [(f, seed, per_kind, keep_dir) for f in files]):
            if n is None:
                skipped.append(os.path.basename(path))
            rows += rs
    if out_json:
        json.dump(rows, open(out_json, "w"), indent=0)
    print("files: %d used, %d skipped (the original does not parse cleanly)" % (len(files) - len(skipped), len(skipped)))
    # the measure of main.ml (precision, recall, F1 of the nodes of the AST,
    # summed over the runs; a crash recovers nothing), and the error nodes
    hdr = "%-11s %6s %6s %10s %8s %8s %9s %10s %9s %10s" % (
        "edit", "runs", "crash", "precision", "recall", "F1", "item-errs", "instr-errs", "expr-errs", "err-chars")
    print(hdr)
    print("-" * len(hdr))
    kinds = sorted(set(r["kind"] for r in rows), key=lambda k: [r["kind"] for r in rows].index(k))
    for k in kinds + ["TOTAL"]:
        rs = [r for r in rows if k == "TOTAL" or r["kind"] == k]
        ok = [r for r in rs if r["status"] == "ok" and r["measure"]]
        n = max(1, len(ok))
        # a crash recovers none of the nodes of the original
        exp = sum(r["measure"][0] if r["measure"] else r["nodes"] for r in rs)
        rec = sum(r["measure"][1] for r in ok)
        mat = sum(r["measure"][2] for r in ok)
        prec = 100.0 * mat / rec if rec else 100.0
        recall = 100.0 * mat / exp if exp else 100.0
        f1 = 2 * prec * recall / (prec + recall) if prec + recall else 0.0
        print("%-11s %6d %6d %9.2f%% %7.2f%% %7.2f%% %9.2f %10.2f %9.2f %10.1f" % (
            k, len(rs), sum(r["status"] != "ok" for r in rs), prec, recall, f1,
            sum(r["item_errors"] for r in ok) / n, sum(r["instr_errors"] for r in ok) / n,
            sum(r["small_errors"] for r in ok) / n,
            sum(r["error_chars"] for r in ok) / n))
    exns = collections.Counter(r["exn"] for r in rows if r["status"] == "crash")
    if exns:
        print("\ncrashes:")
        for e, c in exns.most_common():
            print("  %5d  %s" % (c, e[:150]))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show"); s.add_argument("files", nargs="+")
    f = sub.add_parser("fuzz"); f.add_argument("files", nargs="+")
    f.add_argument("--seed", type=int, default=0)
    f.add_argument("--per-kind", type=int, default=10, help="mutations of each kind per file")
    f.add_argument("-j", type=int, default=os.cpu_count())
    f.add_argument("--keep", help="directory where to save the failing mutants")
    f.add_argument("--json", help="write every run to this file")
    a = ap.parse_args()
    if a.cmd == "show":
        for p in a.files:
            if len(a.files) > 1:
                print("===", p)
            sys.stdout.write(show(p))
    else:
        fuzz(a.files, a.seed, a.per_kind, a.j, a.keep, a.json)


if __name__ == "__main__":
    main()
