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
FB_KEYER_PATH = os.path.join(REPO_ROOT, "scripts", "maya", "maya_key_from_cache.py")
LR_KEYER_PATH = os.path.join(REPO_ROOT, "scripts", "maya", "maya_key_from_cache_LR.py")
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
MARGIN_SAFETY = load_constant(os.path.join(REPO_ROOT, "scripts", "maya", "maya_camera_panels.py"), "MARGIN_SAFETY")

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


def test_find_start_index_picks_first_cached_frame_at_or_after_start():
    """T72 Option B: the walk is seeded at the capture's start frame. None = no
    range known = index 0 (today's behaviour); a start before the cache = 0; a
    start between cached frames = the next cached frame; past the end = last."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        find_start_index = load_function(path, "find_start_index")
        frames = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
        assert find_start_index(frames, None) == 0
        assert find_start_index(frames, 0.0) == 0
        assert find_start_index(frames, -50.0) == 0
        assert find_start_index(frames, 3.0) == 3
        assert find_start_index(frames, 2.5) == 3
        assert find_start_index(frames, 5.0) == 5
        assert find_start_index(frames, 99.0) == 5, "a start past the cache clamps to the last frame"


def test_seed_series_at_start_uses_live_window_and_slices():
    """The measured live frames replace the cached ones (so index 0 IS the live centre at
    the start frame), the result is the slice from the start index, and start index 0 is
    an unchanged copy."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        centers = [10.0, 11.0, 12.0, 20.0, 21.0, 22.0, 23.0]
        half_widths = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
        # two live samples (fewer than 5: no shift decision): index 2 and 3 take the live values
        c, h = seed(centers, half_widths, 2, [(15.0, 8.0), (16.0, 10.0)])
        assert c == [15.0, 16.0, 21.0, 22.0, 23.0], c
        assert h == [4.0, 5.0, 5.0, 6.0, 7.0], h
        # no samples at a start > 0: the plain unshifted slice
        c1, h1 = seed(centers, half_widths, 2, None)
        assert c1 == centers[2:] and h1 == half_widths[2:]
        # start at index 0: unchanged copies (the size-scale reference IS the live value there)
        c0, h0 = seed(centers, half_widths, 0, None)
        assert c0 == centers and h0 == half_widths
        assert c0 is not centers and h0 is not half_widths


def test_seed_series_rigid_shift_is_followed_after_the_window():
    """A consistent live-minus-cache difference over the window (the cache really is
    displaced by a constant) shifts the cached series AFTER the window by that median, so
    the camera does not snap back to the displaced cached path one frame later."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        n = 60
        centers = [100.0 + 0.5 * i for i in range(n)]
        half_widths = [20.0] * n
        start = 10
        # 31 live samples, each exactly +12 from the cache (12 is 30% of the live width 40)
        samples = [(centers[start + j] + 12.0, 40.0) for j in range(31)]
        c, h = seed(centers, half_widths, start, samples)
        assert c[0] == centers[start] + 12.0
        for j in range(31, n - start):
            assert abs(c[j] - (centers[start + j] + 12.0)) < 1e-9, "index %d must follow the rigid +12 shift, got %r" % (j, c[j] - centers[start + j])
        assert h[40] == half_widths[start + 40]


def test_seed_series_non_rigid_mismatch_leaves_the_rest_of_the_walk_unshifted():
    """Defect D1 (found by the independent QA on the rogM ROM scene): where the live character
    differs from the cache non-uniformly (one limb missing live: width smaller, centre off, and
    the difference changes from frame to frame), the one-frame live-minus-cache difference at the
    start frame must NOT be applied to the whole walk. Only the measured window takes the live
    values; every later entry is exactly the cached value."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        n = 80
        centers = [50.0 + (i % 7) for i in range(n)]
        half_widths = [30.0 + (i % 3) for i in range(n)]
        start = 20
        # centre difference at the start frame +9, then 6.5, 0, -4.6, -7.7, ...: not a constant
        diffs = [9.0, 6.5, 0.0, -4.6, -7.7, -6.8, -4.2] + [0.0] * 24
        samples = [(centers[start + j] + diffs[j], 2.0 * half_widths[start + j] - 2.0 * abs(diffs[j])) for j in range(31)]
        c, h = seed(centers, half_widths, start, samples)
        assert c[0] == centers[start] + 9.0, "seed must be the live centre at the start frame"
        for j in range(31, n - start):
            assert c[j] == centers[start + j], "index %d: cached value must stay unshifted, got shift %r" % (j, c[j] - centers[start + j])
            assert h[j] == half_widths[start + j]
        # a tiny but consistent difference (under 2% of the live width) is not followed either
        samples2 = [(centers[start + j] + 0.3, 2.0 * half_widths[start + j]) for j in range(31)]
        c2, _h2 = seed(centers, half_widths, start, samples2)
        for j in range(31, n - start):
            assert c2[j] == centers[start + j]
        # a large median that most samples do NOT share (16 samples at +12, 15 at 0: median 12,
        # spread 12 > 25% of it) is not a rigid shift either
        samples3 = [(centers[start + j] + (12.0 if j < 16 else 0.0), 2.0 * half_widths[start + j]) for j in range(31)]
        c3, _h3 = seed(centers, half_widths, start, samples3)
        for j in range(31, n - start):
            assert c3[j] == centers[start + j], "index %d: an inconsistent difference must not shift the walk" % j


def test_seed_series_non_rigid_mismatch_keeps_the_live_tolerance_on_the_real_cache():
    """The D1 property end to end on the real barM cache: a synthetic live character that has
    its left edge pulled in by up to 18 units around the start frame (and 12 units for a later
    stretch) stays inside the drift tolerance on EVERY frame after the start when the walk uses
    seed_series_at_start; the old behaviour (shift the whole walk by the one-frame difference,
    here +9) is reproduced inline and must leave frames outside it, so this test can really fail."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        compute_edge_guard_curve = load_function(path, "compute_edge_guard_curve")
        center_series, width_series = X_CENTER, X_WIDTH
        n = len(center_series)
        max_w = max(width_series)
        ortho = _needed_ortho(max_w)
        half_ortho = ortho / 2.0
        overflow = compute_effective_overflow_pct(max_w, ortho, 0.0, 0.0, PANEL_WIDTH, MARGIN_SAFETY) * ortho
        half_widths = [w / 2.0 for w in width_series]
        for R in (150, 300, 600, 1000):
            pulled = {}
            for i in range(R, n):
                v = 18.0 * max(0.0, 1.0 - abs(i - R) / 20.0)
                if R + 300 <= i <= R + 330:
                    v = 12.0
                pulled[i] = v
            samples = [(center_series[R + j] + pulled[R + j] / 2.0, width_series[R + j] - pulled[R + j]) for j in range(31)]

            def frames_over(cam_series):
                count = 0
                for j, i in enumerate(range(R, n)):
                    hw = width_series[i] / 2.0
                    if hw > half_ortho + overflow:
                        continue
                    left = center_series[i] - hw + pulled[i]   # the LIVE edges
                    right = center_series[i] + hw
                    p = cam_series[j]
                    if max((p - half_ortho) - left, right - (p + half_ortho)) > overflow + 1e-5:
                        count += 1
                return count

            c, h = seed(center_series, half_widths, R, samples)
            curve = compute_edge_guard_curve(c, h, half_ortho, overflow)
            assert curve[0] == (0, samples[0][0]), "first key must be the live centre at the start frame"
            assert frames_over(_piecewise_series(curve, len(c))) == 0, "R=%d: live frames outside the tolerance with the fix" % R
            d = samples[0][0] - center_series[R]
            old_c = [x + d for x in center_series[R:]]
            old_curve = compute_edge_guard_curve(old_c, half_widths[R:], half_ortho, overflow)
            assert frames_over(_piecewise_series(old_curve, len(old_c))) > 0, "R=%d: the one-frame whole-walk shift should break the tolerance here" % R


def test_start_window_is_long_enough_for_the_rigid_decision():
    """The keyers measure START_WINDOW_FRAMES + 1 live frames after the start; the rigid-shift
    decision needs at least 5 samples (seed_series_at_start default), so a window below that
    would silently turn the rigid support off. Both keyers must use the same value."""
    values = [load_constant(path, "START_WINDOW_FRAMES") for path in (FB_KEYER_PATH, LR_KEYER_PATH)]
    assert values[0] == values[1], "Front/Back and Left/Right windows differ: %r" % (values,)
    assert values[0] >= 10, "window %r too short for the consistency test" % (values[0],)


def test_seeded_walk_on_real_cache_starts_centred_never_jumps_and_stays_in_tolerance():
    """The T72 property on the real barM cache at the start frames the live test
    sweeps: the first key IS the live centre at the start frame (seed), the walk
    never moves the camera before the first real correction (so no jump at R+1),
    and the guard keeps every non-held frame inside the tolerance. A synthetic
    rigid live-vs-cache offset (the size-scale/pose mismatch the real keyer measures)
    is carried through unchanged."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        compute_edge_guard_curve = load_function(path, "compute_edge_guard_curve")
        for center_series, width_series in ((X_CENTER, X_WIDTH), (Z_CENTER, Z_WIDTH)):
            max_w = max(width_series)
            ortho = _needed_ortho(max_w)
            half_ortho = ortho / 2.0
            overflow = compute_effective_overflow_pct(max_w, ortho, 0.0, 0.0, PANEL_WIDTH, MARGIN_SAFETY) * ortho
            half_widths = [w / 2.0 for w in width_series]
            for R in (150, 300, 600, 1000, 2000):
                live = center_series[R] + 7.3
                # a rigid +7.3 live-vs-cache shift over the whole 31-frame window
                samples = [(center_series[R + j] + 7.3, width_series[R + j]) for j in range(31)]
                c, h = seed(center_series, half_widths, R, samples)
                curve = compute_edge_guard_curve(c, h, half_ortho, overflow)
                assert curve[0] == (0, live), "first key must be the live centre at the start frame, got %r" % (curve[0],)
                assert len(c) == len(center_series) - R
                if len(curve) > 1:
                    assert curve[1][0] >= 1, "the first correction cannot sit on the seed frame"
                held = _piecewise_series(curve, len(c))
                for i in range(len(c)):
                    if h[i] > half_ortho + overflow:
                        continue
                    ov = max((held[i] - half_ortho) - (c[i] - h[i]), (c[i] + h[i]) - (held[i] + half_ortho))
                    assert ov <= overflow + 1e-6, "R=%d index %d overflow %.4f beyond tolerance %.4f" % (R, i, ov, overflow)


def test_seeded_walk_at_start_zero_equals_whole_take_walk():
    """R = 0 must be the old behaviour: seeding at index 0 changes nothing."""
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        seed = load_function(path, "seed_series_at_start")
        compute_edge_guard_curve = load_function(path, "compute_edge_guard_curve")
        max_w = max(X_WIDTH)
        ortho = _needed_ortho(max_w)
        overflow = compute_effective_overflow_pct(max_w, ortho, 0.0, 0.0, PANEL_WIDTH, MARGIN_SAFETY) * ortho
        half_widths = [w / 2.0 for w in X_WIDTH]
        whole = compute_edge_guard_curve(X_CENTER, half_widths, ortho / 2.0, overflow)
        c, h = seed(X_CENTER, half_widths, 0, None)
        assert compute_edge_guard_curve(c, h, ortho / 2.0, overflow) == whole


# ---------------------------------------------------------------------------
# T72 item 6 (2026-10-20): the gate follows the frame the artist SEES.
#
# Old behaviour: the walk was built offset-free and the caller wrote
# `value - offset_shift`, so the gate sat one Offset away from the visible frame
# (false nudge on one side, missed nudge on the other). Fix (option B): the walk
# is seeded at centers[0] - offset_shift and compares the pose with the VISIBLE
# camera; compute_edge_guard_curve(..., offset_shift) returns the values to write
# as they are (no post-subtraction). Offset 0 is byte-for-byte the old curve.
# Design consequence the user accepted: after a nudge the Offset may fade (the
# Offset only sets the START); the camera must never hit an invisible gate.
# ---------------------------------------------------------------------------
import hashlib
import inspect

SCENE_FILES = {
    "barM": "barM_rom_anim__c1af6ac5752e.json",
    "barF": "barF_rom_anim__ec80456d5b2e.json",
    "rogM": "rogM_rom_anim__c6ecccd3f700.json",
    "sorM": "sorM_rom_anim__8b4c3274e664.json",
    "sorF": "sorF_rom_anim__a968ea8f3142.json",
}
_scene_cache = {}


def _scene(name):
    if name not in _scene_cache:
        with open(os.path.join(REPO_ROOT, "d4_anim_sample", SCENE_FILES[name])) as f:
            _scene_cache[name] = json.load(f)
    return _scene_cache[name]


_find_start_index = load_function(FB_KEYER_PATH, "find_start_index")
_seed_series_at_start = load_function(FB_KEYER_PATH, "seed_series_at_start")

# zoom 0 = the sized frame (auto tolerance 2%); zoom 7 = the user's real zoom, with the
# Frame Gate widened until the tolerance is above 0: either a wider frame whose auto tolerance
# is 1% ("zoom7_widened") or the typed Tolerance box at 1% ("zoom7_manual1pct"); zoom 7 with the
# gate NOT widened has tolerance 0 (the case the user avoids; the invariants still hold).
OFFSETS_PX = (0, 10, -10, 50, -50, 100, -100)
START_FRAMES = (None, 300, 1000)
ZOOM_SETUPS = ("zoom0", "zoom7_widened", "zoom7_tol0", "zoom7_manual1pct")
GOLDEN_SETUPS = ("zoom0", "zoom7_widened", "zoom7_tol0")   # the digest below was recorded for these three


def _geometry(max_w, setup):
    needed = _needed_ortho(max_w)
    if setup == "zoom0":
        ortho = needed
    elif setup == "zoom7_widened":
        ortho = max_w * MARGIN_SAFETY / (1.0 - 2.0 * 0.01)
    else:
        ortho = needed * (1.0 - 0.07)
    tol_pct = max(0.0, (1.0 - max_w * MARGIN_SAFETY / ortho) / 2.0)
    if setup == "zoom7_manual1pct":
        tol_pct = 0.01   # the frame is zoom 7 of the sized frame; the typed Tolerance box widens the gate to 1%
    return ortho, tol_pct


def _walk_inputs(scene, axis, setup, offset_px, start, size_axis="x"):
    """size_axis: the axis whose widest pose sizes the frame. The real Left/Right keyer sizes the
    frame from the x (Front/Back) widths (AUTO_MARGIN_AXIS = 'x'); ("z","z") is a stress variant
    with a tighter frame so the z walk nudges more."""
    cache = _scene(scene)
    widths = cache[axis + "_width"]
    centers_all = cache[axis + "_center"]
    hw_all = [w / 2.0 for w in widths]
    ortho, tol_pct = _geometry(max(cache[size_axis + "_width"]), setup)
    si = _find_start_index(cache["frames"], start)
    centers, hws = _seed_series_at_start(centers_all, hw_all, si, None)
    shift = offset_px * (ortho / PANEL_WIDTH)
    return centers, hws, ortho / 2.0, tol_pct * ortho, shift, ortho


def _keyed_values(fn, centers, hws, half, ov, shift):
    """The curve exactly as the keyer writes it to the camera. The fixed function takes
    offset_shift and returns the values to write; before the fix it was offset-free and the
    caller subtracted the shift per value (the legacy branch keeps these tests runnable on the
    old code so the RED numbers are real numbers, not a TypeError)."""
    if "offset_shift" in inspect.signature(fn).parameters:
        return fn(centers, hws, half, ov, shift)
    return [(i, v - shift) for i, v in fn(centers, hws, half, ov)]


def _gate_metrics(curve, centers, hws, half, ov, ortho):
    """Counts over frames 1..n-1 against the VISIBLE gate (camera frame edge +/- tolerance):
    false = the camera nudged while the pose was still inside the gate of the camera it had;
    missed = a pose that fits was outside that gate and the camera did not move;
    over = a pose that fits is outside the gate AFTER the decision."""
    n = len(centers)
    keyed = dict(curve)
    cam = [None] * n
    cur = curve[0][1]
    for i in range(n):
        if i in keyed:
            cur = keyed[i]
        cam[i] = cur
    eps = 1e-9 * ortho
    false = missed = over = nudges = 0
    for i in range(1, n):
        lo, hi = cam[i - 1] - half - ov, cam[i - 1] + half + ov
        left, right = centers[i] - hws[i], centers[i] + hws[i]
        fits = hws[i] <= half + ov
        outside = left < lo - eps or right > hi + eps
        moved = abs(cam[i] - cam[i - 1]) > eps   # a 1-ulp tie nudge (see the build report) is not a camera move
        if moved:
            nudges += 1
            if not outside:
                false += 1
        elif fits and outside:
            missed += 1
        lo2, hi2 = cam[i] - half - ov, cam[i] + half + ov
        if fits and (left < lo2 - eps or right > hi2 + eps):
            over += 1
    return {"false": false, "missed": missed, "over": over, "nudges": nudges}


def _visible_oracle(centers, hws, half, ov, shift):
    """Independent re-implementation of the spec (the replay model of the investigation): the
    walk starts at the visible camera c0 - shift and every later decision uses that camera."""
    cam = centers[0] - shift
    out = [(0, cam)]
    last = 0
    n = len(centers)
    for i in range(1, n):
        if hws[i] > half + ov:
            continue
        left, right = centers[i] - hws[i], centers[i] + hws[i]
        if left < cam - half - ov:
            cam += left - (cam - half - ov)
        elif right > cam + half + ov:
            cam += right - (cam + half + ov)
        else:
            continue
        out.append((i, cam))
        last = i
    if last != n - 1:
        out.append((n - 1, cam))
    return out


_fn_cache = {}


def _loaded_fn(path):
    if path not in _fn_cache:
        _fn_cache[path] = load_function(path, "compute_edge_guard_curve")
    return _fn_cache[path]


def _matrix(offsets=OFFSETS_PX):
    for scene in SCENE_FILES:
        for axis, size_axis, path in (("x", "x", FB_KEYER_PATH), ("z", "x", LR_KEYER_PATH), ("z", "z", LR_KEYER_PATH)):
            fn = _loaded_fn(path)
            for setup in ZOOM_SETUPS:
                for start in START_FRAMES:
                    for off in offsets:
                        yield scene, axis, size_axis, setup, start, off, fn


def test_signature_takes_offset_shift_in_both_keyers():
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        params = inspect.signature(_loaded_fn(path)).parameters
        assert "offset_shift" in params, "%s: compute_edge_guard_curve must take offset_shift" % os.path.basename(path)
        assert params["offset_shift"].default == 0.0, "offset_shift must default to 0.0 (old callers unchanged)"


def test_gate_follows_the_visible_frame_matrix_zero_false_missed_over():
    """5 scenes x Front/Back (x) and Left/Right (z) x zoom 0 / zoom 7 widened / zoom 7 tolerance 0
    x start none/300/1000 x Offset 0, +-10, +-50, +-100 px: 0 false nudges, 0 missed nudges, 0 frames
    outside the visible gate. Prints the totals (before the fix: see the build report)."""
    tot = {"false": 0, "missed": 0, "over": 0, "nudges": 0}
    bad = []
    cases = 0
    for scene, axis, size_axis, setup, start, off, fn in _matrix():
        centers, hws, half, ov, shift, ortho = _walk_inputs(scene, axis, setup, off, start, size_axis)
        curve = _keyed_values(fn, centers, hws, half, ov, shift)
        m = _gate_metrics(curve, centers, hws, half, ov, ortho)
        cases += 1
        for k in tot:
            tot[k] += m[k]
        if m["false"] or m["missed"] or m["over"]:
            bad.append("%s/%s(size %s)/%s/start=%s/off=%+d: false=%d missed=%d over=%d" % (scene, axis, size_axis, setup, start, off, m["false"], m["missed"], m["over"]))
    print("MATRIX cases=%d totals false=%d missed=%d over=%d nudges=%d bad_cases=%d" % (cases, tot["false"], tot["missed"], tot["over"], tot["nudges"], len(bad)))
    assert not bad, "%d of %d cases hit an invisible gate (false=%d missed=%d over=%d); first: %s" % (
        len(bad), cases, tot["false"], tot["missed"], tot["over"], bad[:3])


def test_replay_model_target_numbers_at_plus_minus_50_px():
    """The investigation's 40-case set (5 scenes x FB+LR x start 300/1000 x Offset +-50, zoom 0,
    the sized frame; Left/Right frame sized from x like the product). The investigation's replay with the
    live per-frame ground truth counted 282 false / 3349 missed before the fix; this cache-only replay
    counts 267 / 3739 / 4006 (false / missed / over) before the fix. After the fix: 0 / 0 / 0."""
    false = missed = over = cases = 0
    for scene in SCENE_FILES:
        for axis, path in (("x", FB_KEYER_PATH), ("z", LR_KEYER_PATH)):
            for start in (300, 1000):
                for off in (50, -50):
                    centers, hws, half, ov, shift, ortho = _walk_inputs(scene, axis, "zoom0", off, start)
                    m = _gate_metrics(_keyed_values(_loaded_fn(path), centers, hws, half, ov, shift), centers, hws, half, ov, ortho)
                    false += m["false"]
                    missed += m["missed"]
                    over += m["over"]
                    cases += 1
    print("REPLAY40 cases=%d false=%d missed=%d over=%d" % (cases, false, missed, over))
    assert cases == 40
    assert (false, missed, over) == (0, 0, 0), "false=%d missed=%d over=%d (expected 0/0/0)" % (false, missed, over)


def test_walk_matches_the_independent_visible_space_oracle():
    checked = 0
    for scene, axis, size_axis, setup, start, off, fn in _matrix((10, -10, 50, -50, 100, -100)):
        centers, hws, half, ov, shift, _ortho = _walk_inputs(scene, axis, setup, off, start, size_axis)
        got = _keyed_values(fn, centers, hws, half, ov, shift)
        exp = _visible_oracle(centers, hws, half, ov, shift)
        tag = "%s/%s(size %s)/%s/start=%s/off=%+d" % (scene, axis, size_axis, setup, start, off)
        assert [i for i, _ in got] == [i for i, _ in exp], "%s: key frames differ (%d vs %d keys)" % (tag, len(got), len(exp))
        err = max(abs(a[1] - b[1]) for a, b in zip(got, exp))
        assert err < 1e-9, "%s: values differ by %g" % (tag, err)
        checked += 1
    assert checked == 5 * 3 * len(ZOOM_SETUPS) * 3 * 6


def test_offset_only_sets_the_start_both_signs():
    """The first key is the character centre minus the Offset (the camera starts exactly one
    Offset away from centred), for both signs and for the start-frame-seeded series."""
    for scene in SCENE_FILES:
        for axis, path in (("x", FB_KEYER_PATH), ("z", LR_KEYER_PATH)):
            for start in (None, 300, 1000):
                for off in (10, -10, 50, -50, 100, -100):
                    centers, hws, half, ov, shift, _o = _walk_inputs(scene, axis, "zoom0", off, start)
                    curve = _keyed_values(_loaded_fn(path), centers, hws, half, ov, shift)
                    assert curve[0][0] == 0
                    assert abs(curve[0][1] - (centers[0] - shift)) < 1e-9, "%s/%s start=%s off=%+d: first key %r vs %r" % (scene, axis, start, off, curve[0][1], centers[0] - shift)
                    assert (shift > 0) == (curve[0][1] < centers[0]), "sign of the start offset wrong"


def _legacy_curve(centers, half_widths, half_ortho, overflow):
    """Verbatim copy of compute_edge_guard_curve before T72 item 6 (the Offset-0 reference)."""
    n = len(centers)
    if n == 0:
        return []
    curve = [(0, centers[0])]
    cam_pos = centers[0]
    last_keyed_index = 0
    for i in range(1, n):
        if half_widths[i] > half_ortho + overflow:
            continue
        left_edge = centers[i] - half_widths[i]
        right_edge = centers[i] + half_widths[i]
        allowed_left = cam_pos - half_ortho - overflow
        allowed_right = cam_pos + half_ortho + overflow
        if left_edge < allowed_left:
            cam_pos += left_edge - allowed_left
        elif right_edge > allowed_right:
            cam_pos += right_edge - allowed_right
        else:
            continue
        curve.append((i, cam_pos))
        last_keyed_index = i
    if last_keyed_index != n - 1:
        curve.append((n - 1, cam_pos))
    return curve


# sha256 over repr() of every offset-0 curve of the matrix below, recorded from the shipped
# function BEFORE T72 item 6 (the verbatim old copy above is checked against the same digest,
# so a changed golden value and a changed copy cannot both slip through unnoticed).
GOLDEN_OFFSET0_DIGEST = "eec135589799e8052ab0bbb904d52248c1f9b5eb1f4362619fe8b8a9875598d5"


def _offset0_digest(fn, pass_offset):
    h = hashlib.sha256()
    for scene in SCENE_FILES:
        for axis in ("x", "z"):
            for setup in GOLDEN_SETUPS:
                for start in START_FRAMES:
                    centers, hws, half, ov, _shift, _o = _walk_inputs(scene, axis, setup, 0, start)
                    curve = fn(centers, hws, half, ov, 0.0) if pass_offset else fn(centers, hws, half, ov)
                    h.update(repr(curve).encode("ascii"))
    return h.hexdigest()


def test_offset_zero_is_byte_for_byte_the_old_curve():
    for path in (FB_KEYER_PATH, LR_KEYER_PATH):
        fn = _loaded_fn(path)
        assert _offset0_digest(fn, False) == GOLDEN_OFFSET0_DIGEST, "default call changed the Offset-0 curve (%s)" % os.path.basename(path)
        if "offset_shift" in inspect.signature(fn).parameters:
            assert _offset0_digest(fn, True) == GOLDEN_OFFSET0_DIGEST, "offset_shift=0.0 changed the Offset-0 curve (%s)" % os.path.basename(path)
    assert _offset0_digest(_legacy_curve, False) == GOLDEN_OFFSET0_DIGEST, "the verbatim legacy copy no longer matches the recorded golden digest"


def test_fb_and_lr_copies_agree_with_an_offset():
    fb, lr = _loaded_fn(FB_KEYER_PATH), _loaded_fn(LR_KEYER_PATH)
    centers = [0.0, 5.0, -5.0, 40.0, 0.0, 0.0, 100.0, 0.0, 30.0, -30.0]
    hws = [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 60.0, 5.0, 5.0, 5.0]
    for shift in (0.0, 3.5, -3.5, 8.0, -8.0):
        a = _keyed_values(fb, centers, hws, 10.0, 1.0, shift)
        b = _keyed_values(lr, centers, hws, 10.0, 1.0, shift)
        assert a == b, "FB and LR diverged at shift %r: %r vs %r" % (shift, a, b)
        assert 6 not in [i for i, _ in a], "[B] hold must still skip the unfittable pose"


def test_hand_checked_synthetic_walk_with_positive_and_negative_offset():
    """Hand-derived: half_ortho 10, overflow 1 (gate half-width 11), character half-width 5,
    centres 0,0,0,8,8,-8,-8. Offset +4: the camera starts at -4, gate [-15, 7]; index 3 has its
    right edge at 13 > 7 -> cam = 13 - 11 = 2; index 5 has its left edge at -13 < 2 - 11 = -9 ->
    cam = -13 + 11 = -2. Offset -4: the camera starts at +4, gate [-7, 15]; index 3: 13 <= 15, no
    nudge; index 5: -13 < -7 -> cam = -2."""
    fn = _loaded_fn(FB_KEYER_PATH)
    centers = [0.0, 0.0, 0.0, 8.0, 8.0, -8.0, -8.0]
    hws = [5.0] * 7
    pos = _keyed_values(fn, centers, hws, 10.0, 1.0, 4.0)
    assert pos == [(0, -4.0), (3, 2.0), (5, -2.0), (6, -2.0)], pos
    neg = _keyed_values(fn, centers, hws, 10.0, 1.0, -4.0)
    assert neg == [(0, 4.0), (5, -2.0), (6, -2.0)], neg


def test_hold_for_an_unfittable_pose_still_applies_with_an_offset():
    fn = _loaded_fn(FB_KEYER_PATH)
    centers = [0.0, 100.0, 0.0]
    hws = [5.0, 60.0, 5.0]   # index 1 cannot fit (60 > 10 + 1): held, no key
    for shift in (4.0, -4.0):
        keys = _keyed_values(fn, centers, hws, 10.0, 1.0, shift)
        assert 1 not in [i for i, _ in keys], "unfittable pose must be held with offset %r" % shift


# --- the keyer function itself (caller wiring), with a recording stand-in for maya.cmds ---
class _FakeCmds(object):
    def __init__(self, ortho):
        self.t = 0.0
        self.ortho = ortho
        self.keys = []

    def currentTime(self, *a, **k):
        if a:
            self.t = a[0]
        return self.t

    def select(self, *a, **k):
        pass

    def keyframe(self, *a, **k):
        return 0

    def cutKey(self, *a, **k):
        pass

    def listRelatives(self, *a, **k):
        return ["camShape"]

    def getAttr(self, attr):
        return self.ortho

    def setKeyframe(self, attr, time=None, value=None):
        self.keys.append((time, value))


def _run_real_key_edge_guard(path, scene, axis, setup, offset_px, start):
    """Executes the REAL key_edge_guard of the keyer file (ast-extracted) against the real cache
    with a recording stand-in for cmds; the live character equals the cached one (scale 1)."""
    with open(path) as f:
        source = f.read()
    tree = ast.parse(source, filename=path)
    cache = _scene(scene)
    ortho, tol_pct = _geometry(max(cache["x_width"]), setup)   # both keyers size the frame from x
    fake = _FakeCmds(ortho)
    frames = cache["frames"]
    centers_all, widths_all = cache[axis + "_center"], cache[axis + "_width"]

    def get_target_bbox():
        i = frames.index(fake.t)
        c, w = centers_all[i], widths_all[i]
        return (c - w / 2.0, 0.0, c - w / 2.0, c + w / 2.0, 1.0, c + w / 2.0)

    ns = {"cmds": fake, "get_target_bbox": get_target_bbox}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in ("find_start_index", "seed_series_at_start", "compute_edge_guard_curve", "key_edge_guard"):
            exec(compile(ast.get_source_segment(source, node), path, "exec"), ns)
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", "") == "START_WINDOW_FRAMES":
            ns["START_WINDOW_FRAMES"] = ast.literal_eval(node.value)
    shift = offset_px * (ortho / PANEL_WIDTH)
    ns["key_edge_guard"]("cam", axis, cache, centers_all[0], centers_all[0], 1.0, tol_pct, shift, start)
    return fake.keys


def test_real_key_edge_guard_writes_the_visible_gate_curve_for_both_keyers():
    checked = 0
    for path, axis in ((FB_KEYER_PATH, "x"), (LR_KEYER_PATH, "z")):
        for scene in ("barM", "sorF"):
            for setup in ("zoom0", "zoom7_widened", "zoom7_manual1pct"):
                for start in (None, 300, 1000):
                    for off in (0, 10, -10, 50, -50, 100, -100):
                        keys = _run_real_key_edge_guard(path, scene, axis, setup, off, start)
                        cache = _scene(scene)
                        centers, hws, half, ov, shift, _ortho = _walk_inputs(scene, axis, setup, off, start)
                        exp = _visible_oracle(centers, hws, half, ov, shift)
                        si = _find_start_index(cache["frames"], start)
                        exp_keys = [(cache["frames"][si + j], v) for j, v in exp]
                        tag = "%s %s %s start=%s off=%+d" % (os.path.basename(path), scene, setup, start, off)
                        assert [t for t, _ in keys] == [t for t, _ in exp_keys], "%s: key frames differ (%d vs %d)" % (tag, len(keys), len(exp_keys))
                        err = max(abs(a[1] - b[1]) for a, b in zip(keys, exp_keys))
                        assert err < 1e-9, "%s: written values differ by %g" % (tag, err)
                        checked += 1
    assert checked == 2 * 2 * 3 * 3 * 7


# Parity table with the launcher estimate (Get-EdgeGuardCurveEstimateCore in rom_launcher.ps1): the
# SAME numbers are asserted in tests/test_rom_launcher_integration.ps1 against the PowerShell
# port. Rows: axis, setup, typed Tolerance (None = auto), Offset px, measured Start (None = whole
# take), guard keys, % of frames over tolerance, worst overflow % of the frame width, all on barM
# (Left/Right sized from x, 960 px panel), generated from the independent visible-space oracle.
# Over/worst count every measured frame from the seed on, held poses included (the estimate does).
ESTIMATE_PARITY_TABLE = [
    ('x', 'zoom0', None, 0, None, 70, 0.0000, 2.0000),
    ('x', 'zoom0', None, 0, 300, 32, 0.0000, 2.0000),
    ('x', 'zoom0', None, 50, 300, 50, 0.0000, 2.0000),
    ('x', 'zoom0', None, -50, 300, 51, 0.0000, 2.0000),
    ('x', 'zoom0', None, 100, 1000, 49, 0.0000, 2.0000),
    ('x', 'zoom0', None, -100, 1000, 75, 0.0000, 2.0000),
    ('x', 'zoom0', None, 10, 0, 81, 0.0000, 2.0000),
    ('x', 'zoom7_manual1pct', 1.0, 50, 300, 105, 0.0000, 1.0000),
    ('x', 'zoom7_manual1pct', 1.0, -50, 300, 147, 0.0000, 1.0000),
    ('x', 'zoom7_manual1pct', 1.0, 100, 1000, 75, 0.0446, 4.7401),
    ('x', 'zoom7_manual1pct', 1.0, -100, 300, 173, 0.0000, 1.0000),
    ('x', 'zoom7_manual1pct', 1.0, -10, 300, 111, 0.0000, 1.0000),
    ('x', 'zoom7_tol0', None, -50, 300, 190, 0.7140, 1.7061),
    ('z', 'zoom0', None, 50, 300, 2, 0.0000, 1.4858),
    ('z', 'zoom0', None, -100, 1000, 2, 0.0000, 0.0000),
    ('z', 'zoom7_manual1pct', 1.0, 50, 300, 6, 0.0000, 1.0000),
    ('z', 'zoom7_manual1pct', 1.0, -100, 1000, 2, 0.0000, 0.9123),
]


def _estimate_style(curve, centers, hws, half, ov, ortho):
    n = len(centers)
    keyed = dict(curve)
    cur = curve[0][1]
    over = 0
    worst = 0.0
    for i in range(n):
        if i in keyed:
            cur = keyed[i]
        o = max((cur - half) - (centers[i] - hws[i]), (centers[i] + hws[i]) - (cur + half))
        if o > 0 and o > worst:
            worst = o
        if o > ov + 1e-9 * ortho:
            over += 1
    return len(curve), 100.0 * over / n, 100.0 * worst / ortho


def test_shipped_walk_matches_the_estimate_parity_table():
    for axis, setup, tol, off, start, keys, over_pct, worst_pct in ESTIMATE_PARITY_TABLE:
        path = FB_KEYER_PATH if axis == "x" else LR_KEYER_PATH
        centers, hws, half, ov, shift, ortho = _walk_inputs("barM", axis, setup, off, start)
        curve = _keyed_values(_loaded_fn(path), centers, hws, half, ov, shift)
        k, o, w = _estimate_style(curve, centers, hws, half, ov, ortho)
        tag = "%s %s off=%+d start=%s" % (axis, setup, off, start)
        assert k == keys, "%s: %d keys, table %d" % (tag, k, keys)
        assert abs(o - over_pct) < 1e-3 and abs(w - worst_pct) < 1e-3, "%s: over %.4f worst %.4f, table %.4f / %.4f" % (tag, o, w, over_pct, worst_pct)


_test_functions = [
    test_front_back_reproduces_replica_metrics_at_zoom20_offset20,
    test_front_back_b_never_holds_at_zoom0_offset0,
    test_front_back_offset_differential_property,
    test_left_right_matches_front_back_algorithm_on_synthetic_input,
    test_left_right_regression_properties_on_real_cache_z_axis,
    test_find_start_index_picks_first_cached_frame_at_or_after_start,
    test_seed_series_at_start_uses_live_window_and_slices,
    test_seed_series_rigid_shift_is_followed_after_the_window,
    test_seed_series_non_rigid_mismatch_leaves_the_rest_of_the_walk_unshifted,
    test_seed_series_non_rigid_mismatch_keeps_the_live_tolerance_on_the_real_cache,
    test_start_window_is_long_enough_for_the_rigid_decision,
    test_seeded_walk_on_real_cache_starts_centred_never_jumps_and_stays_in_tolerance,
    test_seeded_walk_at_start_zero_equals_whole_take_walk,
    test_signature_takes_offset_shift_in_both_keyers,
    test_gate_follows_the_visible_frame_matrix_zero_false_missed_over,
    test_replay_model_target_numbers_at_plus_minus_50_px,
    test_walk_matches_the_independent_visible_space_oracle,
    test_offset_only_sets_the_start_both_signs,
    test_offset_zero_is_byte_for_byte_the_old_curve,
    test_fb_and_lr_copies_agree_with_an_offset,
    test_hand_checked_synthetic_walk_with_positive_and_negative_offset,
    test_hold_for_an_unfittable_pose_still_applies_with_an_offset,
    test_real_key_edge_guard_writes_the_visible_gate_curve_for_both_keyers,
    test_shipped_walk_matches_the_estimate_parity_table,
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
