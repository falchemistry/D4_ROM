"""One-time (per referenced animation) dense sampler: walks every frame in
the playback range, evaluates the rig, and caches the horizontal
bounding-box center (both the front/back axis and the left/right axis) to
a JSON file keyed by the scene's referenced animation file path -- e.g.
D:/__rom/_legacy/2024_05_06/barM_rom_anim.ma. Different character scenes
that reference the SAME animation file share one cache; if a cache for
this animation already exists, sampling is skipped entirely.

Note: the cached bbox values are still mesh-derived, so they're only
exactly right for the character size this cache was built from -- reusing
across differently-sized characters on the same animation is an
approximation, not guaranteed-exact.

This is the expensive part (cmds.currentTime() forces a full rig
evaluation per frame) -- run it once per animation. Downstream keying
decisions (threshold, step, stepped-vs-smooth) can then be made near-
instantly from the cached data via maya_key_from_cache.py, without ever
touching Maya's evaluation again for this animation.
"""
import hashlib
import json
import os
import sys
import maya.cmds as cmds

# Relative to this script's own location, not a hardcoded absolute path --
# the co_filename trick works because compile() below is (indirectly, via
# send_to_maya.ps1) always given this file's real path, even though plain
# exec() doesn't set __file__ in the namespace.
SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
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


anim_ref = find_animation_reference()
cache_path = cache_path_for(anim_ref)
print('Animation reference: %s' % anim_ref)
print('Cache path: %s' % cache_path)

if os.path.exists(cache_path):
    print('Cache already exists, skipping sampling.')
    print('CLAUDE_CACHE_OK')
else:
    os.makedirs(CACHE_DIR, exist_ok=True)
    cmds.select(clear=True)
    original_time = cmds.currentTime(query=True)

    start = cmds.playbackOptions(query=True, minTime=True)
    end = cmds.playbackOptions(query=True, maxTime=True)

    # This step is a single long, synchronous command-port call with no
    # other feedback -- from outside, several genuine minutes of sampling
    # look identical to a hung/broken command port (confirmed the hard way
    # once already). Poll this file to check whether it's actually
    # progressing without needing the (blocked) command port to respond.
    PROGRESS_PATH = os.path.join(CACHE_DIR, '_cache_build_progress.txt')
    total_frames = int(end - start) + 1

    def _write_progress(done, total, note=''):
        with open(PROGRESS_PATH, 'w') as pf:
            pf.write('animation_reference=%s\n' % anim_ref)
            pf.write('frames_done=%d\n' % done)
            pf.write('frames_total=%d\n' % total)
            pf.write('percent=%.1f\n' % (100.0 * done / total if total else 100.0))
            if note:
                pf.write('note=%s\n' % note)

    _write_progress(0, total_frames, note='starting')

    frames = []
    x_centers = []
    x_widths = []
    z_centers = []
    z_widths = []

    frame = start
    while frame <= end:
        cmds.currentTime(frame)
        bbox = get_target_bbox()
        frames.append(frame)
        x_centers.append((bbox[0] + bbox[3]) / 2.0)
        x_widths.append(bbox[3] - bbox[0])
        z_centers.append((bbox[2] + bbox[5]) / 2.0)
        z_widths.append(bbox[5] - bbox[2])
        frame += 1
        if len(frames) % 100 == 0:
            _write_progress(len(frames), total_frames)

    cmds.currentTime(original_time)

    with open(cache_path, 'w') as f:
        json.dump({
            'animation_reference': anim_ref,
            'source_character_scene': cmds.file(query=True, sceneName=True),
            'start': start,
            'end': end,
            'frames': frames,
            'x_center': x_centers,
            'x_width': x_widths,
            'z_center': z_centers,
            'z_width': z_widths,
        }, f)

    _write_progress(len(frames), total_frames, note='done')
    print('Cached %d frames (%s to %s) -> %s' % (len(frames), start, end, cache_path))
    print('CLAUDE_CACHE_OK')
