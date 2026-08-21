"""Reports Maya's current Range Slider (minTime/maxTime) -- the artist's
active working range, not the outer animationStartTime/animationEndTime
bounds. This is what "Time Slider" means in the ROM launcher's Time Range
option: whatever range is set right now, read fresh at click time.

Writes "TIME_RANGE min=<int> max=<int>" (or "TIME_RANGE_ERROR <message>")
to RESULT_PATH -- rom_launcher.ps1 parses this exact format. A FILE, not
stdout: confirmed empirically (see maya_check_cache.py's header comment)
that Maya's command port does not relay print() output back to the client
over the socket on a successful run.
"""
import os
import sys
import maya.cmds as cmds

SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', 'd4_anim_sample')
RESULT_PATH = os.path.join(CACHE_DIR, '_time_slider_result.txt')

if not os.path.isdir(CACHE_DIR):
    os.makedirs(CACHE_DIR)

try:
    min_time = int(cmds.playbackOptions(query=True, minTime=True))
    max_time = int(cmds.playbackOptions(query=True, maxTime=True))
    result_line = 'TIME_RANGE min=%d max=%d' % (min_time, max_time)
except Exception as exc:
    result_line = 'TIME_RANGE_ERROR %s' % exc

with open(RESULT_PATH, 'w') as f:
    f.write(result_line)
print(result_line)
