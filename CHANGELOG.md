## 1.0.1 - 2026-10-21

- Fixed: the capture camera starts centred when the start frame is not 0 (path re-started at the start frame).
- Fixed: the Offset adjustment now follows the frame you see, also when the frame gate was on at Start Recording (the Offset sets the start position).
- Added tests: live start-frame tracking runner, module-level offset test with a fake maya.cmds, zoom 20 / Offset 0 check in the launcher integration suite.
- Known limit: Left/Right start frame 0 is about 0.3 px off the old result.

## 1.0.0

- First documented version.
