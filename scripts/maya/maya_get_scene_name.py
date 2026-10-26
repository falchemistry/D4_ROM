"""Reports the name of the scene open in Maya, for the launcher's Prefix
box (T87): the scene file name without its folder and extension
('D:/proj/barM_v2.ma' -> 'barM_v2', 'a.v2.ma' -> 'a.v2').

Writes ONE line to RESULT_PATH -- rom_launcher.ps1 (Get-MayaSceneName /
ConvertFrom-SceneNameOutput) parses this exact format:
    SCENE_NAME <name>
    SCENE_UNTITLED            (never saved: the launcher fills nothing)
    SCENE_NAME_ERROR <message>
A FILE, not stdout: Maya's command port does not relay print() output back
over the socket on a successful run (see maya_check_cache.py).

Read-only (queries cmds.file, changes nothing in the scene) and idempotent:
Maya's command port runs every payload TWICE, and the second run simply
rewrites the same single line (the file is overwritten, never appended).
ASCII-only source; works in Python 2 and 3. The result file is written as
UTF-8 so a non-ASCII scene name survives.

D4_SCENE_NAME_RESULT_PATH in the exec globals overrides RESULT_PATH (used by
tests/test_prefix_naming.ps1 with a fake maya.cmds under plain python).
"""

# Imports live inside each function (workspace bridge convention: a function
# never relies on a module-level import name).


def scene_base_name(scene_path):
    """File name without folder and extension; '' for an untitled scene."""
    import os
    if not scene_path:
        return u""
    base = os.path.basename(scene_path.replace("\\", "/").rstrip("/"))
    name = os.path.splitext(base)[0]
    return name


def to_text(value):
    """unicode in Python 2, str in Python 3 (Maya 2.x returns unicode or a
    UTF-8 byte string)."""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    try:
        text_type = unicode  # noqa: F821 (Python 2)
    except NameError:
        text_type = str
    if not isinstance(value, text_type):
        value = text_type(value)
    return value


def scene_name_result_line():
    try:
        import maya.cmds as cmds
        path = cmds.file(q=True, sceneName=True)
        name = scene_base_name(to_text(path or u""))
        if not name.strip():
            return u"SCENE_UNTITLED"
        return u"SCENE_NAME " + name
    except Exception as exc:
        message = u" ".join(to_text(exc).split())
        return u"SCENE_NAME_ERROR %s: %s" % (to_text(type(exc).__name__), message)


def default_result_path():
    import os
    import sys
    script_dir = os.path.dirname(os.path.abspath(sys._getframe().f_code.co_filename))
    return os.path.join(script_dir, "..", "..", "d4_anim_sample", "_scene_name_result.txt")


def write_result(path, line):
    import io
    import os
    folder = os.path.dirname(path)
    if folder and not os.path.isdir(folder):
        os.makedirs(folder)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(to_text(line) + u"\n")


RESULT_PATH = globals().get("D4_SCENE_NAME_RESULT_PATH") or default_result_path()
write_result(RESULT_PATH, scene_name_result_line())
