r"""
Persistent regression test for the tolerance-box manual override (Part 3,
2026-09-29) added to compute_effective_overflow_pct in maya_camera_panels.py
/ maya_camera_panels_LR.py -- the "override plumbing" step of the approved
build order (override -> live-verify -> readout), same position in that
sequence as tests/test_edge_guard_curve_logic.py was for G+B.

Run directly, no live Maya session required and NO mayapy (banned
workspace-wide -- see CLAUDE.md):

    python tests/test_tolerance_override_logic.py

Exits 0 if all checks pass, 1 otherwise.

Method: same as test_edge_guard_curve_logic.py -- extracts the real
compute_effective_overflow_pct via `ast` from the real panel files (never
imports them, since their module-level code needs a live Maya scene), so
this exercises the ACTUAL shipped function, not a hand-copied
reimplementation that could quietly drift from it.

What this test does NOT cover (deliberately, per the approved plan -- these
belong to the live-verify step, not this persisted test): reading the real
_camera_tolerance_pct.txt file end to end (get_manual_tolerance_pct's own
file I/O), and the launcher's PowerShell-side plumbing (state file
read/write, the Tolerance textbox, Get-FrameGateEffectiveOverflowPct's own
mirror). Those need a live Maya bridge run / the real launcher, not a pure
Python check.
"""
import ast
import os
import sys
import traceback

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
FB_PANELS_PATH = os.path.join(REPO_ROOT, "scripts", "maya", "maya_camera_panels.py")
LR_PANELS_PATH = os.path.join(REPO_ROOT, "scripts", "maya", "maya_camera_panels_LR.py")


def load_constant(py_path, const_name):
    """Extracts a top-level `NAME = <number literal>` assignment via ast --
    same technique as test_edge_guard_curve_logic.py's own load_constant."""
    with open(py_path) as f:
        source = f.read()
    tree = ast.parse(source, filename=py_path)
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 \
                and isinstance(node.targets[0], ast.Name) and node.targets[0].id == const_name:
            return ast.literal_eval(node.value)
    raise LookupError("%s not found as a top-level constant in %s" % (const_name, py_path))


def load_function(py_path, func_name):
    """Extracts and execs exactly one top-level function from py_path via
    ast, without running any of the file's other module-level code (which
    needs a real Maya scene). Same technique as test_edge_guard_curve_logic
    .py's own load_function, PLUS: compute_effective_overflow_pct's body
    references the module-level MARGIN_SAFETY constant as a free variable
    (not a parameter) -- ast-extracting only the function itself drops that
    binding, so it's read via load_constant and injected into the function's
    own globals dict before the function is ever called (Python resolves
    globals at CALL time, not def time, so this is safe to do after exec'ing
    the def statement, not just before)."""
    with open(py_path) as f:
        source = f.read()
    tree = ast.parse(source, filename=py_path)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            func_source = ast.get_source_segment(source, node)
            ns = {}
            exec(compile(func_source, py_path, "exec"), ns)
            try:
                ns["MARGIN_SAFETY"] = load_constant(py_path, "MARGIN_SAFETY")
            except LookupError:
                pass  # this particular function/file doesn't need it
            return ns[func_name]
    raise LookupError("%s not found as a top-level function in %s" % (func_name, py_path))


_passed = 0
_failures = []


def test_fb_auto_unchanged_by_the_new_parameter():
    """Regression: manual_pct=None (the default -- every pre-existing
    caller that never passes it) must be byte-identical to the formula
    before this parameter existed. Uses a case that gives a nonzero, non-
    clamped result so the comparison is meaningful."""
    fn = load_function(FB_PANELS_PATH, "compute_effective_overflow_pct")
    max_w, needed_ortho, zoom_pct, offset_x_px, panel_width = 200.0, 220.0, 5.0, 0.0, 960.0
    with_default = fn(max_w, needed_ortho, zoom_pct, offset_x_px, panel_width)
    with_explicit_none = fn(max_w, needed_ortho, zoom_pct, offset_x_px, panel_width, None)
    assert with_default == with_explicit_none, (with_default, with_explicit_none)
    assert with_default > 0.0, "test case should exercise a non-clamped, non-trivial value"


def test_fb_manual_pct_bypasses_the_formula_entirely():
    """Core override behavior (M1: override, not additive, not a floor):
    with manual_pct set, the result is EXACTLY manual_pct/100 regardless of
    zoom_pct -- even at a zoom level that would clamp Auto to exactly 0.
    This is the specific property that makes it a real bypass rather than
    something that merely happens to agree with Auto by coincidence."""
    fn = load_function(FB_PANELS_PATH, "compute_effective_overflow_pct")
    max_w, needed_ortho, panel_width = 200.0, 220.0, 960.0

    # A zoom extreme enough that Auto clamps to 0 (confirm the clamp fires
    # first, so the manual case below is a genuine bypass of it).
    auto_at_extreme_zoom = fn(max_w, needed_ortho, 90.0, 0.0, panel_width)
    assert auto_at_extreme_zoom == 0.0, "test setup expects Auto to clamp to 0 at this zoom"

    for t, zoom in ((0.0, 0.0), (2.0, 5.0), (5.0, 20.0), (10.0, -30.0), (20.0, 90.0)):
        manual = fn(max_w, needed_ortho, zoom, 0.0, panel_width, t)
        assert abs(manual - t / 100.0) < 1e-12, "manual_pct=%s at zoom=%s gave %s, expected exactly %s" % (t, zoom, manual, t / 100.0)


def test_fb_manual_pct_ignores_offset_too():
    """Same bypass property, exercised against offset_x_px instead of
    zoom_pct -- the override must ignore BOTH inputs the Auto formula uses,
    not just one of them."""
    fn = load_function(FB_PANELS_PATH, "compute_effective_overflow_pct")
    max_w, needed_ortho, panel_width = 200.0, 220.0, 960.0
    for offset in (0.0, 50.0, 500.0):
        manual = fn(max_w, needed_ortho, 10.0, offset, panel_width, 7.5)
        assert abs(manual - 0.075) < 1e-12, "manual_pct=7.5 with offset=%s gave %s, expected exactly 0.075" % (offset, manual)


def test_fb_and_lr_agree_on_the_override_given_identical_inputs():
    """Supplementary, same reasoning as gap 1's FB/LR parity check: targets
    copy/paste divergence between the two mirrored files' compute_
    effective_overflow_pct, using synthetic inputs (not the real cache --
    this function doesn't touch cache data at all)."""
    fb_fn = load_function(FB_PANELS_PATH, "compute_effective_overflow_pct")
    lr_fn = load_function(LR_PANELS_PATH, "compute_effective_overflow_pct")
    cases = [
        (200.0, 220.0, 0.0, 0.0, 960.0, None),
        (200.0, 220.0, 15.0, 20.0, 960.0, None),
        (200.0, 220.0, 90.0, 0.0, 960.0, None),
        (200.0, 220.0, 0.0, 0.0, 960.0, 0.0),
        (200.0, 220.0, 40.0, 100.0, 960.0, 3.5),
        (200.0, 220.0, -20.0, 0.0, 960.0, 20.0),
    ]
    for args in cases:
        fb_result = fb_fn(*args)
        lr_result = lr_fn(*args)
        assert fb_result == lr_result, "FB/LR diverged for args=%s: %s vs %s" % (args, fb_result, lr_result)


def test_lr_manual_pct_bypasses_the_formula_entirely():
    """Same core override property as the FB test above, run against the
    LR file directly (not inferred from the parity check alone)."""
    fn = load_function(LR_PANELS_PATH, "compute_effective_overflow_pct")
    max_w, needed_ortho, panel_width = 150.0, 165.0, 960.0
    for t, zoom in ((0.0, 0.0), (2.0, 5.0), (5.0, 20.0), (10.0, -30.0), (20.0, 90.0)):
        manual = fn(max_w, needed_ortho, zoom, 0.0, panel_width, t)
        assert abs(manual - t / 100.0) < 1e-12, "LR manual_pct=%s at zoom=%s gave %s, expected exactly %s" % (t, zoom, manual, t / 100.0)


_test_functions = [
    test_fb_auto_unchanged_by_the_new_parameter,
    test_fb_manual_pct_bypasses_the_formula_entirely,
    test_fb_manual_pct_ignores_offset_too,
    test_fb_and_lr_agree_on_the_override_given_identical_inputs,
    test_lr_manual_pct_bypasses_the_formula_entirely,
]

for _fn in _test_functions:
    try:
        _fn()
    except Exception:
        _failures.append("{}\n{}".format(_fn.__name__, traceback.format_exc()))
    else:
        _passed += 1

print("{} passed, {} failed".format(_passed, len(_failures)))
for _f in _failures:
    print("FAIL:", _f)

sys.exit(1 if _failures else 0)
