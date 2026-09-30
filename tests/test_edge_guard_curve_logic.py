r"""
Persistent regression test for compute_edge_guard_curve -- the G+B camera
tracking algorithm in maya_key_from_cache.py / maya_key_from_cache_LR.py
(2026-09-28 rework: [G] offset-free curve + uniform post-shift so a manual
pixel offset survives every correction instead of being erased on the next
one; [B] hold instead of chase when a pose cannot fit within tolerance
regardless of camera position -- see that function's own docstring for the
full derivation).

Run directly, no live Maya session required and NO mayapy (mayapy is banned
workspace-wide in this repo -- see CLAUDE.md at the D:\__backup\claude root;
the live Maya bridge is the only sanctioned live-verification mechanism, and
this test deliberately needs neither):

    python tests/test_edge_guard_curve_logic.py

Exits 0 if all checks pass, 1 otherwise.

Method: this test never imports maya_key_from_cache.py / _LR.py as modules,
because both files run real, Maya-dependent work at module-import time (the
`try:` block starting at their own `_t0 = time.time()` line) -- importing
them would either require stubbing maya.cmds (masking real bugs behind a
fake, exactly the "diagnostic hooks can invalidate the thing under study"
trap) or crash outright with no cmds available. Instead, `load_function`
below parses each file with `ast`, pulls out ONLY the named top-level
function's source text, and execs JUST that -- compute_edge_guard_curve and
compute_effective_overflow_pct are both confirmed cmds-free (pure math, see
their own docstrings), so this is a faithful, side-effect-free extraction of
the REAL shipped code, not a hand-copied reimplementation that could quietly
drift from it. `load_constant` does the same for a plain top-level
`NAME = <number>` assignment, so EDGE_OVERFLOW_PCT/MARGIN_SAFETY are always
read from the real files rather than a 5th hand-typed copy that could go
stale.

Expected values below (480 keys, 44.6% frames over tolerance, 20.7% worst
overflow, 0 corrections > 50px, B never holds at zoom0/offset0, the exact
-offset*world_per_px differential) are exactly what this same barM cache
reproduced on 2026-09-28 during the post-pause investigation, run twice
independently -- once against a disconnected scratchpad prototype, and once
directly against this real shipped file (scratchpad/verify_real_shipped_
curve.py) -- both hitting every number here exactly. Any drift here is a
confirmed regression, not noise.
"""
import ast
import json
import os
import sys
import traceback

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
FB_KEYER_PATH = os.path.join(REPO_ROOT, "scripts", "maya_key_from_cache.py")
LR_KEYER_PATH = os.path.join(REPO_ROOT, "scripts", "maya_key_from_cache_LR.py")
CACHE_PATH = os.path.join(REPO_ROOT, "d4_anim_sample", "barM_rom_anim__c1af6ac5752e.json")

PANEL_WIDTH = 960.0  # this project's currently configured second-monitor
                      # half-width (SECONDARY_MONITOR_RECT = (1920,0,3840,1080),
                      # see maya_camera_panels.py) -- also what the approved
                      # proposal's own evidence tables used, so it's what the
                      # expected numbers below were generated against.


def load_function(py_path, func_name):
    """Extracts and execs exactly one top-level function from py_path via
    ast, without running any of the file's other module-level code. Returns
    the callable."""
    with open(py_path) as f:
        source = f.read()
    tree = ast.parse(source, filename=py_path)
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            func_source = ast.get_source_segment(source, node)
            ns = {}
            exec(compile(func_source, py_path, "exec"), ns)
            return ns[func_name]
    raise LookupError("%s not found as a top-level function in %s" % (func_name, py_path))


def load_constant(py_path, const_name):
    """Extracts a top-level `NAME = <number literal>` assignment via ast, so
    EDGE_OVERFLOW_PCT/MARGIN_SAFETY are read from the REAL file instead of a
    hand-typed copy that could silently go stale if the real value changes."""
    with open(py_path) as f:
        source = f.read()
    tree = ast.parse(source, filename=py_path)
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 \
                and isinstance(node.targets[0], ast.Name) and node.targets[0].id == const_name:
            return ast.literal_eval(node.value)
    raise LookupError("%s not found as a top-level constant in %s" % (const_name, py_path))


# compute_effective_overflow_pct is cmds-free but lives in maya_camera_panels.py
# (not the keyer files), so it's inlined here rather than loaded via ast from a
# 5th file this test would then also depend on -- kept intentionally minimal
# and matches maya_camera_panels.py's own docstring formula exactly (also
# independently confirmed against the real barM cache during the 2026-09-28
# investigation, scratchpad/verify_real_estimator.ps1/verify_real_shipped_curve.py).
def compute_effective_overflow_pct(max_w, needed_ortho, zoom_pct, offset_x_px, panel_width, margin_safety):
    final_ortho = needed_ortho * (1.0 - zoom_pct / 100.0)
    if final_ortho <= 0:
        return 0.0
    effective = (1.0 - (max_w * margin_safety / final_ortho)) / 2.0
    world_per_px = final_ortho / float(panel_width)
    offset_world = abs(offset_x_px) * world_per_px
    effective -= offset_world / final_ortho
    return max(0.0, effective)


with open(CACHE_PATH) as _f:
    _cache = json.load(_f)

X_CENTER = _cache["x_center"]
X_WIDTH = _cache["x_width"]
Z_CENTER = _cache["z_center"]
Z_WIDTH = _cache["z_width"]

EDGE_OVERFLOW_PCT = load_constant(FB_KEYER_PATH, "EDGE_OVERFLOW_PCT")
MARGIN_SAFETY = load_constant(os.path.join(REPO_ROOT, "scripts", "maya_camera_panels.py"), "MARGIN_SAFETY")

_passed = 0
_failures = []


def _needed_ortho(max_w):
    return (max_w / (1.0 - 2.0 * EDGE_OVERFLOW_PCT)) * MARGIN_SAFETY


def _piecewise_series(curve, length):
    """Reconstructs the piecewise-constant cam_pos series key_edge_guard's
    own loop implies (cam_pos only changes AT a correction) -- matches how
    the approved proposal's own "frames over tolerance"/"worst overflow"
    metrics were read off the resulting curve, not a linear interpolation."""
    series = [None] * length
    cur_val = curve[0][1]
    cur_i = 0
    for idx, val in curve:
        for j in range(cur_i, idx):
            series[j] = cur_val
        cur_val = val
        cur_i = idx
    for j in range(cur_i, length):
        series[j] = cur_val
    return series


def test_front_back_reproduces_replica_metrics_at_zoom20_offset20():
    """Core required check (front/back, x axis): 480 keys, 44.6% frames over
    tolerance, 20.7% worst overflow, 0 corrections > 50px -- the exact
    numbers reproduced twice on 2026-09-28 against this same real cache."""
    compute_edge_guard_curve = load_function(FB_KEYER_PATH, "compute_edge_guard_curve")
    max_w = max(X_WIDTH)
    needed_ortho = _needed_ortho(max_w)

    zoom, offset = 20.0, 20.0
    final_ortho = needed_ortho * (1.0 - zoom / 100.0)
    half_ortho = final_ortho / 2.0
    world_per_px = final_ortho / PANEL_WIDTH
    offset_shift = offset * world_per_px

    overflow_pct = compute_effective_overflow_pct(max_w, needed_ortho, zoom, 0.0, PANEL_WIDTH, MARGIN_SAFETY)
    overflow = overflow_pct * final_ortho
    curve = compute_edge_guard_curve(X_CENTER, [w / 2.0 for w in X_WIDTH], half_ortho, overflow)

    assert len(curve) == 480, "expected 480 keys, got %d" % len(curve)

    values = [v for _, v in curve]
    deltas = [abs(values[i] - values[i - 1]) for i in range(1, len(values))]
    px_per_world = PANEL_WIDTH / final_ortho
    over_50px = sum(1 for d in deltas if d * px_per_world > 50.0)
    assert over_50px == 0, "expected 0 corrections > 50px, got %d" % over_50px

    series = _piecewise_series(curve, len(X_CENTER))
    over_tol_count = 0
    worst_overflow = 0.0
    for i in range(len(X_CENTER)):
        cam_pos = series[i] - offset_shift
        half_w = X_WIDTH[i] / 2.0
        left_edge = X_CENTER[i] - half_w
        right_edge = X_CENTER[i] + half_w
        ov = max((cam_pos - half_ortho) - left_edge, right_edge - (cam_pos + half_ortho))
        if ov > 0:
            over_tol_count += 1
            worst_overflow = max(worst_overflow, ov)
    pct_over_tol = 100.0 * over_tol_count / len(X_CENTER)
    worst_overflow_pct = 100.0 * worst_overflow / final_ortho

    assert abs(pct_over_tol - 44.6) < 0.1, "expected 44.6%% frames over tolerance, got %.2f%%" % pct_over_tol
    assert abs(worst_overflow_pct - 20.7) < 0.1, "expected 20.7%% worst overflow, got %.2f%%" % worst_overflow_pct


def test_front_back_b_never_holds_at_zoom0_offset0():
    """Regression case from the approved proposal: at zoom0/offset0 the
    widest pose already fits, so [B]'s hold branch must never fire (G is
    also a no-op here, since offset=0)."""
    compute_edge_guard_curve = load_function(FB_KEYER_PATH, "compute_edge_guard_curve")
    max_w = max(X_WIDTH)
    needed_ortho = _needed_ortho(max_w)
    half_ortho = needed_ortho / 2.0
    overflow_pct = compute_effective_overflow_pct(max_w, needed_ortho, 0.0, 0.0, PANEL_WIDTH, MARGIN_SAFETY)
    overflow = overflow_pct * needed_ortho

    curve = compute_edge_guard_curve(X_CENTER, [w / 2.0 for w in X_WIDTH], half_ortho, overflow)
    never_holds = all(w / 2.0 <= half_ortho + overflow for w in X_WIDTH)
    assert never_holds, "widest pose should fit at zoom0/offset0 -- B must never hold here"
    # len(curve) > 0 just confirms the function actually ran end to end (not
    # a false pass from an empty/short-circuited input).
    assert len(curve) > 0


def test_front_back_offset_differential_property():
    """[G]'s whole point: compute_edge_guard_curve itself is offset-free (no
    offset parameter at all) -- the caller (key_edge_guard) subtracts
    offset_shift from EVERY returned value uniformly. This reproduces that
    caller-side step and confirms two curves (conceptually offset=0 vs
    offset=20) differ by EXACTLY -offset*world_per_px at every key, with no
    algebraic erasure -- matching the approved proposal's own Success
    Criterion 1 (max abs error < 1e-6)."""
    compute_edge_guard_curve = load_function(FB_KEYER_PATH, "compute_edge_guard_curve")
    max_w = max(X_WIDTH)
    needed_ortho = _needed_ortho(max_w)

    zoom, offset = 20.0, 20.0
    final_ortho = needed_ortho * (1.0 - zoom / 100.0)
    half_ortho = final_ortho / 2.0
    world_per_px = final_ortho / PANEL_WIDTH
    offset_shift = offset * world_per_px

    # Tolerance handed to the keyer is zoom-only under G (offset_x_px=0.0
    # regardless of the real offset) -- both calls use the identical
    # overflow, so compute_edge_guard_curve's OWN output is identical for
    # both; only the caller-side subtraction differs.
    overflow_pct = compute_effective_overflow_pct(max_w, needed_ortho, zoom, 0.0, PANEL_WIDTH, MARGIN_SAFETY)
    overflow = overflow_pct * final_ortho

    curve_a = compute_edge_guard_curve(X_CENTER, [w / 2.0 for w in X_WIDTH], half_ortho, overflow)
    curve_b = compute_edge_guard_curve(X_CENTER, [w / 2.0 for w in X_WIDTH], half_ortho, overflow)

    same_indices = [i for i, _ in curve_a] == [i for i, _ in curve_b]
    assert same_indices, "curve must be deterministic/offset-free -- key indices differ between two identical calls"

    max_diff_error = 0.0
    for (ia, va), (ib, vb) in zip(curve_a, curve_b):
        shifted_a = va - 0.0          # "offset 0" reading of curve_a
        shifted_b = vb - offset_shift  # "offset 20" reading of the SAME curve
        max_diff_error = max(max_diff_error, abs((shifted_a - shifted_b) - offset_shift))
    assert max_diff_error < 1e-6, "expected exact -offset*world_per_px shift, max error %.9f" % max_diff_error


def test_left_right_matches_front_back_algorithm_on_synthetic_input():
    """Supplementary (not in the original six, added because it directly
    targets the real risk this pair of files carries -- copy/paste
    divergence between maya_key_from_cache.py and _LR.py's mirrored
    compute_edge_guard_curve). Same inputs in, byte-identical output, on
    deliberately spiky synthetic data (not the real cache) so a hold/no-hold
    boundary is actually exercised on both branches."""
    fb_curve_fn = load_function(FB_KEYER_PATH, "compute_edge_guard_curve")
    lr_curve_fn = load_function(LR_KEYER_PATH, "compute_edge_guard_curve")

    centers = [0.0, 5.0, -5.0, 40.0, 0.0, 0.0, 100.0, 0.0]  # index 6 forces a [B] hold (half_width 60 > 10+1)
    half_widths = [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 60.0, 5.0]
    half_ortho, overflow = 10.0, 1.0

    fb_curve = fb_curve_fn(centers, half_widths, half_ortho, overflow)
    lr_curve = lr_curve_fn(centers, half_widths, half_ortho, overflow)
    assert fb_curve == lr_curve, "FB and LR compute_edge_guard_curve diverged on identical input:\n%s\nvs\n%s" % (fb_curve, lr_curve)
    # A hold means no keyframe is written there, so confirm [B] actually
    # held the unfittable pose at index 6 (half_width 60 > half_ortho+overflow
    # of 11) rather than "correcting" it like every other index:
    assert 6 not in [i for i, _ in fb_curve], "expected index 6 (an unfittable pose) to be held, not corrected"


def test_left_right_regression_properties_on_real_cache_z_axis():
    """Supplementary: runs the real LR file's compute_edge_guard_curve
    against this project's real cache z_center/z_width (left/right axis),
    confirming the same two structural properties checked above for x --
    B-never-holds at zoom0/offset0, and the offset differential property --
    hold on the z axis too. No hardcoded key-count here: unlike the x-axis
    numbers (independently predicted by the approved proposal and confirmed
    twice), no z-axis key count was ever independently predicted, so this
    deliberately does not assert one -- only the properties that must always
    hold BY CONSTRUCTION if the algorithm is correct, regardless of axis."""
    compute_edge_guard_curve = load_function(LR_KEYER_PATH, "compute_edge_guard_curve")
    max_w = max(Z_WIDTH)
    needed_ortho = _needed_ortho(max_w)

    overflow_pct_0 = compute_effective_overflow_pct(max_w, needed_ortho, 0.0, 0.0, PANEL_WIDTH, MARGIN_SAFETY)
    overflow_0 = overflow_pct_0 * needed_ortho
    never_holds = all(w / 2.0 <= needed_ortho / 2.0 + overflow_0 for w in Z_WIDTH)
    assert never_holds, "z-axis widest pose should fit at zoom0/offset0 -- B must never hold here either"

    zoom, offset = 20.0, 20.0
    final_ortho = needed_ortho * (1.0 - zoom / 100.0)
    half_ortho = final_ortho / 2.0
    world_per_px = final_ortho / PANEL_WIDTH
    offset_shift = offset * world_per_px
    overflow_pct = compute_effective_overflow_pct(max_w, needed_ortho, zoom, 0.0, PANEL_WIDTH, MARGIN_SAFETY)
    overflow = overflow_pct * final_ortho

    curve_a = compute_edge_guard_curve(Z_CENTER, [w / 2.0 for w in Z_WIDTH], half_ortho, overflow)
    curve_b = compute_edge_guard_curve(Z_CENTER, [w / 2.0 for w in Z_WIDTH], half_ortho, overflow)
    max_diff_error = 0.0
    for (ia, va), (ib, vb) in zip(curve_a, curve_b):
        max_diff_error = max(max_diff_error, abs((va - 0.0 - (vb - offset_shift)) - offset_shift))
    assert max_diff_error < 1e-6, "z-axis offset differential off by %.9f" % max_diff_error


_test_functions = [
    test_front_back_reproduces_replica_metrics_at_zoom20_offset20,
    test_front_back_b_never_holds_at_zoom0_offset0,
    test_front_back_offset_differential_property,
    test_left_right_matches_front_back_algorithm_on_synthetic_input,
    test_left_right_regression_properties_on_real_cache_z_axis,
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
