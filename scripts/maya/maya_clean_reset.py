"""Full clean reset: close all Claude view panels, delete the custom
mirrored cameras (claude_cam_back, claude_cam_left) so they regenerate
fresh from front/side, and reset to frame 0 as a consistent reference
pose. Run this before re-opening panels + rebuilding the cache whenever
state feels inconsistent.
"""
import maya.cmds as cmds
import maya.mel as mel

ALL_KNOWN_VIEWS = ['front', 'back', 'side', 'left']
WINDOW_NAME = {v: 'claude_view_' + v for v in ALL_KNOWN_VIEWS}
CUSTOM_CAMERAS = ['d4_rom_front', 'd4_rom_back', 'd4_rom_left', 'd4_rom_right',
                   'claude_cam_back', 'claude_cam_left']  # old names too, in case of leftovers

for v in ALL_KNOWN_VIEWS:
    wname = WINDOW_NAME[v]
    if cmds.window(wname, exists=True):
        cmds.deleteUI(wname)

known_titles = set(v.title() + ' View' for v in ALL_KNOWN_VIEWS) | {'Right View'}
for old_win in cmds.lsUI(windows=True) or []:
    try:
        if cmds.window(old_win, query=True, title=True) in known_titles:
            cmds.deleteUI(old_win)
    except Exception:
        pass

for cam in CUSTOM_CAMERAS:
    if cmds.objExists(cam):
        cmds.delete(cam)
        print('Deleted %s' % cam)

# hide_model_editor_bars() in maya_camera_panels.py/_LR.py calls
# toggleModelEditorBarsInAllPanels(1) to hide the icon toolbar row while
# capturing -- confirmed (by reading toggleModelEditorBarsInAllPanels.mel
# directly) that this collapses a frameLayout via "-collapse 1" on EVERY
# modelPanel in the scene, not just the capture panels, and that it is a
# plain set, not a toggle: calling it again with the same "1" never
# un-hides anything. Nothing previously called it with "0" to restore,
# which left the user's own main viewport's icon toolbar (and the
# stereoCameraToolBar, if present) collapsed indefinitely after a
# capture, with no visual cue why (2026-08-20, reported live: the row
# stayed missing through Reset). Safe to call unconditionally every
# reset -- collapse=0 on an already-expanded frameLayout is a no-op.
mel.eval('toggleModelEditorBarsInAllPanels(0)')

cmds.select(clear=True)
cmds.currentTime(0)

print('CLEAN_RESET_OK')
