"""Left/right variant of maya_camera_panels.py -- same logic, VIEWS set to
the side cameras instead of front/back. Kept as a separate file rather than
a shared import since scripts here run as standalone execs over the
command port, not as an importable package.
"""
import ctypes
import hashlib
import json
import os
import sys
import maya.cmds as cmds
import maya.mel as mel

# --- configuration -----------------------------------------------------
VIEWS = ['left', 'side']        # side = right

# See maya_camera_panels.py for the full explanation and derivation. None =
# auto-derive the margin so the frame contains the subject's widest pose
# (max_w in the bbox cache) EVEN AT full edge_guard drift tolerance, plus
# MARGIN_SAFETY headroom.
MARGIN_PX = None
MARGIN_PX_MIN = 30
MARGIN_PX_MAX = 260
MARGIN_SAFETY = 1.02

# Edge-guard's own drift-tolerance threshold -- MUST match EDGE_OVERFLOW_PCT
# in maya_key_from_cache_LR.py, and the frame-sizing formula below is only
# correct if the two stay in sync. See maya_camera_panels.py's copy of this
# constant for the full derivation and the 8%->2% rationale.
EDGE_OVERFLOW_PCT = 0.02
# 'x' so the side views use the SAME frame width as the front/back pair --
# the character then appears at identical scale across both videos. Driving
# it off 'z' (the narrow side profile) would frame each side view tighter,
# but the character would look noticeably bigger than in the front/back
# video, which is jarring when reviewing them together.
AUTO_MARGIN_AXIS = 'x'

# Magnifier: user-adjustable +/-50% zoom on top of the safe default above.
# See maya_camera_panels.py's get_zoom_pct() for the full explanation.
ZOOM_PCT = 0.0
ZOOM_PCT_MIN = -50.0
ZOOM_PCT_MAX = 50.0

# Manual pixel-space nudge. Shared _camera_offset_px.txt file with
# maya_camera_panels.py (same convention as the shared zoom file) -- see
# that file's get_pixel_offset() for the full explanation.
OFFSET_X_PX = 0.0
OFFSET_Y_PX = 0.0

# Recenter at start frame. See maya_camera_panels.py's
# get_recenter_start_frame() for the full explanation.

ALL_KNOWN_VIEWS = ['front', 'back', 'side', 'left']
TITLE_OVERRIDES = {'side': 'Right'}  # Maya calls the right-side camera 'side'
WINDOW_NAME = {v: 'claude_view_' + v for v in ALL_KNOWN_VIEWS}

# Fallback secondary monitor bounds (Windows virtual-desktop pixels), used
# only if _recording_monitor_rect.txt (below) doesn't exist yet -- e.g.
# the very first run before the launcher's Recording Monitor dropdown has
# ever written one. Regenerate with:
#   Add-Type -AssemblyName System.Windows.Forms
#   [System.Windows.Forms.Screen]::AllScreens
# if the monitor layout ever changes.
SECONDARY_MONITOR_RECT = (1920, 0, 3840, 1080)  # left, top, right, bottom

CAMERA_NODE_NAME = {             # dedicated d4_rom_<position> cameras --
    'front': 'd4_rom_front',     # decoupled from Maya's built-in front/side
    'side': 'd4_rom_right',      # so nothing else in the scene can collide
    'back': 'd4_rom_back',       # with or repurpose them. 'side' is Maya's
    'left': 'd4_rom_left',       # name for the built-in right-view camera.
}
BASE_SOURCE = {                  # bootstrap: copy orientation as-is from
    'front': 'front',            # Maya's built-in camera of the same name,
    'side': 'side',               # one time, when the d4_rom_ camera doesn't exist yet
}
MIRROR_SOURCE = {'back': 'front', 'left': 'side'}  # 180-degree flip of another view
VIEW_AXES = {                   # (horizontal world axis, vertical world axis)
    'front': ('x', 'y'),
    'back': ('x', 'y'),
    'side': ('z', 'y'),
    'left': ('z', 'y'),
}
AXIS_BBOX_INDEX = {'x': (0, 3), 'y': (1, 4), 'z': (2, 5)}
AXIS_POS = {'x': 0, 'y': 1, 'z': 2}


SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', '..', 'd4_anim_sample')


def get_secondary_monitor_rect():
    # Reads the same rect rom_launcher.ps1's Recording Monitor dropdown
    # just wrote (see Write-RecordingMonitorRect) -- keeps the panels'
    # spawn location in sync with whichever monitor OBS is actually set
    # to record, instead of a hardcoded constant independent of that
    # setting (a real gap: switching monitors in the launcher used to
    # move what OBS records but not where these panels appeared, silently
    # recording the wrong screen). Falls back to the hardcoded constant
    # if the file doesn't exist yet or is malformed, so this still works
    # standalone (e.g. run directly, without ever having opened the
    # launcher).
    rect_path = os.path.join(CACHE_DIR, '_recording_monitor_rect.txt')
    try:
        with open(rect_path) as f:
            content = f.read()
        # Belt-and-suspenders: the writer (rom_launcher.ps1) is fixed to
        # never emit a byte-order mark, but this strips one anyway if a
        # future change or a hand-edit ever reintroduces one -- confirmed
        # the hard way (2026-08-21) that a leading BOM makes int() raise
        # ValueError on the first number, silently falling through to the
        # hardcoded fallback below with zero visible error, which is
        # exactly what made switching monitors look like it wasn't
        # working at all. chr(0xFEFF), not a literal/escaped char in this
        # source file, to keep this file plain ASCII (an em-dash caused a
        # UnicodeDecodeError in Maya once before -- same class of risk).
        content = content.lstrip(chr(0xFEFF))
        parts = [int(p.strip()) for p in content.strip().split(',')]
        if len(parts) == 4:
            return tuple(parts)
    except (IOError, OSError, ValueError):
        pass
    return SECONDARY_MONITOR_RECT


def get_zoom_pct():
    """See maya_camera_panels.py for the full explanation. Same
    _camera_zoom_pct.txt file, shared with the front/back panel script, so
    the magnifier setting applies identically to both view pairs."""
    path = os.path.join(CACHE_DIR, '_camera_zoom_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        value = float(content)
        return max(ZOOM_PCT_MIN, min(ZOOM_PCT_MAX, value))
    except (IOError, OSError, ValueError):
        return ZOOM_PCT


def get_manual_tolerance_pct():
    """See maya_camera_panels.py for the full explanation. Same shared
    _camera_tolerance_pct.txt file as the front/back panel script."""
    path = os.path.join(CACHE_DIR, '_camera_tolerance_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        if not content:
            return None
        return float(content)
    except (IOError, OSError, ValueError):
        return None


def get_pixel_offset():
    """See maya_camera_panels.py for the full explanation. Same shared
    _camera_offset_px.txt file as the front/back panel script."""
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


def get_recenter_start_frame():
    """See maya_camera_panels.py for the full explanation. Same shared
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


# --- automatic margin ------------------------------------------------------
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


def load_cache():
    path = cache_path_for(find_animation_reference())
    if not os.path.exists(path):
        print('No bbox cache for this animation -- sampling now (one time, several minutes)...')
        cache_script = os.path.join(SCRIPT_DIR, 'maya_cache_bbox.py')
        exec(compile(open(cache_script).read(), cache_script, 'exec'), {})
    if not os.path.exists(path):
        # Same fix and reasoning as maya_key_from_cache.py's own copy of
        # this check (2026-08-22 design: never quietly continue into a
        # broken recording). See maya_camera_panels.py's own copy of this
        # for the full comment. Marker lives in the raised exception's
        # message, not a separate print() -- print() never relays through
        # Maya's command port, so the print()+raise split left this
        # detection dead on the PowerShell side.
        raise RuntimeError('CAPTURE_ABORT: no cache could be built for this animation -- check that the ROM animation reference is actually loaded and keyed in this scene, then try again.')
    with open(path) as f:
        return json.load(f)


def compute_effective_world_h(world_h, cache):
    """See maya_camera_panels.py for the full explanation and the
    algebra-verified reason this MUST be called with the same value
    compute_margin_px used, and passed into frame_camera's
    world_h_override -- using two different heights for the two halves of
    the same formula silently narrows orthoWidth instead of widening it."""
    cached_heights = cache.get('heights')
    if cached_heights:
        return max(world_h, max(cached_heights) * MARGIN_SAFETY)
    return world_h


def compute_margin_px(world_h, panel_w, panel_h):
    """See maya_camera_panels.py for the derivation. world_h should
    already be the WIDENED value from compute_effective_world_h. Returns
    (margin, max_w, needed_ortho) -- see that file's own copy of this
    function for why the caller needs max_w/needed_ortho too."""
    cache = load_cache()
    max_w = max(cache[AUTO_MARGIN_AXIS + '_width'])
    needed_ortho = (max_w / (1.0 - 2.0 * EDGE_OVERFLOW_PCT)) * MARGIN_SAFETY

    if MARGIN_PX is not None:
        return int(MARGIN_PX), max_w, needed_ortho

    margin = (panel_h - (world_h * float(panel_w) / needed_ortho)) / 2.0
    margin = int(round(max(MARGIN_PX_MIN, min(margin, MARGIN_PX_MAX))))

    print('Auto margin: widest %s-span=%.1f, drift tol=%.0f%% -> orthoWidth=%.1f -> margin=%dpx '
          '(character fills %d of %d px)'
          % (AUTO_MARGIN_AXIS, max_w, EDGE_OVERFLOW_PCT * 100, needed_ortho,
             margin, panel_h - 2 * margin, panel_h))
    return margin, max_w, needed_ortho


def compute_effective_overflow_pct(max_w, needed_ortho, zoom_pct, offset_x_px, panel_width, manual_pct=None):
    """See maya_camera_panels.py for the full derivation. BUG FIXED
    2026-09-08: now also accounts for the pixel offset eating into margin
    asymmetrically -- see that file's copy for the full writeup. Manual
    override (2026-09-29): see that file's copy for the full explanation --
    identical here, manual_pct bypasses the formula and its zero floor
    entirely when not None."""
    if manual_pct is not None:
        return manual_pct / 100.0
    final_ortho = needed_ortho * (1.0 - zoom_pct / 100.0)
    if final_ortho <= 0:
        return 0.0
    effective = (1.0 - (max_w * MARGIN_SAFETY / final_ortho)) / 2.0
    world_per_px = final_ortho / float(panel_width)
    offset_world = abs(offset_x_px) * world_per_px
    effective -= offset_world / final_ortho
    return max(0.0, effective)


def write_effective_overflow_pct(value):
    path = os.path.join(CACHE_DIR, '_camera_effective_overflow_pct.txt')
    with open(path, 'w') as f:
        f.write('%.6f' % value)


def write_world_per_px(value):
    # Hand-off to maya_key_from_cache_LR.py's apply_recenter_override --
    # see maya_camera_panels.py's own copy of this function for the full
    # explanation (the bug this fixes is identical here, tracked axis 'z'
    # instead of 'x').
    path = os.path.join(CACHE_DIR, '_camera_world_per_px.txt')
    with open(path, 'w') as f:
        f.write('%.10f' % value)


def write_base_ortho_width(value):
    # See maya_camera_panels.py's own copy for the full explanation. Same
    # shared _camera_base_ortho_width.txt file.
    path = os.path.join(CACHE_DIR, '_camera_base_ortho_width.txt')
    with open(path, 'w') as f:
        f.write('%.10f' % value)


def write_capture_panel_names(panel_names):
    # See maya_camera_panels.py's own copy for the full explanation. Same
    # shared _capture_panels.txt file -- only whichever leg (front/back or
    # left/right) is currently open ever has panels in it, since
    # close_all_view_panels() always tears down every known window first.
    path = os.path.join(CACHE_DIR, '_capture_panels.txt')
    with open(path, 'w') as f:
        f.write('\n'.join(panel_names))


def view_title(view_name):
    return TITLE_OVERRIDES.get(view_name, view_name.title()) + ' View'


# --- camera setup --------------------------------------------------------
def ensure_camera(view_name):
    node_name = CAMERA_NODE_NAME[view_name]
    if cmds.objExists(node_name):
        return node_name

    if view_name in BASE_SOURCE:
        # bootstrap copy: same orientation as Maya's built-in camera
        source_node = BASE_SOURCE[view_name]
        flip = False
    else:
        source_view = MIRROR_SOURCE[view_name]
        source_node = ensure_camera(source_view)  # recursively ensure it exists
        flip = True

    if not cmds.objExists(source_node):
        raise RuntimeError('Do not know how to create camera for view "%s".' % view_name)

    src_rot = cmds.getAttr(source_node + '.rotate')[0]
    src_trans = cmds.getAttr(source_node + '.translate')[0]
    src_shape = cmds.listRelatives(source_node, shapes=True)[0]
    ortho_width = cmds.getAttr(src_shape + '.orthographicWidth')

    transform, shape = cmds.camera(name=node_name)
    if transform != node_name:
        # cmds.camera() always number-suffixes its result regardless of
        # collision -- force the exact name via rename instead.
        transform = cmds.rename(transform, node_name)
        shape = cmds.listRelatives(transform, shapes=True)[0]

    if flip:
        cmds.setAttr(transform + '.rotate', src_rot[0], src_rot[1] + 180, src_rot[2], type='double3')
        cmds.setAttr(transform + '.translate', -src_trans[0], -src_trans[1], -src_trans[2], type='double3')
    else:
        cmds.setAttr(transform + '.rotate', src_rot[0], src_rot[1], src_rot[2], type='double3')
        cmds.setAttr(transform + '.translate', src_trans[0], src_trans[1], src_trans[2], type='double3')

    cmds.setAttr(shape + '.orthographic', 1)
    cmds.setAttr(shape + '.orthographicWidth', ortho_width)
    cmds.setAttr(shape + '.nearClipPlane', 0.01)
    cmds.setAttr(shape + '.farClipPlane', 1000000)
    return transform


# --- framing ---------------------------------------------------------------
def get_target_bbox():
    sel = cmds.ls(selection=True, long=True)
    if not sel:
        # Only visible mesh shapes -- excludes hidden geometry (e.g. a head
        # you've toggled off) and non-mesh rig clutter (curves, locators,
        # IK gizmos). Also skip weapon/shield "Proxy" placeholder meshes,
        # which otherwise silently inflate the frame beyond the body.
        shapes = cmds.ls(type='mesh', noIntermediate=True, visible=True, long=True) or []
        transforms = cmds.listRelatives(shapes, parent=True, fullPath=True) or []
        sel = list(set(t for t in transforms if 'proxy' not in t.lower()))
    if not sel:
        raise RuntimeError('Nothing to frame: select an object, or add visible geometry to the scene.')
    return cmds.exactWorldBoundingBox(sel)


def frame_camera(view_name, cam_transform, panel_width, panel_height, bbox, margin_px, zoom_pct=0.0, offset_x_px=0.0, offset_y_px=0.0, world_h_override=None):
    h_axis, v_axis = VIEW_AXES[view_name]
    hmin, hmax = AXIS_BBOX_INDEX[h_axis]
    vmin, vmax = AXIS_BBOX_INDEX[v_axis]

    # See maya_camera_panels.py's own copy of this function for why
    # world_h_override must match compute_effective_world_h exactly.
    world_h = world_h_override if world_h_override is not None else (bbox[vmax] - bbox[vmin])
    center_h = (bbox[hmax] + bbox[hmin]) / 2.0
    center_v = (bbox[vmax] + bbox[vmin]) / 2.0

    usable_px = max(panel_height - 2 * margin_px, 1)
    view_height_world = world_h * (panel_height / float(usable_px))
    # base_ortho_width: see maya_camera_panels.py's own copy for why this
    # needs to be its own variable (maya_camera_live_zoom.py reuses it).
    base_ortho_width = view_height_world * (panel_width / float(panel_height))
    ortho_width = base_ortho_width * (1.0 - zoom_pct / 100.0)

    # See maya_camera_panels.py's own copy of this for the full derivation.
    world_per_px = ortho_width / float(panel_width)
    center_h -= offset_x_px * world_per_px
    center_v -= offset_y_px * world_per_px

    shape = cmds.listRelatives(cam_transform, shapes=True)[0]
    cmds.setAttr(shape + '.orthographicWidth', ortho_width)
    # Leave film aperture at Maya's defaults -- overriding it to match the
    # panel aspect (an earlier "fix") actually broke framing; orthoWidth
    # alone is sufficient for correct viewport fitting.

    trans = list(cmds.getAttr(cam_transform + '.translate')[0])
    trans[AXIS_POS[h_axis]] = center_h
    trans[AXIS_POS[v_axis]] = center_v
    cmds.setAttr(cam_transform + '.translate', trans[0], trans[1], trans[2], type='double3')
    return world_per_px, base_ortho_width


def apply_mesh_only_display(panel):
    cmds.modelEditor(panel, edit=True, allObjects=False)
    cmds.modelEditor(panel, edit=True,
                      polymeshes=True,
                      grid=False,
                      displayAppearance='smoothShaded',
                      displayTextures=True,
                      wireframeOnShaded=False,
                      selectionHiliteDisplay=False,
                      # Off, not left at whatever the artist's own viewport
                      # prefs happen to be -- poly count and other HUD text
                      # burned into a ROM capture video looks unprofessional
                      # and isn't something the recording can fix after the
                      # fact.
                      headsUpDisplay=False,
                      # Backface culling on this capture panel only (viewport
                      # display flag, not a scene/mesh edit) -- requested so
                      # back-facing geometry never renders into the ROM
                      # capture video. Reversible, panel-scoped, matches every
                      # other display flag on this same call.
                      backfaceCulling=True,
                      rendererName='vp2Renderer')


def enable_vp2_quality():
    # Same underlying node the Shift+M / Viewport 2.0 preferences toggles hit.
    if cmds.objExists('hardwareRenderingGlobals'):
        cmds.setAttr('hardwareRenderingGlobals.multiSampleEnable', 1)
        cmds.setAttr('hardwareRenderingGlobals.ssaoEnable', 1)


def make_borderless_fullsize(title, x, y, w, h):
    """Strip the title bar/border and force the window to exactly fill the
    given rect. Maya's cmds.window() clamps its own height (a 1080-request
    lands at ~1000), which leaves a dead strip of desktop at the bottom of
    the capture -- and the title bar would show up in the recording too.
    Must run BEFORE the panel is measured for framing, so orthographicWidth
    is computed against the final panel size.

    Also brings the window to the front (see bring_window_to_front) --
    these panels commonly live on a second monitor the artist isn't
    actively looking at, so a run that gets buried under something else
    open on that monitor previously gave no visual cue at all that it had
    even started.

    Only plain ctypes function calls here, no ctypes.Structure subclasses --
    class bodies can't see module-level imports under the command port's
    exec model (see maya_vscode_bridge notes)."""
    user32 = ctypes.windll.user32
    GWL_STYLE = -16
    WS_CAPTION = 0x00C00000
    WS_THICKFRAME = 0x00040000
    SWP_NOZORDER = 0x0004
    SWP_FRAMECHANGED = 0x0020

    hwnd = user32.FindWindowW(None, title)
    if not hwnd:
        return False
    get_long = getattr(user32, 'GetWindowLongPtrW', user32.GetWindowLongW)
    set_long = getattr(user32, 'SetWindowLongPtrW', user32.SetWindowLongW)
    style = get_long(hwnd, GWL_STYLE)
    set_long(hwnd, GWL_STYLE, style & ~WS_CAPTION & ~WS_THICKFRAME)
    user32.SetWindowPos(hwnd, 0, x, y, w, h, SWP_NOZORDER | SWP_FRAMECHANGED)
    bring_window_to_front(hwnd)
    return True


def bring_window_to_front(hwnd):
    """Flashes the window to the top of the z-order once, the standard
    "topmost then not-topmost" idiom: SetWindowPos with HWND_TOPMOST
    followed immediately by HWND_NOTOPMOST moves the window to the front
    and releases it there, rather than pinning it permanently above
    everything else (which would be its own annoyance, floating over
    whatever the artist opens on that monitor next). This is a pure
    z-order operation any process can do to its own windows -- no
    permission Windows can silently deny the way it sometimes blocks
    SetForegroundWindow from a background process, which is attempted
    afterward as a bonus, best-effort step only."""
    user32 = ctypes.windll.user32
    HWND_TOPMOST = -1
    HWND_NOTOPMOST = -2
    SWP_NOMOVE = 0x0002
    SWP_NOSIZE = 0x0001
    SWP_SHOWWINDOW = 0x0040
    flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW
    user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags)
    user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags)
    try:
        user32.SetForegroundWindow(hwnd)
    except Exception:
        pass


def hide_model_editor_bars():
    # Same MEL proc Ctrl+Shift+M calls (ToggleModelEditorBars runtime command).
    # It's a global toggle across every model panel, not a per-panel flag.
    mel.eval('toggleModelEditorBarsInAllPanels(1)')


def close_all_view_panels():
    # Close by our fixed object name first -- reliable regardless of title,
    # and covers every known view even if it's not in this run's VIEWS.
    for v in ALL_KNOWN_VIEWS:
        wname = WINDOW_NAME[v]
        if cmds.window(wname, exists=True):
            cmds.deleteUI(wname)

    # Sweep any leftovers by title too, in case a past run (e.g. before this
    # naming scheme, or one that errored mid-way) left an orphaned window
    # under a Maya-generated name. Leaving these around is what previously
    # let torn-off panels/model editors accumulate across repeated runs.
    known_titles = set(view_title(v) for v in ALL_KNOWN_VIEWS)
    for old_win in cmds.lsUI(windows=True) or []:
        if cmds.window(old_win, query=True, title=True) in known_titles:
            cmds.deleteUI(old_win)


# --- panel windows -----------------------------------------------------
def open_view_panels():
    mon_left, mon_top, mon_right, mon_bottom = get_secondary_monitor_rect()
    mon_width = mon_right - mon_left
    mon_height = mon_bottom - mon_top
    col_width = mon_width // len(VIEWS)

    enable_vp2_quality()
    hide_model_editor_bars()

    cmds.select(clear=True)  # avoid framing a stray selection (cmds.camera() also auto-selects)

    # Recenter at start frame -- see maya_camera_panels.py's own copy of
    # this for the full explanation. Deliberately NOT restored afterward
    # (2026-09-02 revision): the point is for Preview to actually show the
    # artist their capture's starting pose.
    recenter_frame = get_recenter_start_frame()
    if recenter_frame is not None:
        cmds.currentTime(recenter_frame)
        print('Recenter at start frame: showing frame %s' % recenter_frame)
    bbox = get_target_bbox()

    # Panels are forced to exactly col_width x mon_height below, so the
    # margin can be derived up front from those dimensions.
    world_h = compute_effective_world_h(bbox[4] - bbox[1], load_cache())
    margin_px, max_w, needed_ortho = compute_margin_px(world_h, col_width, mon_height)
    zoom_pct = get_zoom_pct()
    if zoom_pct:
        print('Magnifier: %+.0f%%' % zoom_pct)
    offset_x_px, offset_y_px = get_pixel_offset()
    if offset_x_px or offset_y_px:
        print('Pixel offset: X=%+.0f Y=%+.0f' % (offset_x_px, offset_y_px))

    # offset_x_px=0.0 here, NOT the real offset -- see maya_camera_panels.py's
    # own copy of this call for the full explanation (G, 2026-09-28): the
    # guard tolerance handed to the keyer is zoom-only now.
    # Manual tolerance override (2026-09-29) -- see maya_camera_panels.py's
    # own copy of this call for the full explanation.
    manual_tolerance_pct = get_manual_tolerance_pct()
    effective_overflow_pct = compute_effective_overflow_pct(max_w, needed_ortho, zoom_pct, 0.0, col_width, manual_tolerance_pct)
    write_effective_overflow_pct(effective_overflow_pct)
    if manual_tolerance_pct is not None:
        print('Manual tolerance override: %.2f%% (auto would have been %.2f%%)' % (effective_overflow_pct * 100, compute_effective_overflow_pct(max_w, needed_ortho, zoom_pct, 0.0, col_width) * 100))
    elif abs(effective_overflow_pct - EDGE_OVERFLOW_PCT) > 1e-6:
        print('Effective drift tolerance at this zoom/offset: %.2f%% (base %.2f%%)' % (effective_overflow_pct * 100, EDGE_OVERFLOW_PCT * 100))
    if effective_overflow_pct <= 1e-6:
        print('WARNING: zero drift tolerance in effect -- a pose wider than the frame will clip regardless of tracking. Reduce zoom-in, or raise the manual Tolerance value, if clipping is visible.')

    close_all_view_panels()

    panel_names = []
    for i, view_name in enumerate(VIEWS):
        cam = ensure_camera(view_name)

        left = mon_left + i * col_width
        win = cmds.window(WINDOW_NAME[view_name],
                           title=view_title(view_name),
                           topLeftCorner=(mon_top, left),
                           widthHeight=(col_width, mon_height))
        form = cmds.formLayout()
        panel = cmds.modelPanel(camera=cam, menuBarVisible=False, parent=form)
        cmds.formLayout(form, edit=True, attachForm=[
            (panel, 'top', 0), (panel, 'bottom', 0),
            (panel, 'left', 0), (panel, 'right', 0),
        ])
        cmds.showWindow(win)
        cmds.refresh(force=True)
        # menuBarVisible at creation time is unreliable for floating panels;
        # re-apply as an edit (same effect as the Shift+M panel shortcut).
        cmds.modelPanel(panel, edit=True, menuBarVisible=False)

        # Force exact full-monitor size before measuring, so framing is
        # computed against the real final panel dimensions.
        make_borderless_fullsize(view_title(view_name), left, mon_top, col_width, mon_height)
        cmds.refresh(force=True)

        apply_mesh_only_display(panel)
        panel_names.append(panel)

        panel_w = cmds.control(panel, query=True, width=True)
        panel_h = cmds.control(panel, query=True, height=True)
        computed_world_per_px, computed_base_ortho_width = frame_camera(view_name, cam, panel_w, panel_h, bbox, margin_px, zoom_pct, offset_x_px, offset_y_px, world_h)

    write_world_per_px(computed_world_per_px)
    write_base_ortho_width(computed_base_ortho_width)
    write_capture_panel_names(panel_names)
    cmds.refresh(force=True)


# Suspended for the whole setup -- see maya_camera_panels.py's own copy
# for the full explanation (identical fix here).
cmds.refresh(suspend=True)
try:
    open_view_panels()
except Exception:
    # hide_model_editor_bars() runs first inside open_view_panels() and is a
    # GLOBAL toggle across every model panel in the scene, not just these
    # capture panels (see maya_clean_reset.py's comment on
    # toggleModelEditorBarsInAllPanels). If anything after it fails --
    # confirmed live: a scene with no animation raising CAPTURE_ABORT out of
    # load_cache() -- the user's own main viewport was left with its icon
    # toolbar hidden and no visual cue why, since the trailing reset step
    # never runs on an aborted capture. Restore it here before the
    # exception propagates. collapse=0 on an already-expanded frameLayout
    # is a no-op, so this is safe even if hide_model_editor_bars() never
    # got to run.
    mel.eval('toggleModelEditorBarsInAllPanels(0)')
    raise
finally:
    cmds.refresh(suspend=False)
print('VIEW_PANELS_OK')
