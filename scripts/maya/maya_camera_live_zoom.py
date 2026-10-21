"""Applies a new zoom percentage directly to whichever d4_rom_* cameras
already exist -- no panel reopen, no bbox remeasure. Companion to
maya_camera_live_nudge.py, but zoom is absolute (the slider already holds
the running total, unlike offset's delta -- there is no separate PowerShell-
side bookkeeping needed here).

Recomputes orthoWidth from base_ortho_width (the PRE-zoom frame width
frame_camera() wrote at panel-open time -- see write_base_ortho_width),
not from the camera's current orthoWidth attribute, since re-zooming an
already-zoomed value would compound incorrectly.

Zoom changes what a screen pixel is worth in world units, so this ALSO
rewrites _camera_world_per_px.txt after recomputing orthoWidth -- offset
nudging (maya_camera_live_nudge.py) and the recenter-override fix (see
maya_key_from_cache.py's apply_recenter_override) both read that file and
would silently go stale otherwise. This is the one place that ever WRITES
it after panel-open time; nudge only ever reads it.

Reads:
    _camera_zoom_pct.txt      -- written by rom_launcher.ps1's
                                  Write-CameraZoomPct (same file Preview
                                  already uses).
    _camera_base_ortho_width.txt -- written by frame_camera()'s caller.
Writes:
    _camera_world_per_px.txt  -- kept consistent with the new zoom level.
"""
import os
import sys
import maya.cmds as cmds

SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', '..', 'd4_anim_sample')

CAMERA_SHAPES = ['d4_rom_frontShape', 'd4_rom_backShape', 'd4_rom_leftShape', 'd4_rom_rightShape']


def get_zoom_pct():
    # A/B toggle ("show automatic framing") writes a TEMPORARY override
    # here instead of touching the persisted _camera_zoom_pct.txt, so
    # toggling back restores the manual value exactly -- same reasoning as
    # offset nudging being delta-based rather than overwriting the
    # persisted file. Empty/missing override file = normal path.
    override_path = os.path.join(CACHE_DIR, '_camera_zoom_pct_override.txt')
    try:
        with open(override_path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        if content:
            return float(content)
    except (IOError, OSError, ValueError):
        pass

    path = os.path.join(CACHE_DIR, '_camera_zoom_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return float(content)
    except (IOError, OSError, ValueError):
        return 0.0


def get_base_ortho_width():
    path = os.path.join(CACHE_DIR, '_camera_base_ortho_width.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        return float(content)
    except (IOError, OSError, ValueError):
        return None


def write_world_per_px(value):
    path = os.path.join(CACHE_DIR, '_camera_world_per_px.txt')
    with open(path, 'w') as f:
        f.write('%.10f' % value)


base_ortho_width = get_base_ortho_width()
zoom_pct = get_zoom_pct()

if base_ortho_width is None:
    print('ZOOM_LIVE_SKIPPED: no base_ortho_width on record -- open panels (Preview) at least once this session before live-zooming.')
else:
    new_ortho_width = base_ortho_width * (1.0 - zoom_pct / 100.0)
    updated = []
    for shape in CAMERA_SHAPES:
        if not cmds.objExists(shape):
            continue
        cmds.setAttr(shape + '.orthographicWidth', new_ortho_width)
        updated.append(shape)

    if updated:
        # world_per_px = new_ortho_width / panel_width. panel_width itself
        # never changes during a live-tune session (only zoom/offset do),
        # so just read it straight off whichever panel window is still
        # open -- cheap (a plain query, no resize/refresh) and avoids
        # re-deriving it from other files algebraically. Window names are
        # 'claude_view_<view>' (see maya_camera_panels.py's WINDOW_NAME),
        # NOT the camera transform names -- the two are different objects.
        col_width = None
        for win in ('claude_view_front', 'claude_view_back', 'claude_view_left', 'claude_view_side'):
            if cmds.window(win, exists=True):
                col_width = cmds.window(win, query=True, widthHeight=True)[0]
                break
        if not col_width:
            # Never quietly skip this -- a stale world_per_px silently
            # breaks offset nudging's accuracy the moment zoom changes
            # (see this file's own module docstring). Loud failure instead.
            raise RuntimeError('ZOOM_LIVE_FAILED: no open claude_view_* panel window found -- cannot determine panel width to keep world_per_px in sync. Open panels (Preview) first.')
        write_world_per_px(new_ortho_width / float(col_width))
        print('ZOOM_LIVE_OK updated=%s zoom_pct=%+.0f new_ortho_width=%.4f col_width=%s' % (updated, zoom_pct, new_ortho_width, col_width))
    else:
        print('ZOOM_LIVE_SKIPPED: no d4_rom camera shapes currently exist.')
