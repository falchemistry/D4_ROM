# d4_rom_pre_record.py -- your own pre-record script for D4 ROM Capture.
#
# Runs INSIDE Maya right BEFORE each recording starts (after the camera
# panels and keys are ready, just before OBS starts recording). With Axis
# "All" there are two recordings, so this runs twice: once per video.
#
# While this file has no code (only comments and blank lines) the tool
# does not run it at all. Save it as UTF-8.
#
# Available in this script:
#   maya.cmds    -- import it yourself: from maya import cmds
#   D4_CTX       -- a dict describing this recording:
#                   kind ('pre'), axis (run axis: FrontBack, LeftRight
#                   or All), leg_axis (this video's axis), leg_index
#                   (0 or 1), leg_count (1 or 2), start_frame, end_frame
#                   (None when recording all frames), tool_version,
#                   scripts_dir, state_dir
#
# Raising an error here CANCELS the recording on purpose: the tool stops
# the run, restores the taskbar and shows your error message in the log.
# Example: raise RuntimeError('Set the scene units to cm first')
#
# Example (remove the leading '# ' to use it):
#
# from maya import cmds
# if D4_CTX['leg_index'] == 0:
#     cmds.currentTime(cmds.playbackOptions(query=True, minTime=True))
# if not cmds.objExists('ROM_root'):
#     raise RuntimeError('ROM_root is missing -- recording cancelled')
