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
# get_pixel_offset() for the full explanation. Only needed here so
# apply_recenter_override can apply the SAME offset instead of discarding
# it (see that function's docstring).
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
    needed so apply_recenter_override's override keyframe can convert
    OFFSET_X_PX into the same world-space adjustment frame_camera() already
    applied, instead of silently discarding it. Returns None if the file
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


def apply_recenter_override(cam_transform, axis, recenter_frame, offset_x_px, world_per_px):
    """Design (2026-09-02): key_edge_guard's own curve does NOT guarantee
    exact centering at any particular frame -- its job is "never let the
    subject go off-screen," which is a much looser constraint than "stay
    centered," so the curve it naturally produces can leave the subject
    visibly off-center at an arbitrary frame (confirmed live: subject
    center off by 1.2% of orthoWidth at a real recenter frame, purely from
    edge_guard's own sparse-key interpolation, no bug in the tracking
    itself). maya_camera_panels.py's own "Recenter at start frame" only
    ever controlled the VERTICAL axis in practice, since this Y translate
    is the one axis the keyer never touches -- horizontal panning
    (translateX for front/back, translateZ for left/right) gets
    OVERWRITTEN by whatever curve key_edge_guard/etc. just built, silently
    discarding panels.py's own centering there. This inserts one explicit
    keyframe exactly at recenter_frame, using a fresh live bbox
    measurement, so the frame Preview/Start Recording actually shows the
    artist is guaranteed correctly centered on both axes -- the rest of
    the curve (before/after that one frame) is untouched, still tracking
    normally via edge_guard.

    BUG FIXED 2026-09-08: this override computed true_center from a raw
    bbox measurement only, ignoring the manual pixel offset (see
    get_pixel_offset()) that frame_camera() had already applied moments
    earlier in maya_camera_panels.py. Since 'axis' here is always the
    TRACKED/horizontal axis -- the same one OFFSET_X_PX drives -- and
    recenter_frame is exactly the one frame Preview leaves the artist
    looking at, this silently erased the X pixel offset on every Preview
    click that had recenter active (now unconditional). Reported live as
    "the X and Y offset I set isn't reflected in preview." Confirmed on a
    real scene: translateX went from 3.7481 (correct) to 16.8072 (offset
    erased) between the panels script and this override, at the same
    frame -- a 13.06-unit difference matching 50px times that frame's own
    world-per-pixel ratio. Fix: apply the same subtraction frame_camera()
    uses, through the SAME world_per_px ratio it computed (get_world_per_px)
    -- never re-derive world_per_px independently here, or the two drift
    out of sync the same way this bug demonstrated.

    BUG FIXED 2026-09-08 (second fix, same day): the keyframe this inserts
    used Maya's default 'auto' (smooth) tangent, splicing a foreign value
    into key_edge_guard's otherwise sparse, reactive curve. 'auto' tangents
    are computed from neighboring keys and can swing PAST the values on
    either side between two distant keys -- normally invisible, because the
    2% overflow_pct cushion absorbs it. Reported live as "frame gate still
    not pushing the character" at a specific offset+zoom combo that had
    driven effective_overflow_pct to exactly 0 (no cushion left to hide the
    swing), then again as "draggy animation at start of capture frame" once
    a first attempt (linear tangents on JUST this keyframe, still in this
    file's history) only partially fixed it. Confirmed on a real scene with
    recenter active at frame 2000: edge_guard alone (no override) held
    0.00000 overshoot at every single frame of the whole animation even at
    0 cushion; adding the override back with 'auto' tangents produced up to
    26 units of overshoot across 9 clusters from frame 1934 to 2688; the
    linear-tangent-only attempt only reduced that to 20.6 units across 6
    clusters, because it straightens the two segments touching this key but
    the real neighboring keys it connects to (here: 1837 and 3240, both
    holding the SAME value -- a long calm gap with nothing to correct) are
    still smoothly, gradually blended toward a DIFFERENT value across that
    entire gap, which is itself the "draggy" symptom even where it no
    longer overshoots.

    Actual fix: pin the curve back to its own pre-override value exactly 1
    frame before and 1 frame after recenter_frame, with linear tangents
    through all three points. This turns the correction into a single-
    frame notch instead of a wide bulge or a slow drift -- everywhere
    else, the curve is untouched, which is what the design paragraph above
    already promised but 'auto' tangents were quietly breaking. Confirmed:
    0.00000 overshoot across the ENTIRE animation on the same real scene
    that showed 26 units of clipping before this fix."""
    attr = cam_transform + '.translate' + axis.upper()

    # Sampled BEFORE inserting anything below, so these anchors pin the
    # curve to exactly what key_edge_guard's own curve already was at
    # these two frames -- see the "Actual fix" docstring paragraph above.
    anchor_before, anchor_after = recenter_frame - 1, recenter_frame + 1
    value_before = cmds.getAttr(attr, time=anchor_before)
    value_after = cmds.getAttr(attr, time=anchor_after)

    cmds.currentTime(recenter_frame)
    cmds.select(clear=True)
    bbox = get_target_bbox()
    if axis == 'x':
        true_center = (bbox[0] + bbox[3]) / 2.0
    else:
        true_center = (bbox[2] + bbox[5]) / 2.0
    if world_per_px is not None:
        true_center -= offset_x_px * world_per_px

    cmds.setKeyframe(attr, time=anchor_before, value=value_before)
    cmds.setKeyframe(attr, time=recenter_frame, value=true_center)
    cmds.setKeyframe(attr, time=anchor_after, value=value_after)
    for t in (anchor_before, recenter_frame, anchor_after):
        cmds.keyTangent(attr, time=(t, t), inTangentType='linear', outTangentType='linear')


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


def key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, overflow_pct=0.08, offset_shift=0.0):
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
    the ENTIRE curve it builds ignored it completely. apply_recenter_override
    patches the correct offset-aware position in at exactly one frame (the
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
    ONCE at initialization, in the SAME world-unit direction frame_camera()/
    apply_recenter_override() already use. The intent -- every subsequent
    keyframe computed incrementally FROM that same cam_pos, so the shift
    propagates through the ENTIRE curve for free -- turned out not to hold:
    algebraically, cam_pos_new = left_edge + half_ortho + overflow (or the
    symmetric right-edge form) on every CORRECTION, which has NO surviving
    cam_pos term at all -- the offset baked into frame 0's cam_pos is
    erased the instant any correction fires, exactly as if it had never
    been applied. Confirmed live (2026-09-28, zoom 20/offset 20 on barM):
    tolerance file 0.000000, first correction at frame 12 (offset 0) vs
    frame 10 (offset 20), curves IDENTICAL from frame 12 onward -- the
    20px offset survived on only 0.1% of frames. apply_recenter_override
    still runs afterward and is still needed for the same reason as
    before: it corrects sparse-key INTERPOLATION drift at one specific
    frame, unrelated to whether the offset applies elsewhere.

    G + B (2026-09-28, both live-proven -- see compute_edge_guard_curve's
    own docstring for the derivation and real-scene evidence):
    [G] The curve itself is now built completely OFFSET-FREE by compute_
    edge_guard_curve (which never sees offset_shift at all), and offset_shift
    is subtracted from EVERY returned value here, uniformly, as a pure
    constant screen shift -- not just the first. This is what actually
    fixes the erasure bug above: a per-value subtraction can never cancel
    out algebraically the way baking it into a chained cam_pos did.
    [B] compute_edge_guard_curve also holds (skips correcting) any frame
    whose pose cannot fit within the tolerance regardless of camera
    position, instead of chasing it with an oversized, cosmetically bad
    correction for zero actual benefit (the residual clip is the same
    either way -- see that function's own docstring)."""
    frames = cache['frames']
    cached_centers = cache[axis + '_center']
    cached_widths = cache[axis + '_width']
    subject_center = [current_ref + (v - cached_ref) * scale for v in cached_centers]
    subject_half_width = [(w * scale) / 2.0 for w in cached_widths]

    attr = cam_transform + '.translate' + axis.upper()
    if cmds.keyframe(attr, query=True, keyframeCount=True):
        cmds.cutKey(attr, clear=True)

    shape = cmds.listRelatives(cam_transform, shapes=True)[0]
    ortho_width = cmds.getAttr(shape + '.orthographicWidth')
    half_ortho = ortho_width / 2.0
    overflow = overflow_pct * ortho_width

    curve = compute_edge_guard_curve(subject_center, subject_half_width, half_ortho, overflow)
    for i, value in curve:
        cmds.setKeyframe(attr, time=frames[i], value=value - offset_shift)

    return len(curve)


def compute_edge_guard_curve(centers, half_widths, half_ortho, overflow):
    """Pure, cmds-free replica of key_edge_guard's own tracking loop --
    OFFSET-FREE by design [G]: the caller (key_edge_guard) subtracts
    offset_shift from EVERY returned value uniformly, as a pure constant
    screen shift, rather than this function ever seeing or propagating an
    offset internally. This is the actual fix for the erasure bug key_edge_
    guard's own docstring documents: a per-value subtraction after the fact
    can never algebraically cancel out the way baking an offset into a
    chained cam_pos did.

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
    curve = [(0, centers[0])]
    cam_pos = centers[0]
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
# reference-frame scale measurement and the recenter override both jump
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
    # Same "skip rather than guess" fallback as apply_recenter_override --
    # see that function's docstring for why a missing world_per_px must
    # never synthesize a fallback ratio.
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
            # per-frame tracking, no key_edge_guard, no apply_recenter_override.
            # cutKey still runs UNCONDITIONALLY here (guarded only on
            # keyframeCount, matching the existing key_edge_guard/key_from_
            # cache/key_dead_zone convention) so a stale ON-mode curve left
            # over from an EARLIER run on this same scene (gate flipped OFF
            # without a Reset in between) is removed even though this run's
            # own OFF pass never adds any keys of its own -- otherwise the
            # camera would keep tracking on old keys despite the checkbox
            # being off, a silent stale-key bug of exactly the kind this
            # project has hit before (see apply_recenter_override's own
            # BUG FIXED writeups).
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
            keyed = key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, effective_overflow_pct, offset_shift)
        elif MODE == 'dead_zone':
            keyed = key_dead_zone(cam_transform, axis, cache, DEAD_ZONE_PCT, current_ref, cached_ref, scale)
        else:
            keyed = key_from_cache(cam_transform, axis, cache, THRESHOLD_PCT, current_ref, cached_ref, scale)
        print('%s (%s): %d keyframes from %d cached samples' % (view_name, cam_transform, keyed, len(cache['frames'])))

        if recenter_frame is not None:
            apply_recenter_override(cam_transform, axis, recenter_frame, offset_x_px, world_per_px)
            print('%s (%s): overrode frame %s with a true live-centered keyframe' % (view_name, cam_transform, recenter_frame))
finally:
    cmds.currentTime(original_time)
    cmds.refresh(suspend=False)
elapsed = time.time() - _t0
print('Elapsed: %.2f sec' % elapsed)
with open(r'D:\__backup\claude\maya_debug.txt', 'w') as f:
    f.write('elapsed_sec=%.2f threshold_pct=%s scales=%s' % (elapsed, THRESHOLD_PCT, scale_cache))
print('KEY_FROM_CACHE_OK')
