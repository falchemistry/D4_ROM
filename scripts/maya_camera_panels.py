"""Open orthographic camera views as floating panels, tiled side by side on
the secondary monitor, each framed on the model with a top/bottom margin.
Uses dedicated d4_rom_<position> cameras, bootstrapped once from Maya's
built-in front/side cameras and never touching them again.

Extend later by adding 'side' (right view) and/or 'left' to VIEWS below --
both already have mirror rules defined.
"""
import ctypes
import hashlib
import json
import os
import sys
import maya.cmds as cmds
import maya.mel as mel

# --- configuration -----------------------------------------------------
VIEWS = ['front', 'back']       # any of: front, back, side (=right), left

# MARGIN_PX = None  -> derive the top/bottom margin automatically so the
#                      frame is sized directly from the subject's true
#                      widest pose across the whole animation (max_w in the
#                      bbox cache), PLUS enough extra room for edge_guard's
#                      own drift tolerance (EDGE_OVERFLOW_PCT below). Set an
#                      int to override.
#
# Design (2026-09-02, revised): a frame sized for max_w ALONE is not
# actually clip-proof -- edge_guard is reactive (see maya_key_from_cache.py),
# so it lets the subject drift up to EDGE_OVERFLOW_PCT of the frame width
# before it reacts at all. If a max-width pose happens to coincide with
# near-max drift, the two combine and the subject still clips, even though
# the frame is "wide enough" for the pose alone -- confirmed live against
# palM_rom_anim's real cache (width-only sizing: 582 clipped frames, worst
# clip 19.2 units = 8% of orthoWidth, exactly EDGE_OVERFLOW_PCT -- not a
# coincidence, see the derivation below).
#
# EDGE_OVERFLOW_PCT is therefore back in this formula (previously decoupled
# entirely -- that was wrong; the two constants have a real mathematical
# relationship). The worst case is: subject drifted to the edge of
# tolerance (overflow_pct * orthoWidth) AND simultaneously at max_w width.
# For that to still fit inside the frame:
#     overflow_pct * orthoWidth + max_w/2 <= orthoWidth/2
#     orthoWidth >= max_w / (1 - 2*overflow_pct)
# (Note the MINUS, unlike the pre-redesign formula's PLUS -- that older
# version deliberately UNDERSIZED the frame below max_w, relying entirely
# on panning to compensate; this sizes ABOVE max_w, with panning only
# handling drift, not pose width.) This still can't reach exactly zero
# clipping -- by construction, edge_guard only reacts once overflow_pct is
# exceeded, so a residual clip of up to overflow_pct * orthoWidth is
# structurally unavoidable with any reactive tolerance. What this DOES fix
# is the SEVERITY: with EDGE_OVERFLOW_PCT lowered to 2% (see below), worst
# case drops to ~5.0 units on palM (a fingertip, not a hand) instead of
# 22.8 units, while only widening the frame by ~4%.
MARGIN_PX = None
MARGIN_PX_MIN = 30              # floor, so framing never goes edge-to-edge
MARGIN_PX_MAX = 260             # ceiling, so a freak-wide pose can't zoom way out
MARGIN_SAFETY = 1.02            # 2% extra frame width over exact break-even

# Edge-guard's own drift-tolerance threshold (see maya_key_from_cache.py's
# key_edge_guard) -- MUST match EDGE_OVERFLOW_PCT there, the formula above
# is only correct if the two stay in sync. Lowered from 0.08 to 0.02
# (2026-09-02): at 8%, a max-width pose combined with max drift could clip
# by up to 8% of the frame width (a visibly obvious hand poking
# off-screen, user-reported); at 2%, the same worst case drops to ~2% of
# frame width, at the tradeoff of somewhat more frequent (but still small,
# nudge-sized) camera corrections -- validated against palM's real cache:
# 88 nudges across 3241 frames (~1 every 37 frames) vs 11 at 8%. 2% chosen
# over an even tighter 1% (130 nudges, ~1 every 25 frames) to keep
# corrections less frequent, at the cost of a somewhat larger (though
# still small) worst-case residual clip -- 5.0 units vs 2.4.
EDGE_OVERFLOW_PCT = 0.02
AUTO_MARGIN_AXIS = 'x'          # cache axis this view pair pans along

# Magnifier: user-adjustable +/-50% zoom on top of the safe default above.
# Positive = zoom in (narrower orthoWidth, character bigger); negative =
# zoom out (wider orthoWidth, more headroom). ZOOM_PCT is only the fallback
# used before the launcher's magnifier control has ever written a value --
# see get_zoom_pct().
ZOOM_PCT = 0.0
ZOOM_PCT_MIN = -50.0
ZOOM_PCT_MAX = 50.0

# Manual pixel-space nudge on top of everything above -- for a short
# Start/End or Time Slider capture where the automatic framing (anchored to
# the FULL animation's bbox) doesn't happen to center that particular
# sub-range. OFFSET_X_PX/OFFSET_Y_PX are only the fallback used before the
# launcher's Offset boxes have ever written a value -- see
# get_pixel_offset(). Positive X shifts the framing so the subject appears
# further right on screen; positive Y shifts it further up.
OFFSET_X_PX = 0.0
OFFSET_Y_PX = 0.0

# Recenter at start frame: when set (a frame number, via the launcher's
# checkbox), bbox is measured at THAT frame instead of whatever frame
# happens to be current when this script runs -- see get_recenter_start_frame().
# Fixes off-center framing on a short capture whose Start value differs from
# wherever the artist last left the timeline (the Range Slider's own
# min/max is independent of the current-time cursor in Maya).

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
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', 'd4_anim_sample')


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
    """Reads the magnifier value rom_launcher.ps1's zoom slider last wrote
    (see Write-CameraZoomPct), the same file-based hand-off pattern as
    get_secondary_monitor_rect() above. Falls back to ZOOM_PCT if the file
    doesn't exist yet (e.g. before the launcher's magnifier control has
    ever been touched) or is malformed, so this still works standalone."""
    path = os.path.join(CACHE_DIR, '_camera_zoom_pct.txt')
    try:
        with open(path) as f:
            content = f.read().lstrip(chr(0xFEFF)).strip()
        value = float(content)
        return max(ZOOM_PCT_MIN, min(ZOOM_PCT_MAX, value))
    except (IOError, OSError, ValueError):
        return ZOOM_PCT


def get_manual_tolerance_pct():
    """Reads the 'Tolerance' box's typed override (see rom_launcher.ps1's
    Write-CameraTolerancePct) -- a number in percent, or None for Auto
    (empty file, missing file, or malformed content -- 'unknown' must
    default to Auto/today's zoom-derived formula, never a guessed number,
    same convention as get_zoom_pct/get_frame_gate_enabled). Not re-clamped
    here: Commit-ToleranceValueBox already clamps to 0-20 before writing,
    so a value that reaches this file is already valid -- re-clamping here
    would only mask a real bug in the writer, not add real protection."""
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
    """Reads the X/Y pixel offset rom_launcher.ps1's Offset boxes last
    wrote (see Write-CameraOffsetPx) as a single 'X,Y' line -- same
    file-based hand-off pattern as get_zoom_pct(). Falls back to
    (OFFSET_X_PX, OFFSET_Y_PX) if the file doesn't exist yet or is
    malformed."""
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
    """Reads the frame number rom_launcher.ps1 wrote for 'Recenter at start
    frame' (see Write-RecenterStartFrame) -- the capture range's resolved
    Start value (Time Slider min, typed Start/End, or the full animation's
    start), NOT necessarily wherever Maya's current-time cursor happens to
    be. Returns None (disabled -- use whatever frame is current, the
    original behavior) if the file is empty, missing, or malformed; this is
    the deliberate "off" state Clear-RecenterStartFrame writes when the
    launcher's checkbox is unchecked, not just an error fallback."""
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
    """Load the bbox cache for this scene's animation, building it first if
    it doesn't exist yet (one-time, several minutes)."""
    path = cache_path_for(find_animation_reference())
    if not os.path.exists(path):
        print('No bbox cache for this animation -- sampling now (one time, several minutes)...')
        cache_script = os.path.join(SCRIPT_DIR, 'maya_cache_bbox.py')
        exec(compile(open(cache_script).read(), cache_script, 'exec'), {})
    if not os.path.exists(path):
        # Same fix and reasoning as maya_key_from_cache.py's own copy of
        # this check (2026-08-22 design: never quietly continue into a
        # broken recording). The build attempt above can finish without
        # writing a cache (no real animation curves, or bbox motion below
        # the no-motion threshold -- see maya_cache_bbox.py's own printed
        # reason just above this) -- confirmed live this was reachable
        # here too, not just from maya_key_from_cache.py.
        # Marker lives in the raised exception's message, not a separate
        # print() -- print() never relays through Maya's command port, so
        # the print()+raise split left this detection dead on the
        # PowerShell side. See maya_key_from_cache.py for the full story.
        raise RuntimeError('CAPTURE_ABORT: no cache could be built for this animation -- check that the ROM animation reference is actually loaded and keyed in this scene, then try again.')
    with open(path) as f:
        return json.load(f)


def compute_effective_world_h(world_h, cache):
    """Widens world_h to the cache's own max height when that's taller --
    there is no vertical equivalent of edge_guard's horizontal panning, so
    a single frame's live-measured height was never protected by a
    whole-animation guarantee the way max_w is. Design (2026-09-02):
    confirmed real on palM_rom_anim (a clean, integer-frame-only sweep --
    an earlier check using fractional sample points found what looked
    like a severe glitch, but that turned out to be an artifact of
    evaluating animation curves AT a non-keyed time, not a real risk;
    capture/recenter always land on real, integer frames) -- height
    varies ~11% across the animation (226 baseline vs 253 at a
    raised-arms pose), so sizing off a short-pose frame risked the same
    class of vertical clipping the max_w fix already prevents
    horizontally. Falls back to plain world_h for a cache built before
    this field existed (`heights` missing) -- old caches need a Force
    Rebuild to pick this up, not a silent KeyError.

    MUST be called with the SAME value compute_margin_px used to derive
    margin_px, and the result passed into frame_camera's world_h_override
    -- margin_px and the final orthoWidth are two halves of one formula
    (orthoWidth = world_h * panel_w / (panel_h - 2*margin)), so using a
    narrower world_h in one half than the other silently produces an
    orthoWidth NARROWER than intended instead of wider (confirmed by
    working through the algebra before shipping this -- not obvious from
    either half in isolation)."""
    cached_heights = cache.get('heights')
    if cached_heights:
        return max(world_h, max(cached_heights) * MARGIN_SAFETY)
    return world_h


def compute_margin_px(world_h, panel_w, panel_h):
    """Top/bottom margin sized so the frame contains the subject's widest
    pose (max_w in the bbox cache) EVEN AT full edge_guard drift tolerance,
    plus MARGIN_SAFETY headroom -- see the module-level comment above
    EDGE_OVERFLOW_PCT for the derivation. world_h should already be the
    WIDENED value from compute_effective_world_h, not a raw live
    measurement -- see that function's docstring for why.

    Framing ties orthoWidth to the margin via
                   orthoWidth = world_h * panel_w / (panel_h - 2*margin)
    which rearranges to the margin below.

    Returns (margin, max_w, needed_ortho) -- the caller also needs max_w
    and needed_ortho to work out how much of this margin the magnifier's
    zoom eats into (see compute_effective_overflow_pct)."""
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
    """The magnifier multiplies the final orthoWidth AFTER compute_margin_px
    has already sized the frame assuming zero zoom -- zooming in narrows
    the frame below what compute_margin_px promised, silently eating into
    (or entirely consuming) the drift-tolerance headroom EDGE_OVERFLOW_PCT
    was sized around. A fixed EDGE_OVERFLOW_PCT then becomes wrong at
    nonzero zoom: at +10% zoom with the shipped 2% tolerance and 2%
    MARGIN_SAFETY, the frame narrows to LESS than max_w alone, before any
    drift at all -- confirmed by this same formula going negative there.

    Re-derives the tolerance that's actually consistent with the ZOOMED
    frame, so edge_guard reacts to drift more eagerly exactly when zoom has
    left less room to spare (and tolerates more when zooming out gives
    extra room instead). Clamped to a floor of 0 -- past a large enough
    zoom-in, even the driftless max-width pose no longer fits in the frame
    at all, which no tolerance value can fix; that residual is an inherent
    consequence of the user's own zoom choice, not something this can
    compensate away.

    BUG FIXED 2026-09-08: this used to ignore the pixel offset entirely,
    even though offset shifts the subject's resting position toward ONE
    edge of the frame (see frame_camera's own offset math) -- eating
    margin on that near side while adding it on the far side. edge_guard's
    own tolerance is symmetric (the same threshold applies to both edges),
    so the tolerance actually safe to use is bounded by the TIGHTER (near)
    side, not the average symmetric slack the zoom-only formula assumed.
    Confirmed live on a real scene: a 60px offset left the TRUE near-edge
    tolerance at -2.87% (already clipping at rest, before any drift)
    while the offset-blind formula still claimed 2.00% was available --
    reported as "lost its frame-gate ability" and jumpy framing during an
    actual recording (Preview only ever shows one static frame, so this
    never surfaced there -- it only shows up once edge_guard's curve gets
    exercised across the whole animation during real playback).

    Manual override (2026-09-29, tolerance box): when manual_pct is not
    None, it IS the effective value (manual_pct / 100.0) -- bypasses the
    whole zoom/offset-derived formula AND its zero floor entirely, since a
    typed number is now the tolerance itself, not a suggestion layered on
    top of the auto one (M1 in the approved design: override, not additive,
    not a floor). Auto (manual_pct=None, the default) is completely
    unchanged from before this parameter existed -- every existing caller
    that never passes it keeps today's exact behavior, byte for byte."""
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
    # Hand-off to maya_key_from_cache.py's apply_recenter_override, so the
    # recenter override can apply the SAME pixel offset frame_camera() just
    # applied below instead of silently discarding it on the one frame
    # Preview actually shows (see apply_recenter_override's docstring for
    # the bug this fixes). Same file-hand-off pattern as
    # write_effective_overflow_pct.
    path = os.path.join(CACHE_DIR, '_camera_world_per_px.txt')
    with open(path, 'w') as f:
        f.write('%.10f' % value)


def write_base_ortho_width(value):
    # Hand-off to maya_camera_live_zoom.py: the PRE-zoom orthoWidth, so a
    # live zoom-slider push can recompute orthoWidth for a new zoom_pct
    # without redoing the margin/bbox measurement -- and can then rewrite
    # world_per_px too, since zoom changes what a pixel is worth (offset
    # nudging reads that same file -- see maya_key_from_cache.py's
    # apply_recenter_override fix for why these two must never drift
    # independently).
    path = os.path.join(CACHE_DIR, '_camera_base_ortho_width.txt')
    with open(path, 'w') as f:
        f.write('%.10f' % value)


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

    # world_h_override, when given, MUST be the same widened value
    # compute_margin_px derived margin_px from (see compute_effective_world_h)
    # -- margin_px and orthoWidth are two halves of the same formula, and
    # using the raw bbox height here instead would silently make orthoWidth
    # narrower than intended rather than wider. center_v still comes from
    # THIS bbox, not the cache -- vertical CENTERING stays a live/per-frame
    # concern (and is guaranteed exact at the recenter frame specifically
    # by maya_key_from_cache.py's apply_recenter_override), only the frame
    # SIZE needs the whole-animation max.
    world_h = world_h_override if world_h_override is not None else (bbox[vmax] - bbox[vmin])
    center_h = (bbox[hmax] + bbox[hmin]) / 2.0
    center_v = (bbox[vmax] + bbox[vmin]) / 2.0

    usable_px = max(panel_height - 2 * margin_px, 1)
    view_height_world = world_h * (panel_height / float(usable_px))
    # base_ortho_width is the pre-zoom frame width -- kept as its own
    # variable (not just a local inline expression) because
    # maya_camera_live_zoom.py needs this exact value to recompute
    # orthoWidth live from a NEW zoom_pct, without redoing the margin/bbox
    # math (see write_base_ortho_width below).
    base_ortho_width = view_height_world * (panel_width / float(panel_height))
    # Magnifier: scales the whole visible frame (Maya derives the vertical
    # extent from orthoWidth + panel aspect), so this is a true zoom, not
    # just a horizontal crop.
    ortho_width = base_ortho_width * (1.0 - zoom_pct / 100.0)

    # Pixel offset: converted using the FINAL (post-zoom) orthoWidth, so a
    # "pixel" here means an actual pixel on the rendered panel, matching
    # what the artist sees. world_per_px is the same in both directions --
    # panel_width/panel_height and orthoWidth's implied vertical extent
    # share one aspect ratio, so this one ratio covers both axes. Subtracted
    # (not added): center_h/center_v are the CAMERA's own position, and
    # moving the camera's position in the positive axis direction reveals
    # what's on that axis's negative side -- i.e. shifts the subject the
    # OTHER way on screen. Subtracting makes +X move the subject right and
    # +Y move it up, the intuitive reading of a "pixel offset" control.
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

    # Recenter at start frame: measure the bbox at the capture range's
    # resolved Start value instead of whatever frame happens to be current
    # -- the Range Slider's min/max is independent of the current-time
    # cursor in Maya, so without this a short Start/End or Time Slider
    # capture can be framed against a completely unrelated pose.
    #
    # Design (2026-09-02, revised): deliberately NOT restored afterward,
    # unlike maya_key_from_cache.py's own size-scale measurement -- the
    # whole point of this checkbox is for Preview to actually SHOW the
    # artist their capture's starting pose, not just use it as an invisible
    # internal reference. The first version restored the original time,
    # which computed the correct framing but left the artist looking at
    # whatever frame they started on -- indistinguishable from the feature
    # doing nothing at all. maya_key_from_cache.py (the next step in the
    # Preview/Start Recording sequence) captures ITS OWN current time at
    # its own start and restores THAT at its own end, so leaving Maya here
    # at recenter_frame carries through to the end of the whole run rather
    # than snapping back.
    recenter_frame = get_recenter_start_frame()
    if recenter_frame is not None:
        cmds.currentTime(recenter_frame)
        print('Recenter at start frame: showing frame %s' % recenter_frame)
    bbox = get_target_bbox()

    # Panels are forced to exactly col_width x mon_height below, so the
    # margin can be derived up front from those dimensions. Widened to the
    # cache's own max height BEFORE computing margin (see
    # compute_effective_world_h) -- this SAME widened value also has to
    # reach frame_camera below (its world_h_override param), or margin_px
    # and the final orthoWidth end up derived from two different heights
    # and the frame comes out narrower than intended, not wider.
    world_h = compute_effective_world_h(bbox[4] - bbox[1], load_cache())
    margin_px, max_w, needed_ortho = compute_margin_px(world_h, col_width, mon_height)
    zoom_pct = get_zoom_pct()
    if zoom_pct:
        print('Magnifier: %+.0f%%' % zoom_pct)
    offset_x_px, offset_y_px = get_pixel_offset()
    if offset_x_px or offset_y_px:
        print('Pixel offset: X=%+.0f Y=%+.0f' % (offset_x_px, offset_y_px))

    # Zoom changes how much of EDGE_OVERFLOW_PCT's built-in headroom is
    # actually left -- write the value that ACTUALLY applies at the current
    # zoom level so maya_key_from_cache.py's edge_guard uses it instead of
    # its own static constant. See compute_effective_overflow_pct.
    #
    # offset_x_px=0.0 here, NOT the real offset (2026-09-28, part of G):
    # key_edge_guard's guard tolerance is now zoom-only -- the offset no
    # longer shrinks it, since G already guarantees the offset survives as
    # a pure constant shift regardless of how much tolerance is left (see
    # key_edge_guard/compute_edge_guard_curve's own docstrings for the full
    # derivation). Coupling this tolerance to the offset was the OLD design
    # (offset-reduced), rejected in favor of keeping the offset a pure
    # translation -- see the proposal's REJECTED list. This does NOT affect
    # the launcher's own glow/prompt (Get-FrameGateEffectiveOverflowPct in
    # rom_launcher.ps1, which computes its own value independently and
    # deliberately stays offset-aware, Q-ON) -- only what gets WRITTEN here
    # for the keyer to read.
    # Manual tolerance override (2026-09-29): a typed value in the
    # "Tolerance" box bypasses the zoom-derived formula entirely (M1,
    # override not additive/floor -- see compute_effective_overflow_pct's
    # own docstring). None (Auto, the default) is byte-identical to before
    # this existed.
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

        panel_w = cmds.control(panel, query=True, width=True)
        panel_h = cmds.control(panel, query=True, height=True)
        computed_world_per_px, computed_base_ortho_width = frame_camera(view_name, cam, panel_w, panel_h, bbox, margin_px, zoom_pct, offset_x_px, offset_y_px, world_h)

    write_world_per_px(computed_world_per_px)
    write_base_ortho_width(computed_base_ortho_width)
    cmds.refresh(force=True)


# Suspended for the whole setup (2026-09-08): without this, the user sees
# the panel windows appear unframed and then visibly snap into place
# across 3 separate cmds.refresh(force=True) calls inside
# open_view_panels() -- reported as "the viewport kept updating the
# progress... quite distracting." Resumed in `finally` so a mid-setup
# failure can never leave the viewport frozen (the same reasoning as the
# existing model-editor-bars restore in `except` just below, now covering
# both).
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
