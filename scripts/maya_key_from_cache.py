"""Fast keyframing from the cache built by maya_cache_bbox.py -- no rig
evaluation needed for the bulk of the work, just reads cached horizontal
bbox data (looked up by this scene's referenced animation file, same as
the cache script) and inserts keyframes where the (size-adjusted) center
drifts more than THRESHOLD_PCT of the frame width since the last key.

Size adjustment: the cache was built from one specific character's mesh,
so if the current scene's character is a different size, raw cached
centers would be wrong. Before applying, we do ONE cheap live measurement
of the current character's bbox at the cache's reference frame, compare
its width to the cached width at that same frame to get a scale ratio,
then project every cached center through:
    adjusted = current_center_at_ref + (cached_center - cached_center_at_ref) * scale
This assumes lateral movement scales proportionally with character size
-- reasonable for a uniform-scale size variation, approximate otherwise.

Total cost: one rig evaluation (for the reference-frame measurement) plus
a pure-Python pass over the cached samples -- still well under a second
even at every-frame resolution, vs. minutes for a full re-sample.
"""
import hashlib
import json
import os
import sys
import time
import maya.cmds as cmds

# Relative to this script's own location -- see maya_cache_bbox.py for why
# the co_filename trick is needed instead of __file__.
SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
SCRIPTS_DIR = SCRIPT_DIR
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', 'd4_anim_sample')


def find_animation_reference():
    refs = cmds.file(query=True, reference=True) or []
    anim_refs = [r for r in refs if 'anim' in os.path.basename(r).lower()]
    if anim_refs:
        return anim_refs[0]
    non_skel = [r for r in refs if 'skel' not in os.path.basename(r).lower()]
    if non_skel:
        return non_skel[0]
    if refs:
        return refs[0]
    raise RuntimeError('No file references found in this scene to key the cache off of.')


def cache_path_for(anim_ref_path):
    digest = hashlib.sha1(anim_ref_path.encode('utf-8')).hexdigest()[:12]
    safe_name = os.path.splitext(os.path.basename(anim_ref_path))[0]
    return os.path.join(CACHE_DIR, '%s__%s.json' % (safe_name, digest))


def get_target_bbox():
    sel = cmds.ls(selection=True, long=True)
    if not sel:
        shapes = cmds.ls(type='mesh', noIntermediate=True, visible=True, long=True) or []
        transforms = cmds.listRelatives(shapes, parent=True, fullPath=True) or []
        sel = list(set(t for t in transforms if 'proxy' not in t.lower()))
    if not sel:
        raise RuntimeError('Nothing to frame: select an object, or add visible geometry to the scene.')
    return cmds.exactWorldBoundingBox(sel)


def get_effective_overflow_pct():
    """Reads the zoom-adjusted drift tolerance maya_camera_panels.py wrote
    (see its compute_effective_overflow_pct) instead of trusting the
    EDGE_OVERFLOW_PCT constant below in isolation -- the magnifier changes
    how much of that constant's built-in headroom is actually left, and
    this file has no other way to know the current zoom level. Falls back
    to EDGE_OVERFLOW_PCT if the file doesn't exist yet (e.g. run standalone
    without ever having opened panels first) or is malformed."""
    path = os.path.join(CACHE_DIR, '_camera_effective_overflow_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return max(0.0, float(content))
    except (IOError, OSError, ValueError):
        return EDGE_OVERFLOW_PCT


def get_recenter_start_frame():
    """Reads the frame number rom_launcher.ps1 wrote for 'Recenter at start
    frame' (see maya_camera_panels.py's own copy of this function for the
    full explanation). Returns None (disabled) if the file is empty,
    missing, or malformed."""
    path = os.path.join(CACHE_DIR, '_camera_recenter_start_frame.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        if not content:
            return None
        return float(content)
    except (IOError, OSError, ValueError):
        return None


def get_frame_gate_enabled():
    """Reads the 'Frame gate' checkbox state rom_launcher.ps1's
    Write-FrameGateEnabled last wrote -- '1' (checked/ON, the default) or
    '0' (unchecked/OFF). Missing or malformed = ON = today's behavior
    (automatic tracking), the same "unknown defaults to the existing
    behavior" convention as get_effective_overflow_pct's own fallback --
    an OFF state must be an explicit, deliberate '0', never inferred from
    the file simply not existing yet (e.g. a launcher build that predates
    this checkbox). Only the literal '0' means OFF; any other content
    (including garbage) is treated as ON rather than silently disabling
    tracking on a parse hiccup."""
    path = os.path.join(CACHE_DIR, '_camera_frame_gate.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return content != '0'
    except (IOError, OSError):
        return True


# Manual pixel-space nudge -- see maya_camera_panels.py's own copy of
# get_pixel_offset() for the full explanation. Only needed here so the
# keyed curve can carry the SAME offset (offset_shift in key_edge_guard).
OFFSET_X_PX = 0.0
OFFSET_Y_PX = 0.0


def get_pixel_offset():
    """See maya_camera_panels.py for the full explanation. Same shared
    _camera_offset_px.txt file as the panels script."""
    path = os.path.join(CACHE_DIR, '_camera_offset_px.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        parts = content.split(',')
        if len(parts) == 2:
            return float(parts[0]), float(parts[1])
    except (IOError, OSError, ValueError):
        pass
    return OFFSET_X_PX, OFFSET_Y_PX


def get_world_per_px():
    """Reads the world-units-per-screen-pixel ratio maya_camera_panels.py's
    write_world_per_px() wrote right after frame_camera() computed it --
    needed so key_edge_guard can convert OFFSET_X_PX into the same
    world-space adjustment frame_camera() already applied, instead of
    silently discarding it. Returns None if the file
    doesn't exist yet (e.g. the panels script has never run this session)
    or is malformed -- callers must treat that as "skip the offset
    adjustment," not synthesize a guessed ratio, since a wrong guess would
    misapply the offset rather than just omitting it."""
    path = os.path.join(CACHE_DIR, '_camera_world_per_px.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return float(content)
    except (IOError, OSError, ValueError):
        return None


CACHE_PATH = cache_path_for(find_animation_reference())

# view_name -> (camera transform, which cached axis pair to use)
ACTIVE_VIEWS = {
    'front': ('d4_rom_front', 'x'),
    'back': ('d4_rom_back', 'x'),
    # 'side': ('d4_rom_right', 'z'),
    # 'left': ('d4_rom_left', 'z'),
}

MODE = 'edge_guard'   # 'edge_guard', 'dead_zone', or 'threshold'

THRESHOLD_PCT = 0.0    # used when MODE == 'threshold'
DEAD_ZONE_PCT = 0.50   # used when MODE == 'dead_zone': subject can roam this
                        # fraction of frame width around the camera before it reacts
EDGE_OVERFLOW_PCT = 0.02  # used when MODE == 'edge_guard': how far past the
                           # frame edge the subject may extend before the
                           # camera nudges back, as a fraction of frame width.
                           #
                           # MUST match EDGE_OVERFLOW_PCT in
                           # maya_camera_panels.py -- that script's
                           # compute_margin_px derives the frame width from
                           # this value (needed_ortho = max_w / (1 - 2*this)),
                           # sized so a max-width pose still fits even at
                           # full drift tolerance. This is NOT just a
                           # trigger threshold in isolation: edge_guard is
                           # reactive by construction (it only corrects once
                           # this tolerance is exceeded), so the worst-case
                           # clip depth is ALWAYS exactly this fraction of
                           # the frame width, regardless of how wide the
                           # frame is sized -- widening the frame only
                           # reduces how OFTEN clipping happens, not how bad
                           # it is when it does. Lowering this value is the
                           # only way to shrink the worst case itself.
                           #
                           # Design (2026-09-02, revised): a brief experiment
                           # decoupled this from frame-sizing entirely
                           # (frame sized for max_w alone, 8% tolerance) --
                           # reverted after user-reported hand-clipping
                           # persisted. Validated against palM_rom_anim's
                           # real cache: at 8%, worst-case clip was 22.8
                           # units (a visibly obvious hand); at 2%, worst
                           # case drops to ~5.0 units (a fingertip) at the
                           # cost of more frequent (but still small,
                           # nudge-sized) corrections -- 88 nudges across
                           # 3241 frames vs 11 at 8%. 2% chosen over an even
                           # tighter 1% (130 nudges, ~2.4 unit worst case)
                           # to keep corrections less frequent. Historical
                           # reference numbers below predate the
                           # frame-sizing redesign entirely (fixed 45px
                           # margin, narrower frame) -- not representative
                           # of current behavior, kept only for context:
                           #   0.05 -> 1775 keys (55% of frames), max jump 46.3
                           #   0.20 ->  104 keys,   2 reversals, max jump 3.3


def compute_size_scale(cache, axis):
    center_key, width_key = axis + '_center', axis + '_width'
    ref_frame = cache['frames'][0]
    cached_center_ref = cache[center_key][0]
    cached_width_ref = cache[width_key][0]

    cmds.select(clear=True)
    cmds.currentTime(ref_frame)
    bbox = get_target_bbox()
    if axis == 'x':
        current_center_ref, current_width_ref = (bbox[0] + bbox[3]) / 2.0, bbox[3] - bbox[0]
    else:
        current_center_ref, current_width_ref = (bbox[2] + bbox[5]) / 2.0, bbox[5] - bbox[2]

    scale = current_width_ref / cached_width_ref if cached_width_ref else 1.0
    return current_center_ref, cached_center_ref, scale


def key_from_cache(cam_transform, axis, cache, threshold_pct, current_ref, cached_ref, scale):
    frames = cache['frames']
    cached_values = cache[axis + '_center']
    attr = cam_transform + '.translate' + axis.upper()
    if cmds.keyframe(attr, query=True, keyframeCount=True):
        cmds.cutKey(attr, clear=True)

    shape = cmds.listRelatives(cam_transform, shapes=True)[0]
    threshold = threshold_pct * cmds.getAttr(shape + '.orthographicWidth')

    last_keyed = None
    keyed_count = 0
    for i, (frame, cached_value) in enumerate(zip(frames, cached_values)):
        value = current_ref + (cached_value - cached_ref) * scale
        is_boundary = (i == 0 or i == len(frames) - 1)
        if last_keyed is None or is_boundary or abs(value - last_keyed) > threshold:
            cmds.setKeyframe(attr, time=frame, value=value)
            last_keyed = value
            keyed_count += 1
    return keyed_count


def key_dead_zone(cam_transform, axis, cache, dead_zone_pct, current_ref, cached_ref, scale):
    """Camera only moves when the subject nears the edge of a comfort
    zone, and only enough to bring them back to that edge -- not to
    dead-center. Produces natural, lazy repositioning instead of rigid
    tracking."""
    frames = cache['frames']
    cached_values = cache[axis + '_center']
    subject = [current_ref + (v - cached_ref) * scale for v in cached_values]
    attr = cam_transform + '.translate' + axis.upper()
    if cmds.keyframe(attr, query=True, keyframeCount=True):
        cmds.cutKey(attr, clear=True)

    shape = cmds.listRelatives(cam_transform, shapes=True)[0]
    half_zone = (dead_zone_pct / 2.0) * cmds.getAttr(shape + '.orthographicWidth')

    cam_pos = subject[0]
    cmds.setKeyframe(attr, time=frames[0], value=cam_pos)
    keyed_count = 1
    last_keyed_frame = frames[0]

    for i in range(1, len(frames)):
        offset = subject[i] - cam_pos
        if offset > half_zone:
            cam_pos += offset - half_zone
        elif offset < -half_zone:
            cam_pos += offset + half_zone
        else:
            continue
        cmds.setKeyframe(attr, time=frames[i], value=cam_pos)
        keyed_count += 1
        last_keyed_frame = frames[i]

    if last_keyed_frame != frames[-1]:
        cmds.setKeyframe(attr, time=frames[-1], value=cam_pos)
        keyed_count += 1

    return keyed_count


def find_start_index(frames, start_frame):
    """Pure (no cmds). Index of the first cached frame >= start_frame -- the
    frame the capture starts on. None (no range known) or a start before the
    cache means index 0 (today's behaviour); a start past the last cached
    frame clamps to the last index."""
    if start_frame is None:
        return 0
    for i, f in enumerate(frames):
        if f >= start_frame:
            return i
    return len(frames) - 1


START_WINDOW_FRAMES = 30   # live frames measured after the start frame (T72 D1 fix)


def seed_series_at_start(centers, half_widths, start_index, live_samples, min_samples=5, floor_frac=0.02, spread_frac=0.25):
    """Pure (no cmds). T72 Option B: the edge-guard walk is SEEDED at the
    capture's start frame instead of at the first cached frame. Returns the
    (centers, half_widths) slices from start_index to the end.

    live_samples is a list of (centre, width) LIVE bbox measurements of the
    consecutive cached frames start_index, start_index+1, ... (the keyer
    measures START_WINDOW_FRAMES + 1 of them). Those frames take the LIVE
    centre and half width, so index 0 of the result IS the live subject
    centre at the start frame (the seed) and the first corrections are
    decided on what the character really does.

    The cached series after the measured window is shifted by the median of
    (live - cached) over the window ONLY when that difference is a consistent
    (rigid) shift: at least min_samples samples, |median| at least floor_frac
    of the live width, and every sample within spread_frac*|median| of the
    median. Otherwise it stays unshifted. Reason (defect D1, found on the rogM
    ROM scene): where the live character differs from the cache non-uniformly
    (one limb missing in the live scene, so only one bbox edge matches), the
    one-frame difference at the start frame is not valid for the rest of the
    take; shifting the whole walk by it put up to 5.4% of the frame width
    outside the tolerance. The guard parks the bbox edge exactly AT the
    tolerance, so any shift the live scene does not share shows up one for
    one as overflow. A rigid shift (the cache really is displaced by a
    constant) is still followed, so the camera does not snap back to the
    displaced cached path one frame later.

    start_index <= 0 returns both lists unchanged (the size-scale reference
    IS the live measurement at the first frame); start_index > 0 without
    samples returns the unshifted slices."""
    if start_index <= 0:
        return list(centers), list(half_widths)
    cs = list(centers[start_index:])
    hs = list(half_widths[start_index:])
    k = min(len(live_samples or []), len(cs))
    if k == 0:
        return cs, hs
    diffs = [live_samples[j][0] - cs[j] for j in range(k)]
    d = 0.0
    if k >= min_samples:
        ordered = sorted(diffs)
        mid = len(ordered) // 2
        median = ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2.0
        spread = max(abs(x - median) for x in diffs)
        if abs(median) >= floor_frac * live_samples[0][1] and spread <= spread_frac * abs(median):
            d = median
    cs = [c + d for c in cs]
    for j in range(k):
        cs[j] = live_samples[j][0]
        hs[j] = live_samples[j][1] / 2.0
    return cs, hs


def key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, overflow_pct=0.08, offset_shift=0.0, start_frame=None):
    """Camera only moves when the subject's bbox edge would extend past
    the visible frame by more than overflow_pct of the frame width (e.g. a
    hand poking past the edge during a wide arm-swing is tolerated), and
    only enough to bring that edge back to the allowed overflow limit --
    not all the way back to center. Keeps repositioning minimal and
    natural while still catching genuine subject-leaves-the-panel cases.

    Design (2026-09-02, reverted back to nudge from a brief full-recenter
    experiment): the recenter response made the camera visibly, slowly
    drift to center whenever it triggered -- distracting in a way the
    smaller, more frequent nudges aren't. The frame-sizing guarantee (see
    maya_camera_panels.py's compute_margin_px, sized directly off the
    widest pose in the whole animation, unchanged by this revert) already
    does the real work of preventing pose-width clipping; edge_guard here
    only has to correct SIDEWAYS DRIFT (e.g. walking during the take), and
    the launcher's Frame Offset tools (magnifier, X/Y pixel nudge, recenter
    at start frame) now cover the cases a human needs to fix by hand, so
    the automatic full-recenter safety net is no longer needed.

    BUG FIXED 2026-09-08: offset_shift used to not exist as a parameter at
    all -- this function had ZERO knowledge of the manual pixel offset, so
    the ENTIRE curve it builds ignored it completely. The one-frame recenter
    override that existed then (since removed, see the T72 paragraph below)
    patched the correct offset-aware position in at exactly one frame (the
    recenter frame), but that only ever fixed that ONE frame -- everywhere
    else in the animation, the offset silently vanished the moment playback
    moved away from it. Confirmed live via a differential test (offset=40px
    vs offset=0, sampled at 5 frames across the whole animation): the
    expected ~10.45-unit shift was present ONLY at the recenter frame,
    essentially absent everywhere else. Reported as "the edge-guard is not
    working" once a user proceeds past the frame-gate warning and actually
    plays/records the full animation, since Preview only ever shows the one
    static (correct-by-luck) recenter frame.

    Fix (superseded by G below, 2026-09-28): shift cam_pos by offset_shift
    ONCE at initialization, in the SAME world-unit direction frame_camera()
    already uses. The intent -- every subsequent
    keyframe computed incrementally FROM that same cam_pos, so the shift
    propagates through the ENTIRE curve for free -- turned out not to hold:
    algebraically, cam_pos_new = left_edge + half_ortho + overflow (or the
    symmetric right-edge form) on every CORRECTION, which has NO surviving
    cam_pos term at all -- the offset baked into frame 0's cam_pos is
    erased the instant any correction fires, exactly as if it had never
    been applied. Confirmed live (2026-09-28, zoom 20/offset 20 on barM):
    tolerance file 0.000000, first correction at frame 12 (offset 0) vs
    frame 10 (offset 20), curves IDENTICAL from frame 12 onward -- the
    20px offset survived on only 0.1% of frames. (The one-frame recenter
    override that used to run afterward is gone, see the T72 paragraph
    below.)

    G + B (2026-09-28, both live-proven -- see compute_edge_guard_curve's
    own docstring for the derivation and real-scene evidence):
    [G] (as of 2026-09-28; superseded by T72 item 6, 2026-10-20) The curve
    was built completely OFFSET-FREE by compute_edge_guard_curve, and
    offset_shift was subtracted from EVERY returned value here, uniformly,
    as a pure constant screen shift. That fixed the erasure bug above, but
    left the walk's gate one Offset away from the frame the artist sees.
    CURRENT behaviour: this function passes offset_shift INTO
    compute_edge_guard_curve, which seeds the walk at centers[0] -
    offset_shift and decides every nudge against that visible camera, so the
    returned values are written as they are and nothing is subtracted here.
    The Offset sets the START position; after a nudge it may fade.
    [B] compute_edge_guard_curve also holds (skips correcting) any frame
    whose pose cannot fit within the tolerance regardless of camera
    position, instead of chasing it with an oversized, cosmetically bad
    correction for zero actual benefit (the residual clip is the same
    either way -- see that function's own docstring).

    T72 Option B (2026-10-14): start_frame (the capture's resolved Start,
    from _camera_recenter_start_frame.txt) re-seeds the walk. The old
    recenter override (since removed) pinned ONE true-centre key at the
    start frame (a 3-key notch) but left the walk seeded at the first cached frame, so
    one frame later the camera jumped back to the frame-0-seeded curve:
    measured 8-11% of the frame width off centre at R+1 (R = 300, 600,
    1000, 2000 on barM). Now the live subject (centre and width) is measured
    at the start frame and the START_WINDOW_FRAMES frames after it, those
    frames take the live values, and the cached/scaled series after them is
    shifted only if the window shows a consistent shift (seed_series_at_start;
    D1 fix 2026-10-19, see its docstring: a one-frame shift of the whole walk
    broke the tolerance where the live character differs from the cache), and
    compute_edge_guard_curve walks from that frame to the end; only
    start..end is keyed, frames before the start hold the start-frame
    position (only the recorded range matters). The guard algorithm and the
    tolerance are unchanged. No start frame, or a start on the first cached
    frame, behaves as before."""
    frames = cache['frames']
    cached_centers = cache[axis + '_center']
    cached_widths = cache[axis + '_width']
    subject_center = [current_ref + (v - cached_ref) * scale for v in cached_centers]
    subject_half_width = [(w * scale) / 2.0 for w in cached_widths]

    start_index = find_start_index(frames, start_frame)
    live_samples = None
    if start_index > 0:
        # Live measurement of the capture's start frame and the next
        # START_WINDOW_FRAMES frames (the walk's seed and its first stretch).
        live_samples = []
        for i in range(start_index, min(len(frames), start_index + START_WINDOW_FRAMES + 1)):
            cmds.currentTime(frames[i])
            cmds.select(clear=True)
            bbox = get_target_bbox()
            if axis == 'x':
                live_samples.append(((bbox[0] + bbox[3]) / 2.0, bbox[3] - bbox[0]))
            else:
                live_samples.append(((bbox[2] + bbox[5]) / 2.0, bbox[5] - bbox[2]))
    centers, half_widths = seed_series_at_start(subject_center, subject_half_width, start_index, live_samples)

    attr = cam_transform + '.translate' + axis.upper()
    if cmds.keyframe(attr, query=True, keyframeCount=True):
        cmds.cutKey(attr, clear=True)

    shape = cmds.listRelatives(cam_transform, shapes=True)[0]
    ortho_width = cmds.getAttr(shape + '.orthographicWidth')
    half_ortho = ortho_width / 2.0
    overflow = overflow_pct * ortho_width

    # T72 item 6: the walk runs in the frame the artist SEES (seeded at the centre minus the
    # Offset, gate = that camera's frame edge +/- tolerance), so its values are written as they are.
    curve = compute_edge_guard_curve(centers, half_widths, half_ortho, overflow, offset_shift)
    for j, value in curve:
        cmds.setKeyframe(attr, time=frames[start_index + j], value=value)

    return len(curve)


def compute_edge_guard_curve(centers, half_widths, half_ortho, overflow, offset_shift=0.0):
    """Pure, cmds-free replica of key_edge_guard's own tracking loop.

    T72 item 6 (2026-10-20): the gate follows the frame the artist SEES.
    offset_shift (world units, Offset px * world_per_px) seeds the walk at
    centers[0] - offset_shift and every later decision compares the pose with
    THAT camera, so the returned values are the camera values to write, as
    they are (the caller no longer subtracts anything). Before, the walk was
    built offset-free [G] and the caller subtracted offset_shift per value:
    the gate then sat one Offset away from the visible frame (a false nudge
    on one side, a missed nudge on the other, up to the whole Offset wide).
    The Offset now only sets the START; after a nudge it may fade, because
    the camera never meets an invisible gate. offset_shift=0.0 (the default)
    is byte-for-byte the old curve.

    The design history below (G+B, 2026-09-28) describes the earlier offset-free
    form of this function; its [B] hold and the numbers it quotes still apply
    at Offset 0.

    Returns a list of (index, value) pairs -- index into the SAME centers/
    half_widths arrays (equivalently, cache['frames']) -- marking every
    entry that needs an explicit keyframe: index 0 (the anchor), every
    corrective nudge, and the last index (if it wasn't already a
    correction), mirroring the original loop's keyed_count/last_keyed_frame
    bookkeeping exactly, minus the cmds calls.

    [B] Hold when the pose cannot fit: if a pose's own half-width alone
    already exceeds half_ortho + overflow, NO camera position can bring
    both edges inside the allowed range simultaneously -- moving toward
    one edge only worsens the other by the same amount, so "correcting"
    would just chase an unfixable pose: large, frequent motion for a
    residual clip that happens regardless (the SAME clip whether the
    camera moves or not). Holding is a deliberate no-op for that frame,
    not a missed correction -- confirmed live this does not create visible
    snaps when the pose later fits again: on barM at zoom+20%/offset20,
    the first correction after a hold was at most 18px (mean 5px), not a
    jarring jump back.

    Design history for the overall G+B rework (2026-09-28, live-proven
    against barM's real cache, full take, zoom+20%/offset20px):
    - A (current code, offset baked into cam_pos only): 1240 keys, offset
      held on only 0.3% of frames (0.1% live), mean/max single correction
      34px/169px, 366 corrections > 50px, max camera travel 336px.
    - G+B (this function): 480 keys, offset held 100% of frames BY
      CONSTRUCTION (every value gets the same subtraction), mean/max
      correction 3px/25px, zero corrections > 50px, max travel 146px.
    - The trade-off: G+B's offset-side overflow is larger (frames over 0
      tolerance 44.6% vs A's 23.1%, worst overflow 20.7% vs 17.6%) -- the
      price of "offset always wins" is that the guard's own tolerance is
      now zoom-only (see maya_camera_panels.py's compute_effective_
      overflow_pct call), no longer shrunk by the offset the way A's was.
      Accepted trade-off (tolerance box, built separately, makes it a
      visible per-take choice instead of a hidden cost).

    Validated (2026-09-28, plain Python, no Maya, against the real barM
    cache -- see scratchpad proto_keyer_gb.py/validate_gb_prototype.py):
    keys 480/480 exact, frames-over-tolerance 44.6%/44.6% exact, worst
    overflow 20.7%/20.7% exact, differential property (offset0 vs
    offset20 curves) exact to floating-point precision, B never holds at
    zoom0/offset0 (the regression case) confirmed True."""
    n = len(centers)
    if n == 0:
        return []
    cam_pos = centers[0] - offset_shift
    curve = [(0, cam_pos)]
    last_keyed_index = 0
    for i in range(1, n):
        if half_widths[i] > half_ortho + overflow:
            # [B] pose cannot fit even with the full tolerance -- hold.
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


_t0 = time.time()
original_time = cmds.currentTime(query=True)

if not os.path.exists(CACHE_PATH):
    print('No cache found for this animation -- sampling now (this takes a while, one time only)...')
    cache_script = os.path.join(SCRIPTS_DIR, 'maya_cache_bbox.py')
    exec(compile(open(cache_script).read(), cache_script, 'exec'), {})

if not os.path.exists(CACHE_PATH):
    # The build attempt above ran to completion but deliberately did NOT
    # write a cache (CACHE_NO_ANIMATION / CACHE_EMPTY_ANIMATION -- see
    # maya_cache_bbox.py's own printed reason just above this). Design
    # (2026-08-22): the tool must never quietly stop here -- previously
    # this fell straight through into `open(CACHE_PATH)` below, raising a
    # bare FileNotFoundError with no context, which (a) gave no
    # actionable reason and (b) the launcher's step queue doesn't gate on
    # a step's exit code, so it silently continued into spawning camera
    # panels and starting an OBS recording of a scene with no real ROM
    # motion. CAPTURE_ABORT is a marker rom_launcher.ps1's step runner
    # watches for specifically to stop the whole run here, not just this
    # one step -- recording is genuinely not possible without a cache, so
    # continuing would only ever produce a broken result.
    #
    # The marker lives in the RAISED exception's own message, not a
    # separate print() -- confirmed live (2026-08-22) that Maya's command
    # port does not relay print() output back over the socket on a
    # successful run, only an exception's text (or the bare exec() return
    # value, always None). The print()+raise split meant this marker could
    # never actually reach rom_launcher.ps1 at all -- the detection code
    # on the PowerShell side was correctly written but structurally dead.
    raise RuntimeError('CAPTURE_ABORT: no cache could be built for this animation -- check that the ROM animation reference is actually loaded and keyed in this scene, then try again.')

with open(CACHE_PATH) as f:
    cache = json.load(f)

print('Using cache: %d frames (%s to %s), animation=%s, cached from character scene=%s'
      % (len(cache['frames']), cache['start'], cache['end'],
         cache.get('animation_reference'), cache.get('source_character_scene')))

# Suspended for the whole keying pass (2026-09-08): without this, the
# reference-frame scale measurement and the start-frame live measurement both jump
# cmds.currentTime() around visibly -- reported as "the viewport kept
# updating the progress... quite distracting." Resumed in `finally` (this
# whole block had NO exception handling at all before -- a mid-run
# failure used to leave the timeline stuck wherever the last jump landed,
# a real pre-existing gap this also closes). Placed AFTER the cache-load
# above, not at the top of the file: a first-time cache build
# (maya_cache_bbox.py, several minutes) has its own separate progress
# reporting and shouldn't be hidden by this.
cmds.refresh(suspend=True)
try:
    effective_overflow_pct = get_effective_overflow_pct()
    if abs(effective_overflow_pct - EDGE_OVERFLOW_PCT) > 1e-6:
        print('Using zoom-adjusted drift tolerance: %.2f%% (base %.2f%%)' % (effective_overflow_pct * 100, EDGE_OVERFLOW_PCT * 100))

    recenter_frame = get_recenter_start_frame()
    offset_x_px, offset_y_px = get_pixel_offset()
    world_per_px = get_world_per_px()
    # "Skip rather than guess": a missing world_per_px must never
    # synthesize a fallback ratio (a wrong guess would misapply the offset
    # instead of just omitting it), so the offset is simply not applied.
    offset_shift = (offset_x_px * world_per_px) if world_per_px is not None else 0.0

    frame_gate_enabled = get_frame_gate_enabled()
    if not frame_gate_enabled:
        print('Frame gate OFF: camera held static (no tracking, no drift correction)')

    scale_cache = {}
    for view_name, (cam_transform, axis) in ACTIVE_VIEWS.items():
        if not cmds.objExists(cam_transform):
            print('Skipped %s: camera "%s" does not exist' % (view_name, cam_transform))
            continue

        if not frame_gate_enabled:
            # Gate OFF: the camera stays exactly where maya_camera_panels.py's
            # frame_camera() already parked it (start-frame bbox centre,
            # Offset and Zoom applied, run just before this script) -- no
            # per-frame tracking, no key_edge_guard.
            # cutKey still runs UNCONDITIONALLY here (guarded only on
            # keyframeCount, matching the existing key_edge_guard/key_from_
            # cache/key_dead_zone convention) so a stale ON-mode curve left
            # over from an EARLIER run on this same scene (gate flipped OFF
            # without a Reset in between) is removed even though this run's
            # own OFF pass never adds any keys of its own -- otherwise the
            # camera would keep tracking on old keys despite the checkbox
            # being off, a silent stale-key bug of exactly the kind this
            # project has hit before.
            attr = cam_transform + '.translate' + axis.upper()
            if cmds.keyframe(attr, query=True, keyframeCount=True):
                cmds.cutKey(attr, clear=True)
            print('%s (%s): Frame gate OFF -- camera held static' % (view_name, cam_transform))
            continue

        if axis not in scale_cache:
            scale_cache[axis] = compute_size_scale(cache, axis)
        current_ref, cached_ref, scale = scale_cache[axis]
        print('%s axis size scale: %.4f (current width / cached width at ref frame)' % (axis, scale))

        if MODE == 'edge_guard':
            keyed = key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, effective_overflow_pct, offset_shift, recenter_frame)
        elif MODE == 'dead_zone':
            keyed = key_dead_zone(cam_transform, axis, cache, DEAD_ZONE_PCT, current_ref, cached_ref, scale)
        else:
            keyed = key_from_cache(cam_transform, axis, cache, THRESHOLD_PCT, current_ref, cached_ref, scale)
        print('%s (%s): %d keyframes from %d cached samples (start frame %s)' % (view_name, cam_transform, keyed, len(cache['frames']), recenter_frame))
finally:
    cmds.currentTime(original_time)
    cmds.refresh(suspend=False)
elapsed = time.time() - _t0
print('Elapsed: %.2f sec' % elapsed)
with open(r'D:\__backup\claude\maya_debug.txt', 'w') as f:
    f.write('elapsed_sec=%.2f threshold_pct=%s scales=%s' % (elapsed, THRESHOLD_PCT, scale_cache))
print('KEY_FROM_CACHE_OK')
