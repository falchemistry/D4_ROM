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


def apply_recenter_override(cam_transform, axis, recenter_frame):
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
    normally via edge_guard."""
    attr = cam_transform + '.translate' + axis.upper()
    cmds.currentTime(recenter_frame)
    cmds.select(clear=True)
    bbox = get_target_bbox()
    if axis == 'x':
        true_center = (bbox[0] + bbox[3]) / 2.0
    else:
        true_center = (bbox[2] + bbox[5]) / 2.0
    cmds.setKeyframe(attr, time=recenter_frame, value=true_center)


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


def key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, overflow_pct=0.08):
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
    the automatic full-recenter safety net is no longer needed."""
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

    cam_pos = subject_center[0]
    cmds.setKeyframe(attr, time=frames[0], value=cam_pos)
    keyed_count = 1
    last_keyed_frame = frames[0]

    for i in range(1, len(frames)):
        left_edge = subject_center[i] - subject_half_width[i]
        right_edge = subject_center[i] + subject_half_width[i]
        allowed_left = cam_pos - half_ortho - overflow
        allowed_right = cam_pos + half_ortho + overflow

        if left_edge < allowed_left:
            cam_pos += left_edge - allowed_left
        elif right_edge > allowed_right:
            cam_pos += right_edge - allowed_right
        else:
            continue

        cmds.setKeyframe(attr, time=frames[i], value=cam_pos)
        keyed_count += 1
        last_keyed_frame = frames[i]

    if last_keyed_frame != frames[-1]:
        cmds.setKeyframe(attr, time=frames[-1], value=cam_pos)
        keyed_count += 1

    return keyed_count


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

effective_overflow_pct = get_effective_overflow_pct()
if abs(effective_overflow_pct - EDGE_OVERFLOW_PCT) > 1e-6:
    print('Using zoom-adjusted drift tolerance: %.2f%% (base %.2f%%)' % (effective_overflow_pct * 100, EDGE_OVERFLOW_PCT * 100))

recenter_frame = get_recenter_start_frame()

scale_cache = {}
for view_name, (cam_transform, axis) in ACTIVE_VIEWS.items():
    if not cmds.objExists(cam_transform):
        print('Skipped %s: camera "%s" does not exist' % (view_name, cam_transform))
        continue
    if axis not in scale_cache:
        scale_cache[axis] = compute_size_scale(cache, axis)
    current_ref, cached_ref, scale = scale_cache[axis]
    print('%s axis size scale: %.4f (current width / cached width at ref frame)' % (axis, scale))

    if MODE == 'edge_guard':
        keyed = key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, effective_overflow_pct)
    elif MODE == 'dead_zone':
        keyed = key_dead_zone(cam_transform, axis, cache, DEAD_ZONE_PCT, current_ref, cached_ref, scale)
    else:
        keyed = key_from_cache(cam_transform, axis, cache, THRESHOLD_PCT, current_ref, cached_ref, scale)
    print('%s (%s): %d keyframes from %d cached samples' % (view_name, cam_transform, keyed, len(cache['frames'])))

    if recenter_frame is not None:
        apply_recenter_override(cam_transform, axis, recenter_frame)
        print('%s (%s): overrode frame %s with a true live-centered keyframe' % (view_name, cam_transform, recenter_frame))

cmds.currentTime(original_time)
elapsed = time.time() - _t0
print('Elapsed: %.2f sec' % elapsed)
with open(r'D:\__backup\claude\maya_debug.txt', 'w') as f:
    f.write('elapsed_sec=%.2f threshold_pct=%s scales=%s' % (elapsed, THRESHOLD_PCT, scale_cache))
print('KEY_FROM_CACHE_OK')
