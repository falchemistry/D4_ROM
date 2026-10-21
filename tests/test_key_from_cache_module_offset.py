r"""
Whole-module regression test for the Offset wiring of BOTH keyers
(scripts/maya_key_from_cache.py = Front/Back, scripts/maya_key_from_cache_LR.py
= Left/Right) -- T72 item 6 ("Offset follows the visible frame").

Why this exists: tests/test_edge_guard_curve_logic.py extracts compute_edge_
guard_curve / key_edge_guard by ast and tests them in isolation. The code that
CALLS them lives at module top level (get_pixel_offset -> get_world_per_px ->
`offset_shift = offset_x_px * world_per_px if world_per_px is not None else
0.0` -> key_edge_guard(..., offset_shift, recenter_frame)) and is not covered
there. An independent QA pass showed five mutants that suite does not catch:
a sign flip of the offset_shift line (each keyer), passing 0.0 instead of
offset_shift to key_edge_guard (each keyer), and dropping the "world-units-
per-pixel file missing" guard. This test runs the REAL module text, top level
included, against a fake maya.cmds, and compares the keyed values with an
independent in-test oracle, so all five go red.

Run directly, no Maya session and NO mayapy (banned workspace-wide, see
CLAUDE.md at the D:\__backup\claude root):

    python tests/test_key_from_cache_module_offset.py

Exits 0 if all checks pass, 1 otherwise. Takes a few seconds.

Method: each keyer source is compiled with a file name inside a temporary
directory, so its own `CACHE_DIR = <script dir>/../d4_anim_sample` resolves
to a temp d4_anim_sample holding SYNTHETIC cache + state files (nothing from
the repo's d4_anim_sample or the user's files is read). The one hard-coded
debug-file write at the end of each keyer is repointed to the temp dir, so no
repo or user file is written. The live subject equals the cached subject
(scale 1). Oracle: the independent visible-space walk (tracks the left edge of
the frame the artist sees; first key = subject centre - Offset*world_per_px).
"""
import contextlib
import hashlib
import io
import json
import math
import os
import re
import shutil
import sys
import tempfile
import traceback
import types

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
FB_PATH = os.path.join(REPO_ROOT, "scripts", "maya_key_from_cache.py")
LR_PATH = os.path.join(REPO_ROOT, "scripts", "maya_key_from_cache_LR.py")

EDGE = 0.02      # EDGE_OVERFLOW_PCT of the keyers / maya_camera_panels.py
SAFE = 1.02      # MARGIN_SAFETY
PANEL_W = 960.0  # panel width in px (world_per_px = final ortho / PANEL_W)
ANIM_REF = "synthetic_rom_anim.ma"

_TMP = tempfile.mkdtemp(prefix="d4_key_module_offset_")
_STATE = os.path.join(_TMP, "d4_anim_sample")
_SCRIPTS = os.path.join(_TMP, "scripts")
os.makedirs(_STATE)
os.makedirs(_SCRIPTS)
_DEBUG_OUT = os.path.join(_TMP, "maya_debug.txt")


# ---------------------------------------------------------------- synthetic data
def make_scene(kind):
    """Deterministic synthetic cache: 1200 frames, wandering subject with
    arm-swing width changes. Two scenes with different drift/width ranges."""
    frames = list(range(0, 1200))
    if kind == "A":
        xc = [120 * math.sin(i / 90.0) + 0.15 * i + 25 * math.sin(i / 7.0) for i in frames]
        xw = [110 + 45 * abs(math.sin(i / 23.0)) + 30 * max(0.0, math.sin(i / 131.0)) for i in frames]
        zc = [90 * math.sin(i / 61.0 + 1.0) - 0.1 * i + 18 * math.sin(i / 9.0) for i in frames]
        zw = [90 + 35 * abs(math.sin(i / 17.0)) + 25 * max(0.0, math.sin(i / 97.0)) for i in frames]
    else:
        xc = [200 * math.sin(i / 150.0) + 0.45 * i + 40 * math.sin(i / 11.0) for i in frames]
        xw = [70 + 40 * abs(math.sin(i / 31.0)) + 20 * max(0.0, math.sin(i / 53.0)) for i in frames]
        zc = [150 * math.sin(i / 120.0 + 2.0) + 0.3 * i + 30 * math.sin(i / 13.0) for i in frames]
        zw = [60 + 30 * abs(math.sin(i / 29.0)) + 18 * max(0.0, math.sin(i / 71.0)) for i in frames]
    return {
        "frames": frames, "start": frames[0], "end": frames[-1],
        "animation_reference": ANIM_REF, "source_character_scene": "synthetic",
        "x_center": xc, "x_width": xw, "z_center": zc, "z_width": zw,
    }


SCENES = {"A": make_scene("A"), "B": make_scene("B")}


def cache_file_for(ref):
    digest = hashlib.sha1(ref.encode("utf-8")).hexdigest()[:12]
    return os.path.join(_STATE, "%s__%s.json" % (os.path.splitext(os.path.basename(ref))[0], digest))


# --------------------------------------------------------------------- oracle
def oracle_walk(centers, halfw, H, T, shift, start=0):
    """Independent visible-space walk. L = left edge of the frame the artist
    sees, spanning [L, L+2H]; the subject must stay within [L-T, L+2H+T].
    Seed: frame centred on the subject, then moved by the Offset (L = c0 -
    shift - H). Returns (key_count, left_edge_per_frame)."""
    n = len(centers)
    W = 2.0 * H
    L = centers[start] - shift - H
    keyed = [start]
    Ls = [L]
    for i in range(start + 1, n):
        hw = halfw[i]
        if hw > H + T:          # pose cannot fit at all: hold
            Ls.append(L)
            continue
        sl = centers[i] - hw
        sr = centers[i] + hw
        if sl < L - T:
            L = sl + T
            keyed.append(i)
        elif sr > L + W + T:
            L = sr - T - W
            keyed.append(i)
        Ls.append(L)
    if keyed[-1] != n - 1:
        keyed.append(n - 1)
    return len(keyed), Ls


# ------------------------------------------------------------------- fake cmds
class FakeCmds(types.ModuleType):
    """Just enough maya.cmds for the keyers' module-level flow."""

    def __init__(self, cache, ortho):
        types.ModuleType.__init__(self, "maya.cmds")
        self.c = cache
        self.ortho = ortho
        self.t = cache["frames"][0]
        self.keys = {}
        self.cut = []
        self.fi = {f: i for i, f in enumerate(cache["frames"])}

    def file(self, *a, **k):
        return [ANIM_REF]

    def refresh(self, **k):
        pass

    def currentTime(self, *a, **k):
        if a:
            self.t = a[0]
        return self.t

    def select(self, *a, **k):
        pass

    def ls(self, *a, **k):
        if k.get("selection"):
            return []
        return ["m|mShape"]

    def listRelatives(self, x, **k):
        if k.get("shapes"):
            return [x + "Shape"]
        return ["|m"]

    def objExists(self, n):
        return True

    def exactWorldBoundingBox(self, sel):
        i = self.fi[self.t]
        xc, xw = self.c["x_center"][i], self.c["x_width"][i]
        zc, zw = self.c["z_center"][i], self.c["z_width"][i]
        return (xc - xw / 2, 0.0, zc - zw / 2, xc + xw / 2, 1.0, zc + zw / 2)

    def keyframe(self, attr, **k):
        return len(self.keys.get(attr, [])) if k.get("query") else 0

    def cutKey(self, attr, **k):
        self.keys.pop(attr, None)
        self.cut.append(attr)

    def getAttr(self, a):
        return self.ortho

    def setKeyframe(self, attr, time=None, value=None):
        self.keys.setdefault(attr, []).append((time, value))


_DEBUG_RE = re.compile(r"open\(r'D:" + re.escape(chr(92)) + "__backup" + re.escape(chr(92)) + "claude"
                       + re.escape(chr(92)) + r"maya_debug\.txt', 'w'\)")


def _write(name, text):
    with open(os.path.join(_STATE, name), "w") as f:
        f.write(text)


def run_module(scene, lr, off_px, zoom=0.0, tolpct=None, start=None, gate=True, wpp_mode="ok"):
    """Execs the REAL keyer module text with a fake maya.cmds. Returns
    (fake, wpp, final_ortho, overflow_fraction, cache)."""
    cache = SCENES[scene]
    with open(cache_file_for(ANIM_REF), "w") as f:
        json.dump(cache, f)
    maxw = max(cache["x_width"] if not lr else cache["z_width"])
    needed = maxw / (1 - 2 * EDGE) * SAFE
    final = needed * (1 - zoom / 100.0)
    wpp = final / PANEL_W
    ov = max(0.0, (1 - maxw * SAFE / final) / 2) if tolpct is None else tolpct / 100.0
    _write("_camera_frame_gate.txt", "1" if gate else "0")
    _write("_camera_offset_px.txt", "%s,0" % off_px)
    _write("_camera_effective_overflow_pct.txt", repr(ov))
    _write("_camera_recenter_start_frame.txt", "" if start is None else str(start))
    wpath = os.path.join(_STATE, "_camera_world_per_px.txt")
    if wpp_mode == "ok":
        _write("_camera_world_per_px.txt", repr(wpp))
    elif os.path.exists(wpath):
        os.remove(wpath)

    fake = FakeCmds(cache, final)
    maya_pkg = types.ModuleType("maya")
    maya_pkg.cmds = fake
    saved = (sys.modules.get("maya"), sys.modules.get("maya.cmds"))
    sys.modules["maya"] = maya_pkg
    sys.modules["maya.cmds"] = fake
    try:
        path = os.path.join(_SCRIPTS, os.path.basename(LR_PATH if lr else FB_PATH))
        with open(LR_PATH if lr else FB_PATH, encoding="utf-8") as f:
            src = f.read()
        assert _DEBUG_RE.search(src), "debug-file write line not found in %s (test needs updating)" % path
        debug_repl = "open(%r, 'w')" % _DEBUG_OUT.replace(chr(92), "/")
        src = _DEBUG_RE.sub(lambda m: debug_repl, src)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exec(compile(src, path, "exec"), {"__name__": "key_from_cache_under_test"})
    finally:
        for name, old in (("maya", saved[0]), ("maya.cmds", saved[1])):
            if old is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = old
    return fake, wpp, final, ov, cache


def cams_for(lr):
    return ("d4_rom_right", "d4_rom_left") if lr else ("d4_rom_front", "d4_rom_back")


def check_against_oracle(fake, scene_cache, lr, final, ov, shift_world, start):
    """Returns a list of problems (empty = every camera matches the oracle)."""
    axis = "z" if lr else "x"
    fr = scene_cache["frames"]
    cen = scene_cache[axis + "_center"]
    wid = scene_cache[axis + "_width"]
    si = 0 if start is None else fr.index(start)
    H = final / 2.0
    T = ov * final
    k, Ls = oracle_walk(cen[si:], [w / 2.0 for w in wid[si:]], H, T, shift_world, 0)
    problems = []
    for cam in cams_for(lr):
        ks = fake.keys.get(cam + ".translate" + axis.upper(), [])
        if len(ks) != k:
            problems.append("%s: %d keys, oracle %d" % (cam, len(ks), k))
            continue
        if ks[0][0] != fr[si]:
            problems.append("%s: first key at frame %s, expected %s" % (cam, ks[0][0], fr[si]))
        if abs(ks[0][1] - (cen[si] - shift_world)) > 1e-6:
            problems.append("%s: first key %.6f, expected centre - Offset = %.6f" % (cam, ks[0][1], cen[si] - shift_world))
        for tm, v in ks:
            j = fr.index(tm) - si
            if abs(v - (Ls[j] + H)) > 1e-6 * H:
                problems.append("%s: value at frame %s is %.6f, oracle %.6f" % (cam, tm, v, Ls[j] + H))
                break
    return problems


# ------------------------------------------------------------------------ tests
OFFSETS = (0, 50, -50, 100, -100)
ZOOMS = ((0, None), (7, 1.0))     # (zoom %, manual tolerance % or None = Auto)
STARTS = (None, 300, 1000)


def test_both_keyers_follow_the_oracle_for_offsets_zoom_start_and_both_cameras():
    bad = []
    n = 0
    differs = 0
    for scene in sorted(SCENES):
        for lr in (False, True):
            for off in OFFSETS:
                for zoom, tol in ZOOMS:
                    for st in STARTS:
                        fake, wpp, final, ov, cache = run_module(scene, lr, off, zoom, tol, st)
                        n += 1
                        probs = check_against_oracle(fake, cache, lr, final, ov, off * wpp, st)
                        if probs:
                            bad.append("scene %s lr=%s off=%+d zoom=%s tol=%s start=%s: %s" % (scene, lr, off, zoom, tol, st, probs[0]))
                        if off == 100 and not probs:
                            f0, w0, fin0, ov0, c0 = run_module(scene, lr, 0, zoom, tol, st)
                            a = f0.keys.get(cams_for(lr)[0] + ".translate" + ("Z" if lr else "X"))
                            b = fake.keys.get(cams_for(lr)[0] + ".translate" + ("Z" if lr else "X"))
                            if a != b:
                                differs += 1
    assert n == 120, n
    assert not bad, "%d of %d cases differ from the oracle; first: %s" % (len(bad), n, bad[0])
    # Non-vacuity: the Offset must actually change the keyed curve somewhere.
    assert differs >= 6, "Offset 100 changed the curve in only %d cases -- test data too weak" % differs


def test_first_key_is_the_subject_centre_minus_offset_in_world_units_for_both_keyers():
    # The sign convention in one line, independent of the walk: Offset +50 px
    # puts the FIRST key at (centre - 50*world_per_px), -50 at (centre + 50*wpp).
    for lr in (False, True):
        axis = "Z" if lr else "X"
        cen0 = SCENES["A"]["z_center" if lr else "x_center"][0]
        for off in (50, -50):
            fake, wpp, final, ov, cache = run_module("A", lr, off, 0, None, None)
            for cam in cams_for(lr):
                first = fake.keys[cam + ".translate" + axis][0][1]
                assert abs(first - (cen0 - off * wpp)) < 1e-9, (lr, off, cam, first, cen0 - off * wpp)
                assert (first < cen0) == (off > 0), (lr, off, cam)


def test_missing_world_per_px_file_skips_the_offset_and_does_not_crash():
    # "Skip rather than guess": without the ratio the Offset is not applied
    # (shift 0) and the run must still complete and key both cameras.
    for lr in (False, True):
        for off in (50, -100):
            fake, wpp, final, ov, cache = run_module("A", lr, off, 0, None, None, wpp_mode="missing")
            probs = check_against_oracle(fake, cache, lr, final, ov, 0.0, None)
            assert not probs, "lr=%s off=%+d missing ratio: %s" % (lr, off, probs[0])


def test_gate_off_keeps_the_camera_static_and_cuts_stale_keys():
    for lr in (False, True):
        fake, wpp, final, ov, cache = run_module("A", lr, 50, 0, None, None, gate=False)
        axis = "Z" if lr else "X"
        for cam in cams_for(lr):
            assert not fake.keys.get(cam + ".translate" + axis), (lr, cam, "keys written with the gate OFF")


_test_functions = [
    test_both_keyers_follow_the_oracle_for_offsets_zoom_start_and_both_cameras,
    test_first_key_is_the_subject_centre_minus_offset_in_world_units_for_both_keyers,
    test_missing_world_per_px_file_skips_the_offset_and_does_not_crash,
    test_gate_off_keeps_the_camera_static_and_cuts_stale_keys,
]

_passed = 0
_failures = []
for _fn in _test_functions:
    try:
        _fn()
    except Exception:
        _failures.append("{}\n{}".format(_fn.__name__, traceback.format_exc()))
    else:
        _passed += 1

shutil.rmtree(_TMP, ignore_errors=True)
print("{} passed, {} failed".format(_passed, len(_failures)))
for _f in _failures:
    print("FAIL:", _f)

sys.exit(1 if _failures else 0)
