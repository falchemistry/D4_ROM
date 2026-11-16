r"""
Regression test for T136 / R3: the two keyer scripts (maya_key_from_cache.py,
maya_key_from_cache_LR.py) used to END with a debug write to a hard-coded
dev path (D:\__backup\claude\maya_debug.txt). On any machine without that
folder (the dist zip) open() raised after the keys were already set, the
launcher log showed a traceback and KEY_FROM_CACHE_OK never printed.

Run directly, no Maya, no mayapy (banned workspace-wide), stdlib only:

    python tests/test_t136_keyer_no_debug_write.py [repo_root]

repo_root is optional (default: the repo this file lives in); pass another
tree (for example a copy of an older commit) to see the test go red on it.
Exits 0 if all checks pass, 1 otherwise. One flushed result line per case,
with a START line before each.

Cases per keyer file:
  1. no string literal in the file names a drive path or maya_debug
  2. no open(..., 'w'/'a'/'x'/'+') call anywhere in the file (the keyer only
     READS the cache; any write would be a write outside the tool folder)
  3. the file's closing statements (everything from the elapsed-time line to
     the end) run with every write-mode open() refused, as on a machine
     without the D: folder, and still print KEY_FROM_CACHE_OK
"""
import ast
import io
import os
import sys
import time
import traceback

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYERS = [
    os.path.join(ROOT, "scripts", "maya", "maya_key_from_cache.py"),
    os.path.join(ROOT, "scripts", "maya", "maya_key_from_cache_LR.py"),
]
WRITE_CHARS = set("wax+")


def _read(path):
    with io.open(path, "r", encoding="utf-8") as f:
        return f.read()


def case_no_drive_or_debug_literal(path):
    tree = ast.parse(_read(path), path)
    bad = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            v = node.value
            low = v.lower()
            if "maya_debug" in low or (len(v) > 2 and v[1:3] == ":\\" and v[0].isalpha()):
                bad.append((node.lineno, v))
    assert not bad, "hard-coded debug/drive path literal(s): %r" % (bad,)


def _open_write_mode(call):
    if not (isinstance(call.func, ast.Name) and call.func.id == "open"):
        return None
    mode = None
    if len(call.args) > 1 and isinstance(call.args[1], ast.Constant):
        mode = call.args[1].value
    for kw in call.keywords:
        if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
            mode = kw.value.value
    if isinstance(mode, str) and (set(mode) & WRITE_CHARS):
        return mode
    return None


def case_no_write_mode_open(path):
    tree = ast.parse(_read(path), path)
    bad = [(n.lineno, _open_write_mode(n)) for n in ast.walk(tree)
           if isinstance(n, ast.Call) and _open_write_mode(n)]
    assert not bad, "open() in a write mode at line(s) %r" % (bad,)


def case_tail_runs_without_d_drive(path):
    src = _read(path)
    lines = src.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("elapsed = time.time() - _t0"):
            start = i
    assert start is not None, "closing 'elapsed = time.time() - _t0' line not found"
    tail = "\n".join(lines[start:]) + "\n"
    refused = []

    def refusing_open(file, mode="r", *a, **k):
        if set(str(mode)) & WRITE_CHARS:
            refused.append(file)
            raise IOError(2, "No such file or directory (simulated missing drive)", str(file))
        return io.open(file, mode, *a, **k)

    ns = {
        "__name__": "t136_tail",
        "time": time,
        "_t0": time.time(),
        "THRESHOLD_PCT": 1.0,
        "scale_cache": {},
        "open": refusing_open,
    }
    old_stdout = sys.stdout
    sys.stdout = captured = io.StringIO()
    try:
        exec(compile(tail, path + "#tail", "exec"), ns)
    finally:
        sys.stdout = old_stdout
    out = captured.getvalue()
    assert "KEY_FROM_CACHE_OK" in out, "KEY_FROM_CACHE_OK not printed; output=%r" % out
    assert not refused, "a write-mode open() was attempted: %r" % (refused,)


CASES = [
    ("no_drive_or_debug_literal", case_no_drive_or_debug_literal),
    ("no_write_mode_open", case_no_write_mode_open),
    ("tail_runs_without_d_drive", case_tail_runs_without_d_drive),
]


def main():
    passed, failures = 0, []
    for path in KEYERS:
        for name, fn in CASES:
            label = "%s::%s" % (os.path.basename(path), name)
            print("START " + label)
            sys.stdout.flush()
            try:
                fn(path)
            except Exception as exc:
                failures.append(label)
                print("FAIL  %s -- %s" % (label, str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__))
                if os.environ.get("T136_TRACE"):
                    traceback.print_exc()
            else:
                passed += 1
                print("PASS  " + label)
            sys.stdout.flush()
    print("{} passed, {} failed".format(passed, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
