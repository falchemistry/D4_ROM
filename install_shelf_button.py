# Run this ONCE (paste into Maya's Script Editor, Python tab, Ctrl+Enter).
# It adds a permanent "OpenROMPort" button to your current shelf tab --
# shelves are saved with Maya's preferences, so the button survives
# restarts. After this one-time setup, opening the command port each
# session is just one click on that button (still manual/on-demand, not
# auto-run on launch) instead of pasting open_maya_port.py every time.
import maya.cmds as cmds

# The actual code the button runs -- same as open_maya_port.py, just
# embedded as the button's command string.
BUTTON_COMMAND = '''import maya.cmds as cmds
try:
    cmds.commandPort(name=':7001', close=True)
except Exception:
    pass
cmds.commandPort(name=':7001', sourceType='python')
print('Command port :7001 is open -- rom_launcher.bat and the other .bat files will work now.')
'''

current_shelf = cmds.tabLayout('ShelfLayout', query=True, selectTab=True)

# avoid piling up duplicates if this installer gets run more than once
for existing in cmds.shelfLayout(current_shelf, query=True, childArray=True) or []:
    if cmds.shelfButton(existing, query=True, exists=True):
        if cmds.shelfButton(existing, query=True, label=True) == 'ROM Port':
            cmds.deleteUI(existing)

cmds.shelfButton(
    parent=current_shelf,
    label='ROM Port',
    annotation='Open the Maya command port (127.0.0.1:7001) the D4 ROM tools need. Click once per Maya session.',
    image1='commandButton.png',
    command=BUTTON_COMMAND,
    sourceType='python',
)

print('Added a "ROM Port" button to your "%s" shelf. Click it once each time you restart Maya, before using rom_launcher.bat.' % current_shelf)
