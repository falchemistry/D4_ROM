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


def apply_recenter_override(cam_transform, axis, recenter_frame):
    """See maya_key_from_cache.py for the full explanation: guarantees the
    frame Preview/Start Recording shows is actually correctly centered on
    BOTH axes, since key_edge_guard's own curve only guarantees "stays
    on-screen," not "centered"."""
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


def key_edge_guard(cam_transform, axis, cache, current_ref, cached_ref, scale, overflow_pct=0.08):
    """See maya_key_from_cache.py's copy of this function for the full
    design note (2026-09-02, reverted back to nudge from a brief
    full-recenter experiment -- the recenter made the camera visibly drift
    to center on trigger, which read as distracting rather than helpful).
    Nudges just enough to bring the offending edge back to the allowed
    overflow limit, not all the way to center."""
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
