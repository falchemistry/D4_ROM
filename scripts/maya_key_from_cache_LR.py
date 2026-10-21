"""Left/right variant of maya_key_from_cache.py -- same logic, targets the
d4_rom_left / d4_rom_right cameras on the Z axis instead of front/back on X.
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
    """See maya_key_from_cache.py for the full explanation. Same shared
    _camera_effective_overflow_pct.txt file."""
    path = os.path.join(CACHE_DIR, '_camera_effective_overflow_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return max(0.0, float(content))
    except (IOError, OSError, ValueError):
        return EDGE_OVERFLOW_PCT


def get_recenter_start_frame():
    """See maya_key_from_cache.py for the full explanation. Same shared
    _camera_recenter_start_frame.txt file."""
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
    """See maya_key_from_cache.py for the full explanation. Same shared
    _camera_frame_gate.txt file -- '0' means OFF, anything else (including
    missing/malformed) means ON."""
    path = os.path.join(CACHE_DIR, '_camera_frame_gate.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return content != '0'
    except (IOError, OSError):
        return True


# Manual pixel-space nudge -- see maya_camera_panels.py's get_pixel_offset()
# for the full explanation. Only needed here so the keyed curve can carry the
# SAME offset (offset_shift in key_edge_guard).
OFFSET_X_PX = 0.0
OFFSET_Y_PX = 0.0


def get_pixel_offset():
    """See maya_camera_panels.py for the full explanation. Same shared
    _camera_offset_px.txt file."""
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
    """See maya_key_from_cache.py for the full explanation. Same shared
    _camera_world_per_px.txt file, written by maya_camera_panels_LR.py's
    write_world_per_px()."""
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
    'side': ('d4_rom_right', 'z'),
    'left': ('d4_rom_left', 'z'),
}

MODE = 'edge_guard'   # 'edge_guard', 'dead_zone', or 'threshold'

THRESHOLD_PCT = 0.0    # used when MODE == 'threshold'
DEAD_ZONE_PCT = 0.50   # used when MODE == 'dead_zone': subject can roam this
                        # fraction of frame width around the camera before it reacts
EDGE_OVERFLOW_PCT = 0.02  # used when MODE == 'edge_guard': how far past the
                           # frame edge the subject may extend before the
                           # camera nudges back, as a fraction of frame width.
                           # MUST match EDGE_OVERFLOW_PCT in
                           # maya_camera_panels_LR.py, which derives the
                           # frame width from it (2026-09-02 revision, see
                           # maya_key_from_cache.py for the full derivation
                           # and rationale for lowering this from 0.08).


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
    """See maya_key_from_cache.py's copy of this function for the full
    design note (2026-09-02, reverted back to nudge from a brief
    full-recenter experiment -- the recenter made the camera visibly drift
    to center on trigger, which read as distracting rather than helpful).
    Nudges just enough to bring the offending edge back to the allowed
    overflow limit, not all the way to center.

    BUG FIXED 2026-09-08: offset_shift (see maya_key_from_cache.py's copy
    for the full writeup) -- this function used to have zero knowledge of
    the manual pixel offset at all, so the whole curve ignored it outside
    the (since removed) one-frame recenter override.

    G + B (2026-09-28, see maya_key_from_cache.py's copy of this function
    and of compute_edge_guard_curve below for the full derivation and
    real-scene/replica evidence -- identical fix here, z axis instead of
    x): the 2026-09-08 fix above turned out not to actually hold under
    correction (algebraically, cam_pos_new = edge +/- half_ortho +/-
    overflow has no surviving cam_pos term, so any correction erases
    whatever offset was baked into frame 0). [G] (as of 2026-09-28;
    superseded by T72 item 6, 2026-10-20) built the curve completely
    offset-free and subtracted offset_shift from EVERY keyed value
    uniformly. CURRENT behaviour: this function passes offset_shift INTO
    compute_edge_guard_curve, which seeds the walk at centers[0] -
    offset_shift and decides every nudge against that visible camera, so
    the values are written as they are and nothing is subtracted here (the
    Offset sets the START position; after a nudge it may fade). [B] holds (skips correcting) any
    frame whose pose cannot fit within the tolerance regardless of camera
    position, instead of chasing it for zero actual benefit.

    T72 Option B (2026-10-14): start_frame re-seeds the walk at the
    capture's start frame from the LIVE subject there (centre and width of
    the start frame and the START_WINDOW_FRAMES after it, see
    seed_series_at_start); only start..end is keyed (the one-frame recenter
    notch is gone). See maya_key_from_cache.py's copy of this function for the full
    writeup and the measured before/after (identical here, z axis)."""
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
    """See maya_key_from_cache.py's copy of this function for the full
    docstring, derivation, and evidence (identical here) -- pure, cmds-free
    replica of key_edge_guard's own tracking loop, with a hold when a pose
    cannot fit within the tolerance regardless of camera position [B].
    T72 item 6 (2026-10-20): the walk is seeded at centers[0] - offset_shift
    and compares every pose with that VISIBLE camera, so the returned values
    are written as they are (no post-subtraction); offset_shift=0.0 is
    byte-for-byte the old curve."""
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
    # See maya_key_from_cache.py's own copy of this check for the full
    # reasoning -- same fix, same design (2026-08-22): never quietly
    # continue into a broken recording when no cache could be built.
    # Marker lives in the raised exception's message, not a separate
    # print() -- print() output never relays back through Maya's command
    # port, so the print()+raise split left this detection dead on the
    # PowerShell side. See maya_key_from_cache.py for the full story.
    raise RuntimeError('CAPTURE_ABORT: no cache could be built for this animation -- check that the ROM animation reference is actually loaded and keyed in this scene, then try again.')

with open(CACHE_PATH) as f:
    cache = json.load(f)

print('Using cache: %d frames (%s to %s), animation=%s, cached from character scene=%s'
      % (len(cache['frames']), cache['start'], cache['end'],
         cache.get('animation_reference'), cache.get('source_character_scene')))

# Suspended for the whole keying pass -- see maya_key_from_cache.py's own
# copy for the full explanation (identical fix here). Placed AFTER the
# cache-load above so a first-time cache build's own progress reporting
# is never hidden by this.
cmds.refresh(suspend=True)
try:
    effective_overflow_pct = get_effective_overflow_pct()
    if abs(effective_overflow_pct - EDGE_OVERFLOW_PCT) > 1e-6:
        print('Using zoom-adjusted drift tolerance: %.2f%% (base %.2f%%)' % (effective_overflow_pct * 100, EDGE_OVERFLOW_PCT * 100))

    recenter_frame = get_recenter_start_frame()
    offset_x_px, offset_y_px = get_pixel_offset()
    world_per_px = get_world_per_px()
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
            # See maya_key_from_cache.py's copy of this branch for the full
            # explanation (identical here, tracked axis 'z' instead of 'x').
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
