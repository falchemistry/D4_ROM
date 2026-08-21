"""Reports Maya's animationStartTime/animationEndTime -- the OUTER bounds
of the scene's actual keyed animation, independent of whatever the artist
has the Range Slider (playbackOptions minTime/maxTime) currently scrubbed
to. This is what the launcher's "All" Time Range option uses: recording
the true full ROM regardless of the Range Slider's current state, instead
of silently trusting it (a real bug -- "All" could previously record a
narrower clip than the actual animation if the Range Slider had been
scrubbed narrower for something unrelated).

Writes "ANIM_RANGE min=<int> max=<int>" (or "ANIM_RANGE_ERROR <message>")
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
RESULT_PATH = os.path.join(CACHE_DIR, '_animation_range_result.txt')

if not os.path.isdir(CACHE_DIR):
    os.makedirs(CACHE_DIR)

try:
    min_time = int(cmds.playbackOptions(query=True, animationStartTime=True))
    max_time = int(cmds.playbackOptions(query=True, animationEndTime=True))
    result_line = 'ANIM_RANGE min=%d max=%d' % (min_time, max_time)
except Exception as exc:
    result_line = 'ANIM_RANGE_ERROR %s' % exc

with open(RESULT_PATH, 'w') as f:
    f.write(result_line)
print(result_line)
