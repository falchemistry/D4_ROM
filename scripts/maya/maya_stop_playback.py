"""Stop Maya's own playback immediately -- used by the launcher's Stop
button, since killing maya_obs_capture.ps1 externally only stops the
WATCHING process, not Maya's own playback loop, which would otherwise
keep animating on its own until it reaches the end of its range.
"""
from maya import cmds

cmds.play(state=False)
