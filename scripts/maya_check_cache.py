"""Reports whether an animation-bbox cache already exists for the CURRENT
scene's animation reference, without building anything -- lets the launcher
answer "will Preview/Start Recording trigger a slow first-time cache build,
or not" before the user clicks it.

Reference-resolution and cache-path logic are duplicated from
maya_cache_bbox.py rather than imported -- every script this project sends
through send_to_maya.ps1 runs in its own isolated exec() namespace (see
that file's header comment for why), so there is no live import to share
between them; keeping this pair small and duplicated is simpler than
threading a shared import across the bridge.

Writes one line starting with CACHE_EXISTS or CACHE_MISSING, followed by
the resolved animation reference and cache path, to RESULT_PATH --
rom_launcher.ps1 parses this exact format. A FILE, not stdout: confirmed
empirically (2026-08-19) that Maya's command port does not relay print()
output back to the client over the socket at all on a successful run --
only the exec() call's own return value (always None for the isolated
exec() wrapper send_to_maya.ps1 sends) or an exception's text comes back.
This is the same file-based signaling already proven for
maya_cache_bbox.py's _cache_build_progress.txt, not a new pattern.
"""
import hashlib
import os
import sys
import maya.cmds as cmds

SCRIPT_DIR = os.path.dirname(sys._getframe().f_code.co_filename)
CACHE_DIR = os.path.join(SCRIPT_DIR, '..', 'd4_anim_sample')
RESULT_PATH = os.path.join(CACHE_DIR, '_cache_check_result.txt')


def find_animation_reference(refs):
    anim_refs = [r for r in refs if 'anim' in os.path.basename(r).lower()]
    if anim_refs:
        return anim_refs[0]
    non_skel = [r for r in refs if 'skel' not in os.path.basename(r).lower()]
    if non_skel:
        return non_skel[0]
    return refs[0]


def cache_path_for(anim_ref_path):
    digest = hashlib.sha1(anim_ref_path.encode('utf-8')).hexdigest()[:12]
    safe_name = os.path.splitext(os.path.basename(anim_ref_path))[0]
    return os.path.join(CACHE_DIR, '%s__%s.json' % (safe_name, digest))


if not os.path.isdir(CACHE_DIR):
    os.makedirs(CACHE_DIR)

try:
    refs = cmds.file(query=True, reference=True) or []
    if not refs:
        # Distinct from CACHE_CHECK_ERROR below (an unexpected failure) --
        # this is the expected result of the wrong scene being loaded, or
        # the right scene not being referenced in yet, and the launcher's
        # Maya-connection indicator surfaces it differently (a "wrong
        # scene" warning, not a generic error).
        result_line = 'CACHE_NO_REFERENCE No file references found in this scene.'
    else:
        anim_ref = find_animation_reference(refs)
        cache_path = cache_path_for(anim_ref)
        status = 'CACHE_EXISTS' if os.path.exists(cache_path) else 'CACHE_MISSING'
        result_line = '%s animation_reference=%s cache_path=%s' % (status, anim_ref, cache_path)
except Exception as exc:
    result_line = 'CACHE_CHECK_ERROR %s' % exc

with open(RESULT_PATH, 'w') as f:
    f.write(result_line)
print(result_line)
