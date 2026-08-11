"""Full clean reset: close all Claude view panels, delete the custom
mirrored cameras (claude_cam_back, claude_cam_left) so they regenerate
fresh from front/side, and reset to frame 0 as a consistent reference
pose. Run this before re-opening panels + rebuilding the cache whenever
state feels inconsistent.
"""
import maya.cmds as cmds

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

cmds.select(clear=True)
cmds.currentTime(0)

print('CLAUDE_CLEAN_RESET_OK')
