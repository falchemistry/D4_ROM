"""Applies an incremental pixel delta directly to whichever d4_rom_* cameras
already exist -- no panel reopen, no bbox remeasure. This is the plumbing
behind the launcher's live offset controls (middle-drag scrub, arrow-key
nudge, and a typed-box commit converted to a delta): all three funnel
through this one script, sending a (delta_x_px, delta_y_px) rather than an
absolute value, so this script never needs to know the running total --
rom_launcher.ps1 owns that bookkeeping (it already has to, for the box
text/persisted file), and this script just applies whatever delta it's
handed to whatever the camera's CURRENT position already is.

Static vs keyed horizontal channel (T72, 2026-10-14): with the frame gate
OFF the camera's horizontal translate is a plain attribute, so a bare
setAttr is correct. With the gate ON the keyer has keyed that channel
across the take (translateX for front/back, translateZ for left/right),
and a bare setAttr only changes the value at the current frame -- it was
silently lost the moment anything re-evaluated the curve (scrubbing away
and back). So when the horizontal channel has animation keys, ALL of its
keys are shifted by the same amount (cmds.keyframe relative edit), which
keeps the whole curve's shape and makes the offset stick everywhere. The
vertical channel (translateY) is never keyed by this pipeline and keeps
the plain setAttr.

Reads:
    _camera_nudge_delta.txt  -- "dx,dy" in screen pixels, written by
                                 rom_launcher.ps1 right before this send.
    _camera_world_per_px.txt -- written by maya_camera_panels.py/_LR.py's
                                 frame_camera() (and kept current by
                                 maya_camera_live_zoom.py whenever zoom
                                 changes) -- the SAME ratio those scripts
                                 use, never re-derived independently here.
"""
import os
import sys
import maya.cmds as cmds

# __file__ is never defined in bridge-executed code (see maya_vscode_bridge
# memory) -- same co_filename trick every other script in this project uses.
SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', '..', 'd4_anim_sample')

# cam_transform -> which local translate letter is the tracked/horizontal
# screen axis for that camera (front/back track world X, left/right track
# world Z) -- vertical is always Y for every view in this pipeline.
CAMERAS_H_LETTER = {
    'd4_rom_front': 'X',
    'd4_rom_back': 'X',
    'd4_rom_left': 'Z',
    'd4_rom_right': 'Z',
}


def get_world_per_px():
    path = os.path.join(CACHE_DIR, '_camera_world_per_px.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return float(content)
    except (IOError, OSError, ValueError):
        return None


def get_nudge_delta():
    path = os.path.join(CACHE_DIR, '_camera_nudge_delta.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        parts = content.split(',')
        if len(parts) == 2:
            return float(parts[0]), float(parts[1])
    except (IOError, OSError, ValueError):
        pass
    return 0.0, 0.0


world_per_px = get_world_per_px()
delta_x_px, delta_y_px = get_nudge_delta()

if world_per_px is None:
    print('NUDGE_SKIPPED: no world_per_px on record -- open panels (Preview) at least once this session before nudging.')
else:
    moved = []
    for cam_transform, h_letter in CAMERAS_H_LETTER.items():
        if not cmds.objExists(cam_transform):
            continue
        h_attr = cam_transform + '.translate' + h_letter
        v_attr = cam_transform + '.translateY'
        # Same sign convention as frame_camera(): subtracting makes +X move
        # the subject right and +Y move it up.
        h_shift = -delta_x_px * world_per_px
        if cmds.keyframe(h_attr, query=True, keyframeCount=True):
            # Keyed (frame gate ON): shift every key, not just the current value.
            cmds.keyframe(h_attr, edit=True, relative=True, valueChange=h_shift)
        else:
            cmds.setAttr(h_attr, cmds.getAttr(h_attr) + h_shift)
        cmds.setAttr(v_attr, cmds.getAttr(v_attr) - delta_y_px * world_per_px)
        moved.append(cam_transform)
    print('NUDGE_OK moved=%s dx_px=%.2f dy_px=%.2f' % (moved, delta_x_px, delta_y_px))
