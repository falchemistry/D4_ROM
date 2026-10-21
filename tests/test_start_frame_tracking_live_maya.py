r"""
Live-Maya regression test for the capture START-FRAME tracking (T72, Option B).

What it guards (all measured on a real running Maya, never mocked):
  1. Centre: a capture that starts at frame R is centred on the character at
     R AND at R+1 (the old "notch" override left the camera 8-11% of the
     frame width off at R+1 because the guard walk was seeded at frame 0).
  2. Tolerance: the number of frames outside the drift tolerance over R..end
     stays 0 at every tested start frame (the guard itself is unchanged).
  3. Keys: the horizontal channel is keyed only from R to the end (no notch
     keys), exactly the keys an independent re-implementation of the walk
     seeded at R predicts; frames before R hold R's position.
  4. Live nudge: an X offset nudge (Front/Back translateX, Left/Right
     translateZ) and a Y nudge survive scrubbing away and back with the
     frame gate ON (keyed channel) and OFF (static channel).
  5. Typed offset: a typed +50 px X offset is still ~50 px at R and R+1.
  6. Start frame 0: same keys as the independent oracle (no extra notch
     keys); optionally compared to a golden recording from the old code.
  7. The real maya_clean_reset.py leaves no d4_rom nodes.
  9. Visible gate (T72 item 6): with a typed Offset of either sign and at zoom 0 / zoom 7 (Tolerance
     widened), the keys are the edge-guard walk in the frame the artist SEES (the Offset only sets the
     start; it may fade after a nudge), no false/missed key, no frame outside the visible gate.
  8. Live-vs-cache mismatch (defect D1): on a scene whose live character differs from
     its cache non-uniformly (rogM: some frames the live bbox is narrower than the cached
     one) the centre at R+1 is under 1% AND no live-sampled frame leaves the tolerance
     (the one-frame seed shift used to break this). Skipped when that scene file is
     missing (CFG key mismatch_scene, default the rogM ROM scene); it runs LAST because
     it opens that scene.

How to run (a Maya with its command port open, the barM ROM scene open --
any scene whose animation reference has a cache in d4_anim_sample works):
send this file with the bridge (send_to_maya.ps1 / send_and_wait.ps1,
-Marker ALL_STEPS_DONE). Optional configuration: put a dict named CFG in the
namespace the file is exec'd in (keys: scripts_dir, scratch_dir,
result_path, cases (list of case names), golden_dir, golden_mode
'record' or 'compare'). Defaults: the repo's scripts\maya folder, a scratch
folder under the system temp dir.

SAFETY: the product scripts are COPIED into the scratch folder with their
CACHE_DIR (and the maya_debug.txt path) repointed at a scratch copy of the
state folder, so the real d4_anim_sample state files the launcher reads are
never written. No real mouse, no OBS, no focus changes: the camera panels
open as they always do (borderless windows), nothing else.

The bridge runs every payload twice: the main routine is skipped when the
result file already carries ALL_STEPS_DONE. Every case writes a START line
and ONE flushed PASS/FAIL line, so a hang names the culprit case.
Code and comments are ASCII only on purpose.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import traceback
import maya.cmds as cmds

CFG = globals().get('CFG') or {}
TEST_FILE = sys._getframe().f_code.co_filename
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(TEST_FILE)))
SCRIPTS_DIR = CFG.get('scripts_dir') or os.path.join(REPO_ROOT, 'scripts', 'maya')
SCRATCH = CFG.get('scratch_dir') or os.path.join(tempfile.gettempdir(), 'd4_rom_start_frame_test')
RESULT = CFG.get('result_path') or os.path.join(SCRATCH, 'result.txt')
CASES = CFG.get('cases')
GOLDEN_DIR = CFG.get('golden_dir')
GOLDEN_MODE = CFG.get('golden_mode')
MISMATCH_SCENE = CFG.get('mismatch_scene', 'D:/__temp/rogM_stor285_WIP_ROM.ma')
SRC_STATE_DIR = os.path.join(REPO_ROOT, 'd4_anim_sample')
STATE = os.path.join(SCRATCH, 'state')
COPIES = os.path.join(SCRATCH, 'scripts_copy')

PRODUCT_SCRIPTS = ['maya_camera_panels.py', 'maya_camera_panels_LR.py', 'maya_key_from_cache.py',
                   'maya_key_from_cache_LR.py', 'maya_camera_live_nudge.py', 'maya_camera_live_zoom.py',
                   'maya_clean_reset.py']
CACHE_DIR_LINE = "CACHE_DIR = os.path.join(SCRIPT_DIR, '..', '..', 'd4_anim_sample')"
DEBUG_OPEN = "open(r'D:" + chr(92) + "__backup" + chr(92) + "claude" + chr(92) + "maya_debug.txt', 'w')"

_tally = {'pass': 0, 'fail': 0}
_last = {'d': 0.0}


def log(line):
    os.makedirs(os.path.dirname(RESULT), exist_ok=True)
    with open(RESULT, 'a') as f:
        f.write('%s %s\n' % (time.strftime('%H:%M:%S'), line))
        f.flush()
        try:
            os.fsync(f.fileno())
        except Exception:
            pass


def already_done():
    try:
        return os.path.exists(RESULT) and 'ALL_STEPS_DONE' in open(RESULT).read()
    except Exception:
        return False


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        h.update(f.read())
    return h.hexdigest()


def sc(name):
    return os.path.join(COPIES, name)


def run_script(path):
    exec(compile(open(path).read(), path, 'exec'), {})


def wstate(name, text):
    with open(os.path.join(STATE, name), 'w') as f:
        f.write(text)


def set_state(gate, R, off_x=0.0, off_y=0.0, zoom=0.0, tol=''):
    wstate('_camera_frame_gate.txt', '1' if gate else '0')
    wstate('_camera_recenter_start_frame.txt', '' if R is None else str(int(R)))
    wstate('_camera_offset_px.txt', '%s,%s' % (off_x, off_y))
    wstate('_camera_zoom_pct.txt', str(zoom))
    wstate('_camera_zoom_pct_override.txt', '')
    wstate('_camera_tolerance_pct.txt', tol)
    wstate('_camera_nudge_delta.txt', '0,0')


def prepare_scratch():
    """Copies the state folder and the product scripts (CACHE_DIR repointed)."""
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(COPIES, exist_ok=True)
    for n in os.listdir(SRC_STATE_DIR):
        src = os.path.join(SRC_STATE_DIR, n)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(STATE, n))
    state_fwd = STATE.replace(chr(92), '/')
    for n in PRODUCT_SCRIPTS:
        text = open(os.path.join(SCRIPTS_DIR, n), encoding='utf-8', newline='').read()
        out = text.replace(CACHE_DIR_LINE, "CACHE_DIR = r'%s'  # TEST REPOINT" % state_fwd)
        out = out.replace(DEBUG_OPEN, "open(r'%s/maya_debug.txt', 'w')" % state_fwd)
        if n != 'maya_clean_reset.py' and out == text:
            raise RuntimeError('could not repoint CACHE_DIR in %s (product line changed?)' % n)
        if DEBUG_OPEN in out:
            raise RuntimeError('debug path not repointed in %s' % n)
        with open(os.path.join(COPIES, n), 'w', encoding='utf-8', newline='') as f:
            f.write(out)


def anim_cache_path():
    refs = cmds.file(query=True, reference=True) or []
    anim = [r for r in refs if 'anim' in os.path.basename(r).lower()]
    ref = anim[0] if anim else refs[0]
    digest = hashlib.sha1(ref.encode('utf-8')).hexdigest()[:12]
    return os.path.join(STATE, '%s__%s.json' % (os.path.splitext(os.path.basename(ref))[0], digest))


def load_cache():
    with open(anim_cache_path()) as f:
        return json.load(f)


# ---------------------------------------------------------------- measuring
def subject_bbox():
    cmds.select(clear=True)
    shapes = cmds.ls(type='mesh', noIntermediate=True, visible=True, long=True) or []
    tr = cmds.listRelatives(shapes, parent=True, fullPath=True) or []
    sel = list(set(t for t in tr if 'proxy' not in t.lower()))
    return cmds.exactWorldBoundingBox(sel)


def subj_center(axis):
    bb = subject_bbox()
    if axis == 'x':
        return (bb[0] + bb[3]) / 2.0, bb[3] - bb[0]
    return (bb[2] + bb[5]) / 2.0, bb[5] - bb[2]


def chain(cam):
    lp = cmds.ls(cam, long=True)[0]
    parts = [p for p in lp.split('|') if p]
    return ['|' + '|'.join(parts[:i + 1]) for i in range(len(parts))]


def wpos(cam, axis, f=None):
    """World horizontal camera position: translate summed along the parent chain."""
    letter = axis.upper()
    tot = 0.0
    for n in chain(cam):
        a = n + '.translate' + letter
        tot += cmds.getAttr(a, time=f) if f is not None else cmds.getAttr(a)
    return tot


def ortho_of(cam):
    shape = cmds.listRelatives(cam, shapes=True)[0]
    return cmds.getAttr(shape + '.orthographicWidth')


def wpp_value():
    return float(open(os.path.join(STATE, '_camera_world_per_px.txt')).read().strip())


def eff_tol():
    try:
        return float(open(os.path.join(STATE, '_camera_effective_overflow_pct.txt')).read().strip())
    except Exception:
        return 0.02


def err_at(cam, axis, frame):
    """(world error, px error, % of ortho): live bbox centre minus camera centre."""
    cmds.currentTime(frame)
    c, _w = subj_center(axis)
    p = wpos(cam, axis)
    e = c - p
    return e, e / wpp_value(), 100.0 * e / ortho_of(cam)


def key_list(cam, axis):
    attr = cam + '.translate' + axis.upper()
    t = cmds.keyframe(attr, q=True, timeChange=True) or []
    v = cmds.keyframe(attr, q=True, valueChange=True) or []
    return list(zip(t, v))


def take_over_tolerance(cam, axis, R):
    """Frames R..end whose subject edge passes the allowed tolerance, camera sampled per
    frame against the cache (scaled like the keyer). Returns (over, n, worst_pct_ortho)."""
    cache = load_cache()
    frames = cache['frames']
    xc = cache[axis + '_center']
    xw = cache[axis + '_width']
    cmds.currentTime(frames[0])
    cur_ref, w_live = subj_center(axis)
    scale = w_live / xw[0] if xw[0] else 1.0
    ortho = ortho_of(cam)
    half = ortho / 2.0
    tol = eff_tol() * ortho
    over = 0
    n = 0
    worst = 0.0
    for i, f in enumerate(frames):
        if f < R:
            continue
        p = wpos(cam, axis, f)
        c = cur_ref + (xc[i] - xc[0]) * scale
        hw = xw[i] * scale / 2.0
        ov = max(0.0, (p - half) - (c - hw), (c + hw) - (p + half))
        if ov > tol + 1e-5:
            over += 1
        worst = max(worst, ov)
        n += 1
    return over, n, 100.0 * worst / ortho


def oracle_keys(axis, R, off_x_px, cam):
    """Independent re-implementation of the spec: edge-guard walk seeded at the first
    cached frame >= R from the LIVE centre at R minus the Offset (T72 item 6: the gate follows the
    frame the artist sees), [B] hold.
    D1 fix: the live bbox (centre and width) of every frame from R to R+30 REPLACES the cached
    values for those frames, and the cached series after them is shifted by the live-minus-cache
    median only when that difference is a consistent (rigid) shift: at least 5 samples, the median
    at least 2% of the live width, every sample within 25% of the median from it. Otherwise the
    cached series after the window stays unshifted. R None means seed at the first cached frame
    (today's behaviour)."""
    cache = load_cache()
    frames = cache['frames']
    xc = cache[axis + '_center']
    xw = cache[axis + '_width']
    cmds.currentTime(frames[0])
    cur_ref, w_live = subj_center(axis)
    scale = w_live / xw[0] if xw[0] else 1.0
    sc_ = [cur_ref + (c - xc[0]) * scale for c in xc]
    hw = [w * scale / 2.0 for w in xw]
    idx = 0
    if R is not None:
        idx = len(frames) - 1
        for i, f in enumerate(frames):
            if f >= R:
                idx = i
                break
    n = len(frames)
    cs = list(sc_[idx:])
    hs = list(hw[idx:])
    d = 0.0
    _last['mis'] = 0.0
    if idx > 0:
        samples = []
        for i in range(idx, min(n, idx + 31)):
            cmds.currentTime(frames[i])
            samples.append(subj_center(axis))
        diffs = [samples[j][0] - cs[j] for j in range(len(samples))]
        _last['mis'] = diffs[0]
        if len(samples) >= 5:
            srt = sorted(diffs)
            m = len(srt) // 2
            med = srt[m] if len(srt) % 2 else (srt[m - 1] + srt[m]) / 2.0
            spread = max(abs(x - med) for x in diffs)
            if abs(med) >= 0.02 * samples[0][1] and spread <= 0.25 * abs(med):
                d = med
        cs = [c + d for c in cs]
        for j in range(len(samples)):
            cs[j] = samples[j][0]
            hs[j] = samples[j][1] / 2.0
    _last['d'] = d
    _last['series'] = (idx, list(cs), list(hs))
    ortho = ortho_of(cam)
    half = ortho / 2.0
    ovf = eff_tol() * ortho
    shift = off_x_px * wpp_value()
    # T72 item 6: the walk runs in the VISIBLE frame -- it starts at the centre minus the Offset
    # and every decision compares the pose with that camera; the written value is the walk value.
    cam_pos = cs[0] - shift
    out = [(frames[idx], cam_pos)]
    last = 0
    m_ = len(cs)
    for i in range(1, m_):
        if hs[i] > half + ovf:
            continue
        left, right = cs[i] - hs[i], cs[i] + hs[i]
        al, ar = cam_pos - half - ovf, cam_pos + half + ovf
        if left < al:
            cam_pos += left - al
        elif right > ar:
            cam_pos += right - ar
        else:
            continue
        out.append((frames[idx + i], cam_pos))
        last = i
    if last != m_ - 1:
        out.append((frames[n - 1], cam_pos))
    return out


def flow(gate, R, off_x=0.0, zoom=0.0, lr=False, tol=''):
    """Real clean reset -> state -> panels -> keyer: what Preview does."""
    run_script(sc('maya_clean_reset.py'))
    set_state(gate, R, off_x, 0.0, zoom, tol)
    run_script(sc('maya_camera_panels_LR.py' if lr else 'maya_camera_panels.py'))
    run_script(sc('maya_key_from_cache_LR.py' if lr else 'maya_key_from_cache.py'))
    cam = 'd4_rom_right' if lr else 'd4_rom_front'
    axis = 'z' if lr else 'x'
    if not cmds.objExists(cam):
        raise RuntimeError('camera %s missing after flow' % cam)
    return cam, axis


def sub(name, ok, detail):
    return (name, bool(ok), detail)


# -------------------------------------------------------------------- cases
def case_sweep(lr, R):
    cam, axis = flow(True, R, lr=lr)
    res = []
    e0 = err_at(cam, axis, R)
    e1 = err_at(cam, axis, R + 1)
    e2 = err_at(cam, axis, R + 2)
    ortho = ortho_of(cam)
    jump = 100.0 * abs(wpos(cam, axis, R + 1) - wpos(cam, axis, R)) / ortho
    # Front/Back: the next-frame centre error itself must stay under 1% (success
    # criterion 1, measured on barM). Left/Right: the subject can legitimately move
    # many px per frame while the guard camera holds (barM z moves 13.5 px/frame at
    # frame 1000 = natural drift), so only the camera CONTINUITY is asserted there.
    ok1 = abs(e0[2]) < 0.5 and jump < 1.0 and (lr or abs(e1[2]) < 1.0)
    res.append(sub('C1_centre_next_frame', ok1,
                   'err%%ortho R=%.2f R+1=%.2f R+2=%.2f (px R+1=%.1f); camera jump R->R+1 %.2f%% ortho; need |R|<0.5, jump<1.0%s' % (
                       e0[2], e1[2], e2[2], e1[1], jump, '' if lr else ', |R+1|<1.0')))
    over, n, worst = take_over_tolerance(cam, axis, R)
    res.append(sub('C2_tolerance_frames_over', over == 0,
                   'frames over tolerance %d of %d (worst overflow %.2f%% ortho) need 0' % (over, n, worst)))
    keys = key_list(cam, axis)
    first = min(k[0] for k in keys) if keys else None
    v_before = cmds.getAttr(cam + '.translate' + axis.upper(), time=0) if R > 0 else None
    v_at_r = cmds.getAttr(cam + '.translate' + axis.upper(), time=R)
    ok_keys = bool(keys) and first >= R - 1e-6 and (v_before is None or abs(v_before - v_at_r) < 1e-6)
    res.append(sub('C8_keys_only_from_R', ok_keys,
                   'keys=%d first_key_frame=%s need >=%d; value@0=%s value@R=%.4f (must hold)' % (len(keys), first, R, v_before, v_at_r)))
    exp = oracle_keys(axis, R, 0.0, cam)
    wpp = wpp_value()
    ok_o, why = compare_keys(keys, exp, 0.25 * wpp)
    res.append(sub('C3_keys_match_oracle', ok_o, why))
    return res


def compare_keys(got, exp, tol_world):
    gd = dict((round(t, 3), v) for t, v in got)
    ed = dict((round(t, 3), v) for t, v in exp)
    extra = sorted(set(gd) - set(ed))
    missing = sorted(set(ed) - set(gd))
    worst = 0.0
    for t in ed:
        if t in gd:
            worst = max(worst, abs(gd[t] - ed[t]))
    ok = not extra and not missing and worst <= tol_world
    return ok, 'keys got=%d expected=%d extra=%s missing=%d max_value_diff=%.4f world (tol %.4f); rigid shift applied d=%.5f' % (
        len(gd), len(ed), extra[:4], len(missing), worst, tol_world, _last['d'])


def case_live_shift():
    """The cache never matches the live character exactly in real use (different
    character size, pose offsets). Simulate a live-vs-cache difference that only
    exists from the start frame on: a temporary translateX ramp on the scene's ROOT
    group (0 at frame 0, 40 at R, then flat). The walk must be seeded from the LIVE
    centre at R, so the camera is still centred at R and R+1 (needs the live shift d).
    The ramp is removed again afterwards."""
    R = 300
    root = '|ROOT'
    if not cmds.objExists(root):
        return [sub('C1_live_shift_seed', False, 'no |ROOT group in this scene to ramp')]
    attr = root + '.translateX'
    try:
        cmds.setKeyframe(attr, time=0, value=0.0)
        cmds.setKeyframe(attr, time=R, value=40.0)
        cmds.keyTangent(attr, inTangentType='linear', outTangentType='linear')
        cam, axis = flow(True, R)
        e0 = err_at(cam, axis, R)
        e1 = err_at(cam, axis, R + 1)
        keys = key_list(cam, axis)
        exp = oracle_keys(axis, R, 0.0, cam)
        ok_o, why = compare_keys(keys, exp, 0.25 * wpp_value())
        mis = _last['mis']
        ok1 = abs(e0[2]) < 0.5 and abs(e1[2]) < 1.5 and abs(mis) > 0.5
        return [sub('C1_live_shift_seed', ok1, 'err%%ortho R=%.2f R+1=%.2f (need |R|<0.5, |R+1|<1.5); live-vs-cache mismatch at R %.3f world (must be non-zero, else the ramp did nothing); rigid shift applied to the rest of the walk d=%.3f' % (e0[2], e1[2], mis, _last['d'])),
                sub('C3_live_shift_keys_match_oracle', ok_o, why)]
    finally:
        try:
            cmds.cutKey(attr, clear=True)
            cmds.setAttr(attr, 0.0)
        except Exception:
            pass


def live_take_over_tolerance(cam, axis, R, stride=5):
    """Ground truth for the D1 defect: frames R..end (every `stride`-th cached frame) whose LIVE
    subject bbox edge passes the allowed tolerance of the camera at that frame. Unlike
    take_over_tolerance (which re-derives the subject from the cache and so cannot see a cache that
    differs from the live scene) this measures the real character. Poses that cannot fit even
    with the full tolerance are skipped (the keyer holds on them by design [B]).
    Returns (over, n, unfit, worst_pct_ortho)."""
    cache = load_cache()
    ortho = ortho_of(cam)
    half = ortho / 2.0
    tol = eff_tol() * ortho
    over = n = unfit = 0
    worst = 0.0
    for k, f in enumerate([f for f in cache['frames'] if f >= R]):
        if k % stride:
            continue
        cmds.currentTime(f)
        c, w = subj_center(axis)
        p = wpos(cam, axis)
        hw = w / 2.0
        n += 1
        if hw > half + tol:
            unfit += 1
            continue
        ov = max(0.0, (p - half) - (c - hw), (c + hw) - (p + half))
        worst = max(worst, ov)
        if ov > tol + 1e-5:
            over += 1
    return over, n, unfit, 100.0 * worst / ortho


def ensure_mismatch_scene():
    """Opens the scene whose live character differs from its cache at some frames (T72 defect D1,
    found by the independent QA on rogM: live bbox narrower than the cached one, centre off by up to
    9 world units). Returns None when the scene is not available (the cases then SKIP)."""
    path = MISMATCH_SCENE
    if not path or not os.path.exists(path):
        return None
    cur = (cmds.file(q=True, sceneName=True) or '').replace(chr(92), '/')
    if cur.lower() != path.replace(chr(92), '/').lower():
        cmds.file(path, o=True, f=True, ignoreVersion=True, prompt=False)
        prepare_scratch()
    return path


def case_live_mismatch(R):
    """D1 regression. On a scene whose live character differs from its cache NON-uniformly, the
    centre must still be right at R+1 (criterion 1: next-frame error under 1% of the ortho width)
    AND no sampled frame may leave the allowed tolerance (criterion 2: 0 over, as the old code).
    Shifting the whole cached walk by the one-frame live-minus-cache difference broke criterion 2:
    10 / 9 / 15 / 8 sampled frames over at R = 200 / 1400 / 1500 / 1600 (worst 5.4% of the width)."""
    if not ensure_mismatch_scene():
        return [sub('SKIP_scene_missing', True, 'SKIP: mismatch scene %s not found on this machine' % MISMATCH_SCENE)]
    cam, axis = flow(True, R)
    e0 = err_at(cam, axis, R)
    e1 = err_at(cam, axis, R + 1)
    over, n, unfit, worst = live_take_over_tolerance(cam, axis, R)
    keys = key_list(cam, axis)
    return [
        sub('C1_mismatch_next_frame_centre', abs(e0[2]) < 0.5 and abs(e1[2]) < 1.0,
            'err%%ortho R=%.2f R+1=%.2f (need |R|<0.5 and |R+1|<1.0); keys=%d' % (e0[2], e1[2], len(keys))),
        sub('C2_mismatch_live_frames_over_tolerance', over == 0,
            'live-sampled frames over tolerance %d of %d (unfit skipped %d, worst overflow %.2f%% ortho) need 0' % (over, n, unfit, worst)),
    ]


def case_offset50():
    R = 300
    cam, axis = flow(True, R, off_x=50.0)
    e0 = err_at(cam, axis, R)
    e1 = err_at(cam, axis, R + 1)
    ok = abs(e0[1] - 50.0) <= 1.0 and abs(e1[1] - 50.0) <= 3.0
    return [sub('C4_typed_offset_kept', ok, 'px error R=%.1f R+1=%.1f need ~50 (+-1 at R, +-3 at R+1)' % (e0[1], e1[1]))]


def keyed_gate_metrics(cam, axis, R):
    """T72 item 6. Replays the written keys against the character (the series the keyer walked:
    cache poses scaled like the keyer, the live window and the rigid shift of oracle_keys, which
    must have run just before) from the first cached frame >= R, with the gate = the VISIBLE frame edge +/- tolerance of
    the camera as it is held between keys. false = a key was written while the pose was still inside
    the gate of the held camera; missed = a pose that fits was outside that gate and no key was
    written; over = a pose that fits is outside the gate of the camera Maya really evaluates at
    that frame (sampled, interpolation included). Frames after the first measured one only."""
    cache = load_cache()
    frames = cache['frames']
    idx, cs, hs = _last['series']
    ortho = ortho_of(cam)
    half = ortho / 2.0
    ov = eff_tol() * ortho
    eps = 1e-5
    attr = cam + '.translate' + axis.upper()
    kd = dict((round(t, 3), v) for t, v in key_list(cam, axis))
    base = wpos(cam, axis, frames[idx]) - cmds.getAttr(attr, time=frames[idx])
    cur = kd.get(round(frames[idx], 3), cmds.getAttr(attr, time=frames[idx])) + base
    false = missed = over = keys = 0
    for i in range(idx + 1, len(frames)):
        f = frames[i]
        c = cs[i - idx]
        hw = hs[i - idx]
        fits = hw <= half + ov
        outside = (c - hw) < cur - half - ov - eps or (c + hw) > cur + half + ov + eps
        k = kd.get(round(f, 3))
        if k is not None and abs(k + base - cur) > 1e-9:
            keys += 1
            if not outside:
                false += 1
            cur = k + base
        elif fits and outside:
            missed += 1
        if fits:
            p = wpos(cam, axis, f)
            if (c - hw) < p - half - ov - eps or (c + hw) > p + half + ov + eps:
                over += 1
    return false, missed, over, keys


def case_visible_gate(lr, R, off, zoom, tol):
    """T72 item 6 end to end on the real keyer: with a typed Offset (both signs) and the zoom the
    artist uses (zoom 7 with the Tolerance widened), the written keys are exactly the walk in the
    visible frame (oracle), no key is false or missed, no frame leaves the visible gate, and the
    camera starts one Offset away from the character at the start frame."""
    cam, axis = flow(True, R, off_x=off, zoom=zoom, lr=lr, tol=tol)
    keys = key_list(cam, axis)
    exp = oracle_keys(axis, R, off, cam)
    ok_o, why = compare_keys(keys, exp, 0.25 * wpp_value())
    false, missed, over, nk = keyed_gate_metrics(cam, axis, R)
    e0 = err_at(cam, axis, R)
    tag = ('LR' if lr else 'FB') + '_R%d_off%d_zoom%d' % (R, int(off), int(zoom))
    extra = []
    if not lr:
        lo, ln, lu, lw = live_take_over_tolerance(cam, axis, R + 1)
        extra = [sub('C12_live_bbox_inside_visible_gate_%s' % tag, lo == 0,
                     'LIVE bbox sampled every 5th frame: %d of %d over the visible gate (unfit skipped %d, worst %.2f%% ortho) need 0' % (lo, ln, lu, lw))]
    return extra + [
        sub('C9_keys_match_visible_oracle_%s' % tag, ok_o, why),
        sub('C10_no_false_missed_over_%s' % tag, false == 0 and missed == 0 and over == 0,
            'false=%d missed=%d over=%d (keys after the first: %d; tolerance %.4f of the frame) need 0/0/0' % (false, missed, over, nk, eff_tol())),
        sub('C11_start_is_one_offset_from_centre_%s' % tag, abs(e0[1] - off) <= 1.0,
            'px error at R %.2f need %+.0f (+-1)' % (e0[1], off)),
    ]


def case_nudge(lr, gate, R=300, dx=100.0, dy=40.0):
    cam, axis = flow(gate, R, lr=lr)
    wpp = wpp_value()
    pts = (R, R + 10, R + 100, R + 500)
    before = dict((f, wpos(cam, axis, f)) for f in pts)
    yb = dict((f, cmds.getAttr(cam + '.translateY', time=f)) for f in pts)
    h_keys = len(key_list(cam, axis))
    cmds.currentTime(R)
    wstate('_camera_nudge_delta.txt', '%s,%s' % (dx, dy))
    run_script(sc('maya_camera_live_nudge.py'))
    cmds.currentTime(R + 10)
    cmds.currentTime(R + 500)
    cmds.currentTime(R)
    now_r = wpos(cam, axis)
    after = dict((f, wpos(cam, axis, f)) for f in pts)
    ya = dict((f, cmds.getAttr(cam + '.translateY', time=f)) for f in pts)
    exp = -dx * wpp
    expy = -dy * wpp
    sh = dict((f, after[f] - before[f]) for f in pts)
    shy = dict((f, ya[f] - yb[f]) for f in pts)
    tolh = 1e-4 * max(1.0, abs(exp))
    ok_h = abs(now_r - before[R] - exp) < tolh and all(abs(sh[f] - exp) < tolh for f in pts)
    ok_y = all(abs(shy[f] - expy) < 1e-4 * max(1.0, abs(expy)) for f in pts)
    nm = ('LR' if lr else 'FB') + ('_gateON' if gate else '_gateOFF')
    return [
        sub('C3_nudge_X_sticks_%s' % nm, ok_h,
            'h_keys=%d expected shift %.4f; after scrub at R(current time)=%.4f, per-frame %s' % (
                h_keys, exp, now_r - before[R], ', '.join('f%d=%.4f' % (f, sh[f]) for f in pts))),
        sub('C3_nudge_Y_sticks_%s' % nm, ok_y,
            'expected shift %.4f; %s' % (expy, ', '.join('f%d=%.4f' % (f, shy[f]) for f in pts))),
    ]


def sample_all(cam, axis):
    cache = load_cache()
    return [wpos(cam, axis, f) for f in cache['frames']]


def case_identity(lr, off_x):
    cam, axis = flow(True, 0, off_x=off_x, lr=lr)
    keys = key_list(cam, axis)
    exp = oracle_keys(axis, 0, off_x, cam)
    ok, why = compare_keys(keys, exp, 0.25 * wpp_value())
    nm = ('LR' if lr else 'FB') + '_off%d' % int(off_x)
    res = [sub('C5_R0_keys_match_oracle_%s' % nm, ok, why)]
    if GOLDEN_MODE and GOLDEN_DIR and off_x != 0:
        res.append(sub('C5_R0_golden_skipped_%s' % nm, True, 'SKIP: a non-zero Offset is no longer compared with the old code (T72 item 6 changes the gate on purpose)'))
    elif GOLDEN_MODE and GOLDEN_DIR:
        os.makedirs(GOLDEN_DIR, exist_ok=True)
        gp = os.path.join(GOLDEN_DIR, 'golden_%s.json' % nm)
        samples = sample_all(cam, axis)
        wpp = wpp_value()
        if GOLDEN_MODE == 'record':
            json.dump({'samples': samples, 'wpp': wpp, 'keys': keys}, open(gp, 'w'))
            res.append(sub('C5_R0_golden_recorded_%s' % nm, True, 'recorded %d samples, %d keys' % (len(samples), len(keys))))
        else:
            g = json.load(open(gp))
            worst = max(abs(a - b) for a, b in zip(samples, g['samples']))
            cmn = dict((round(t, 3), v) for t, v in g['keys'])
            kd = max([abs(v - cmn[round(t, 3)]) for t, v in keys if round(t, 3) in cmn] or [0.0])
            res.append(sub('C5_R0_vs_old_code_%s' % nm, worst <= 0.25 * wpp and kd < 1e-6,
                           'max sampled diff %.4f world = %.3f px (need <= 0.25 px); common-key value diff %.2e' % (worst, worst / wpp, kd)))
    return res


def case_clean_reset():
    flow(True, 300)
    flow(True, 300, lr=True)
    run_script(sc('maya_clean_reset.py'))
    left = cmds.ls('*d4_rom*') or []
    return [sub('C6_clean_reset_leaves_no_d4_rom_nodes', not left, 'remaining d4_rom nodes: %s' % left[:8])]


def run_case(name, fn):
    if CASES is not None and name not in CASES:
        return
    log('START %s' % name)
    t0 = time.time()
    try:
        results = fn()
    except Exception:
        _tally['fail'] += 1
        log('ERROR %s %s' % (name, traceback.format_exc().replace('\n', ' | ')))
        return
    for sname, ok, detail in results:
        _tally['pass' if ok else 'fail'] += 1
        log('%s %s/%s (%.1fs) %s' % ('PASS' if ok else 'FAIL', name, sname, time.time() - t0, detail))


def main():
    log('START_RUN scripts_dir=%s scratch=%s' % (SCRIPTS_DIR, SCRATCH))
    original_time = cmds.currentTime(query=True)
    try:
        prepare_scratch()
        digests = dict((n, sha256_of(os.path.join(SCRIPTS_DIR, n))[:12]) for n in PRODUCT_SCRIPTS)
        log('INFO product script sha256 prefixes %s' % digests)
        log('INFO scene=%s cache=%s' % (cmds.file(q=True, sceneName=True), os.path.basename(anim_cache_path())))
        for R in (150, 300, 600, 1000, 2000):
            run_case('sweep_fb_R%d' % R, lambda R=R: case_sweep(False, R))
        run_case('offset50_fb_R300', case_offset50)
        # T72 item 6: the gate follows the visible frame. zoom 0 (auto tolerance) and zoom 7 with the
        # Tolerance box widened to 1%, both signs, Offset 10/50/100 px, start frames 300 and 1000.
        for lr in (False, True):
            for R in (300, 1000):
                for zoom, tol in ((0.0, ''), (7.0, '1')):
                    for off in (10.0, -10.0, 50.0, -50.0, 100.0, -100.0):
                        nm = 'gate_%s_R%d_z%d_off%d' % ('lr' if lr else 'fb', R, int(zoom), int(off))
                        run_case(nm, lambda lr=lr, R=R, zoom=zoom, tol=tol, off=off: case_visible_gate(lr, R, off, zoom, tol))
        run_case('live_shift_fb_R300', case_live_shift)
        run_case('nudge_fb_gateON_R300', lambda: case_nudge(False, True))
        run_case('nudge_fb_gateOFF_R300', lambda: case_nudge(False, False))
        run_case('nudge_lr_gateON_R300', lambda: case_nudge(True, True))
        run_case('sweep_lr_R300', lambda: case_sweep(True, 300))
        run_case('sweep_lr_R1000', lambda: case_sweep(True, 1000))
        run_case('identity_fb_R0_off0', lambda: case_identity(False, 0.0))
        run_case('identity_fb_R0_off50', lambda: case_identity(False, 50.0))
        run_case('identity_lr_R0_off0', lambda: case_identity(True, 0.0))
        run_case('clean_reset_empty', case_clean_reset)
        # Last on purpose: this opens another scene (replaces the open one in the test Maya).
        for R in (200, 1400, 1500, 1600):
            run_case('mismatch_fb_R%d' % R, lambda R=R: case_live_mismatch(R))
    except Exception:
        _tally['fail'] += 1
        log('ERROR setup/run %s' % traceback.format_exc().replace('\n', ' | '))
    try:
        run_script(sc('maya_clean_reset.py'))
    except Exception:
        log('WARN final reset failed %s' % traceback.format_exc().replace('\n', ' | '))
    try:
        cmds.currentTime(original_time)
    except Exception:
        pass
    log('SUMMARY passed=%d failed=%d' % (_tally['pass'], _tally['fail']))
    log('ALL_STEPS_DONE')


try:
    if not already_done():
        main()
except Exception:
    try:
        log('ERROR top %s' % traceback.format_exc().replace('\n', ' | '))
        log('ALL_STEPS_DONE')
    except Exception:
        pass
