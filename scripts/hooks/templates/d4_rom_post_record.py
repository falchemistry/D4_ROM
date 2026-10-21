# d4_rom_post_record.py -- your own post-record script for D4 ROM Capture.
#
# Runs INSIDE Maya right AFTER each recording stops. With Axis "All" there
# are two recordings, so this runs twice: once per video. It also runs
# once when you click Stop, if the pre-record script already ran.
#
# While this file has no code (only comments and blank lines) the tool
# does not run it at all. Save it as UTF-8.
#
# Available in this script:
#   maya.cmds    -- import it yourself: from maya import cmds
#   D4_CTX       -- a dict describing this recording:
#                   kind ('post'), axis (run axis: FrontBack, LeftRight
#                   or All), leg_axis (this video's axis), leg_index
#                   (0 or 1), leg_count (1 or 2), start_frame, end_frame
#                   (None when recording all frames), tool_version,
#                   scripts_dir, state_dir
#
# An error here is only a WARNING: it is written to the log and the run
# carries on (the next video and the final reset still happen).
#
# Example (remove the leading '# ' to use it):
#
# from maya import cmds
# print('Recorded video %d of %d' % (D4_CTX['leg_index'] + 1, D4_CTX['leg_count']))
# cmds.select(clear=True)
