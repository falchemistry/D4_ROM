"""Restore Maya's HUD to whatever maya_obs_capture.ps1's Get-MayaHudState
last saved to _hud_state.json, then delete that file.

Closes the gap Process.Kill() opens: killing maya_obs_capture.ps1 bypasses
its own PowerShell `finally` entirely (same reasoning as
maya_stop_playback.py's own header comment about killing the watching
process, not Maya's own playback loop), so a hard Stop mid-capture would
otherwise leave the capture panel's HUD forced on and any suppressed items
still suppressed. This script is the other half of that restore, run as
its own step from rom_launcher_logic.ps1's Get-StopCleanupSteps.

Deliberately a silent no-op if _hud_state.json doesn't exist -- Stop can be
clicked when no capture (or a Preview-only run) is active at all, in which
case there is nothing to restore, same "run regardless, no-op if nothing to
do" convention Get-StopCleanupSteps' own header comment already documents
for obs_control.ps1 -Action stop.
"""
import json
import os
import sys
from maya import cmds

# NOT os.path.dirname(__file__) -- send_to_maya.ps1 runs this script via
# exec(compile(open(path).read(), path, 'exec'), {}), an EMPTY globals
# dict that never gets a '__file__' entry (confirmed live, 2026-09-30:
# raises NameError). sys._getframe().f_code.co_filename is the same
# workaround already used by maya_camera_panels.py/_LR.py's own SCRIPT_DIR
# for this exact reason.
SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
STATE_PATH = os.path.join(SCRIPT_DIR, '..', 'state', '_hud_state.json')

if os.path.exists(STATE_PATH):
    with open(STATE_PATH) as f:
        state = json.load(f)

    for item_name, was_visible in state.get('items', {}).items():
        try:
            cmds.headsUpDisplay(item_name, edit=True, visible=bool(was_visible))
        except Exception as e:
            print('Could not restore HUD item %r: %s' % (item_name, e))

    for panel_name, was_on in state.get('panels', {}).items():
        # The panel may already be gone (window closed between the kill and
        # this step running) -- skip it silently rather than error, same
        # existence-guard Get-MayaHudState itself uses when SAVING.
        if cmds.control(panel_name, exists=True):
            try:
                cmds.modelEditor(panel_name, edit=True, headsUpDisplay=bool(was_on))
            except Exception as e:
                print('Could not restore HUD flag on panel %r: %s' % (panel_name, e))

    os.remove(STATE_PATH)
    print('MAYA_HUD_RESTORED')
else:
    print('MAYA_HUD_RESTORE_SKIPPED no_saved_state')
