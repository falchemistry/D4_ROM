## 1.1.0 - 2026-10-21

- Added: Pre-Post Recording - two scripts, d4_rom_pre_record.py and d4_rom_post_record.py, in the new user_hooks folder (created on first start from empty templates, never overwritten) run inside Maya before and after each video (axis All = two videos); a failing pre script aborts the recording, a failing post script only warns, Stop runs post if pre ran.
- Added: a Pre-Post Recording row with a folder button in the Settings tab (dot gray = both empty, green = code present, amber = problem).
- Added: the zip ships empty templates only and the build fails if a template contains code or user_hooks would be shipped.
- Changed: scripts are grouped in maya, capture, obs and state folders (done in the previous commit, no version change then).
- Added tests: runner, hooks and dist tests.

## 1.0.1 - 2026-10-21

- Fixed: the capture camera starts centred when the start frame is not 0 (path re-started at the start frame).
- Fixed: the Offset adjustment now follows the frame you see, also when the frame gate was on at Start Recording (the Offset sets the start position).
- Added tests: live start-frame tracking runner, module-level offset test with a fake maya.cmds, zoom 20 / Offset 0 check in the launcher integration suite.
- Known limit: Left/Right start frame 0 is about 0.3 px off the old result.

## 1.0.0

- First documented version.
