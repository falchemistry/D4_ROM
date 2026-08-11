# Paste this into Maya's Script Editor (Python tab) and run it (Ctrl+Enter)
# before using rom_launcher.bat or any of the other .bat files in this
# folder. They all send commands to Maya over this port -- without it
# open, every button/step will silently do nothing (Maya's command port
# does not show an error if nothing is listening).
#
# Must be re-run every time Maya is restarted -- the port does not persist
# across sessions. Safe to run more than once (closes any existing port on
# this name first, so it won't error if it's already open).
import maya.cmds as cmds

try:
    cmds.commandPort(name=':7001', close=True)
except Exception:
    pass
cmds.commandPort(name=':7001', sourceType='python')
print('Command port :7001 is open -- rom_launcher.bat and the other .bat files will work now.')
