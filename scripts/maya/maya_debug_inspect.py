import maya.cmds as cmds
import traceback

lines = []
try:
    for cam, attr in (('d4_rom_front', 'translateX'), ('d4_rom_back', 'translateX'),
                      ('d4_rom_left', 'translateZ'), ('d4_rom_right', 'translateZ')):
        if not cmds.objExists(cam):
            lines.append('%s MISSING' % cam)
            continue
        shape = cmds.listRelatives(cam, shapes=True)[0]
        n = cmds.keyframe(cam + '.' + attr, query=True, keyframeCount=True) or 0
        lines.append('%-15s keys=%-5d orthoWidth=%.2f' % (cam, n, cmds.getAttr(shape + '.orthographicWidth')))
except Exception:
    lines.append('ERROR')
    lines.append(traceback.format_exc())

with open(r'D:\__backup\claude\maya_debug.txt', 'w') as f:
    f.write('\n'.join(lines))
