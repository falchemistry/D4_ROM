r"""
Persistent regression test for scripts/hooks/maya_run_hook.py (T97), the
tool-owned runner that executes the user's d4_rom_pre_record.py /
d4_rom_post_record.py inside Maya.

Run directly, no live Maya session required and NO mayapy (banned
workspace-wide -- see CLAUDE.md):

    python tests/test_prepost_runner.py

Exits 0 if all checks pass, 1 otherwise.

Method: a fake `maya` / `maya.cmds` package is put into sys.modules, then
the REAL runner file is exec'd the same way the launcher's payload does
(exec(compile(open(path).read(), path, 'exec'), {...})), so this exercises
the shipped file, not a copy. Also checks the two shipped templates are
ASCII and comment-only (the runner must treat them as "no code").

NOT covered here (needs the live bridge / the real launcher): that Maya's
command port relays the raised CAPTURE_ABORT text back to send_to_maya.ps1
and that rom_launcher.ps1 then aborts the run.
"""
import io
import json
import os
import shutil
import sys
import tempfile
import traceback
import types

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
RUNNER_PATH = os.path.join(REPO_ROOT, "scripts", "hooks", "maya_run_hook.py")
TEMPLATE_DIR = os.path.join(REPO_ROOT, "scripts", "hooks", "templates")
TEMPLATE_NAMES = ["d4_rom_pre_record.py", "d4_rom_post_record.py"]

results = []


def check(name, fn):
    try:
        fn()
        results.append((name, True, ""))
    except BaseException:  # a user-code KeyboardInterrupt must fail the case, not kill the suite
        results.append((name, False, traceback.format_exc().strip().splitlines()[-1]))


def install_fake_maya():
    """A minimal stand-in for maya.cmds that records calls."""
    maya_pkg = types.ModuleType("maya")
    cmds = types.ModuleType("maya.cmds")
    cmds.calls = []

    def currentTime(*args, **kwargs):
        cmds.calls.append(("currentTime", args, kwargs))
        return 1.0

    def objExists(name):
        cmds.calls.append(("objExists", (name,), {}))
        return name == "exists_node"

    cmds.currentTime = currentTime
    cmds.objExists = objExists
    maya_pkg.cmds = cmds
    sys.modules["maya"] = maya_pkg
    sys.modules["maya.cmds"] = cmds
    return cmds


def write(path, text):
    with io.open(path, "w", encoding="ascii", newline="\n") as f:
        f.write(text)


def load_runner_functions():
    """exec the runner WITHOUT D4_HOOK_KIND: defines functions only."""
    g = {"__name__": "d4_rom_hook_runner_test"}
    with open(RUNNER_PATH) as f:
        source = f.read()
    exec(compile(source, RUNNER_PATH, "exec"), g)
    return g


def run_payload(tmp, kind, user_path, ctx_path, leg_index=0, leg_axis="FrontBack", run_id=None):
    """Exactly what the launcher's -Code payload does. Returns
    (raised_text or None, printed lines)."""
    printed = []
    g = {
        "__name__": "d4_rom_hook_runner",
        "D4_HOOK_KIND": kind,
        "D4_HOOK_USER_PATH": user_path,
        "D4_HOOK_CONTEXT_PATH": ctx_path,
        "D4_HOOK_LEG_INDEX": leg_index,
        "D4_HOOK_LEG_AXIS": leg_axis,
    }
    if run_id is not None:
        g["D4_HOOK_RUN_ID"] = run_id
    with open(RUNNER_PATH) as f:
        source = f.read()
    old_stdout = sys.stdout
    buf = io.StringIO() if sys.version_info[0] >= 3 else io.BytesIO()
    sys.stdout = buf
    raised = None
    try:
        exec(compile(source, RUNNER_PATH, "exec"), g)
    except RuntimeError as exc:
        raised = str(exc)
    finally:
        sys.stdout = old_stdout
    printed = [l for l in buf.getvalue().splitlines() if l.strip()]
    return raised, printed


def make_context(tmp):
    ctx_path = os.path.join(tmp, "_hook_context.json")
    write(ctx_path, json.dumps({
        "axis": "All", "leg_count": 2, "start_frame": None, "end_frame": None,
        "tool_version": "1.1.0", "scripts_dir": tmp, "state_dir": tmp,
        "kind": "SHOULD_BE_OVERRIDDEN", "leg_index": 99,
    }))
    return ctx_path


TMP = tempfile.mkdtemp(prefix="t97_runner_")
CMDS = install_fake_maya()
CTX_PATH = make_context(TMP)


def t_runner_exists():
    assert os.path.isfile(RUNNER_PATH), "runner missing: %s" % RUNNER_PATH
    with open(RUNNER_PATH, "rb") as f:
        data = f.read()
    data.decode("ascii")
    assert not data.startswith(b"\xef\xbb\xbf"), "runner has a BOM"


def t_load_without_kind_runs_nothing():
    g = load_runner_functions()
    for fn in ("hook_source_has_code", "build_context", "run_user_hook", "relay_error_for", "main"):
        assert callable(g.get(fn)), "%s not defined" % fn


def t_has_code_rule():
    g = load_runner_functions()
    f = g["hook_source_has_code"]
    assert f("") is False
    assert f("\n\n   \n") is False
    assert f("# a\n   # b\n\n") is False
    assert f("# a\nx = 1\n") is True
    assert f("    print('x')  # indented\n") is True


def t_templates_are_ascii_comment_only():
    g = load_runner_functions()
    for name in TEMPLATE_NAMES:
        p = os.path.join(TEMPLATE_DIR, name)
        assert os.path.isfile(p), "template missing: %s" % p
        with open(p, "rb") as f:
            data = f.read()
        text = data.decode("ascii")
        assert not data.startswith(b"\xef\xbb\xbf"), "%s has a BOM" % name
        assert text.strip(), "%s is empty (needs the explanatory header)" % name
        assert not g["hook_source_has_code"](text), "%s has a code line" % name
        assert "D4_CTX" in text, "%s does not mention D4_CTX" % name


def t_ok_path():
    user = os.path.join(TMP, "ok_pre.py")
    write(user, "# comment\nfrom maya import cmds\ncmds.currentTime(5)\n")
    del CMDS.calls[:]
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is None, "unexpected raise: %s" % raised
    assert "D4_HOOK_OK pre" in printed, "printed: %r" % printed
    assert CMDS.calls and CMDS.calls[0][0] == "currentTime", "fake cmds not called: %r" % CMDS.calls


def t_ctx_visible():
    user = os.path.join(TMP, "ctx_post.py")
    out_path = os.path.join(TMP, "ctx_dump.json")
    write(user, "import json\nwith open(%r, 'w') as f:\n    json.dump(D4_CTX, f)\n" % out_path)
    raised, printed = run_payload(TMP, "post", user, CTX_PATH, leg_index=1, leg_axis="LeftRight")
    assert raised is None, "unexpected raise: %s" % raised
    with open(out_path) as f:
        ctx = json.load(f)
    assert ctx["kind"] == "post", ctx
    assert ctx["leg_index"] == 1, ctx
    assert ctx["leg_axis"] == "LeftRight", ctx
    assert ctx["axis"] == "All", ctx
    assert ctx["leg_count"] == 2, ctx
    assert ctx["start_frame"] is None and ctx["end_frame"] is None, ctx
    assert ctx["tool_version"] == "1.1.0", ctx
    for key in ("scripts_dir", "state_dir"):
        assert key in ctx, key


def t_pre_error_aborts():
    user = os.path.join(TMP, "boom_pre.py")
    write(user, "x = 1\nraise ValueError('no camera here')\n")
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is not None, "PRE error must raise"
    assert raised.startswith("CAPTURE_ABORT: pre-record script failed -- "), raised
    assert "ValueError: no camera here" in raised, raised
    assert "(line 2)" in raised, raised
    assert "\n" not in raised, "relayed text must be one line"
    err = [l for l in printed if l.startswith("D4_HOOK_ERROR pre:")]
    assert err, "no D4_HOOK_ERROR line printed: %r" % printed
    assert any("Traceback" in l for l in printed), "no traceback printed"


def t_post_error_warns_only():
    user = os.path.join(TMP, "boom_post.py")
    write(user, "raise KeyError('k')\n")
    raised, printed = run_payload(TMP, "post", user, CTX_PATH)
    assert raised is not None, "POST error must still be relayed as text"
    assert "CAPTURE_ABORT" not in raised, "POST must never abort: %s" % raised
    assert raised.startswith("D4_HOOK_ERROR post: KeyError"), raised


def t_syntax_error():
    user = os.path.join(TMP, "syntax_pre.py")
    write(user, "# ok\nif True\n    pass\n")
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is not None and raised.startswith("CAPTURE_ABORT: pre-record script failed -- "), raised
    assert "SyntaxError" in raised, raised
    assert "(line 2)" in raised, raised


def t_system_exit_is_caught():
    user = os.path.join(TMP, "exit_pre.py")
    write(user, "import sys\nsys.exit(3)\n")
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is not None and "SystemExit" in raised, raised


def t_fresh_dict():
    a = os.path.join(TMP, "fresh_a.py")
    b = os.path.join(TMP, "fresh_b.py")
    write(a, "LEAK_ME = 1\n")
    write(b, "\n".join([
        "assert 'LEAK_ME' not in globals(), 'value leaked from a previous hook'",
        "for n in ('run_user_hook', 'main', 'D4_HOOK_KIND', 'D4_HOOK_USER_PATH', 'build_context'):",
        "    assert n not in globals(), n + ' visible to user code'",
        "assert isinstance(D4_CTX, dict)",
        "assert __file__.endswith('fresh_b.py')",
        "",
    ]))
    raised, _ = run_payload(TMP, "pre", a, CTX_PATH)
    assert raised is None, raised
    raised, printed = run_payload(TMP, "pre", b, CTX_PATH)
    assert raised is None, "fresh-dict check failed: %s" % raised


def t_missing_file_skipped():
    raised, printed = run_payload(TMP, "pre", os.path.join(TMP, "nope.py"), CTX_PATH)
    assert raised is None, "missing file must not abort: %s" % raised
    assert any(l.startswith("D4_HOOK_SKIPPED pre") for l in printed), printed


def t_comment_only_skipped():
    user = os.path.join(TMP, "empty_post.py")
    write(user, "# only comments\n\n   # more\n")
    raised, printed = run_payload(TMP, "post", user, CTX_PATH)
    assert raised is None, raised
    assert any(l.startswith("D4_HOOK_SKIPPED post") for l in printed), printed


def t_missing_context_still_runs():
    user = os.path.join(TMP, "noctx_pre.py")
    out_path = os.path.join(TMP, "noctx_dump.json")
    write(user, "import json\nwith open(%r, 'w') as f:\n    json.dump(D4_CTX, f)\n" % out_path)
    raised, printed = run_payload(TMP, "pre", user, os.path.join(TMP, "no_ctx.json"))
    assert raised is None, raised
    with open(out_path) as f:
        ctx = json.load(f)
    assert ctx["kind"] == "pre" and "context_error" in ctx, ctx


def t_unknown_kind_raises():
    g = load_runner_functions()
    try:
        g["main"]({"D4_HOOK_KIND": "middle"}, out=lambda s: None)
    except RuntimeError as exc:
        assert "CAPTURE_ABORT" not in str(exc), str(exc)
        return
    raise AssertionError("unknown kind did not raise")


def t_utf8_bom_user_file():
    user = os.path.join(TMP, "bom_pre.py")
    with open(user, "wb") as f:
        f.write(b"\xef\xbb\xbfx = 1\n")
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is None, raised
    assert "D4_HOOK_OK pre" in printed, printed


def _counter_hook(name, kind_raise=False):
    """A user file that appends one line per execution to a counter file."""
    user = os.path.join(TMP, name + ".py")
    counter = os.path.join(TMP, name + "_count.txt")
    body = "with open(%r, 'a') as f:\n    f.write('x\\n')\n" % counter
    if kind_raise:
        body += "raise RuntimeError('cancel on purpose')\n"
    write(user, body)
    return user, counter


def _count(counter):
    if not os.path.exists(counter):
        return 0
    with open(counter) as f:
        return len([l for l in f if l.strip()])


def t_once_guard_same_id_runs_once():
    # Maya's command port executes every payload TWICE; the second
    # execution of the same run id must not run the user's file again.
    user, counter = _counter_hook("once_post")
    rid = "post-0-11111111111111111111111111111111"
    r1, p1 = run_payload(TMP, "post", user, CTX_PATH, run_id=rid)
    r2, p2 = run_payload(TMP, "post", user, CTX_PATH, run_id=rid)
    assert r1 is None and r2 is None, (r1, r2)
    assert _count(counter) == 1, "user code ran %d times for one run id" % _count(counter)
    assert "D4_HOOK_OK post" in p1, p1
    assert any(l.startswith("D4_HOOK_SKIPPED post duplicate") for l in p2), p2


def t_once_guard_different_id_runs_again():
    user, counter = _counter_hook("once_two_ids")
    run_payload(TMP, "pre", user, CTX_PATH, run_id="pre-0-aaaa")
    run_payload(TMP, "pre", user, CTX_PATH, run_id="pre-0-aaaa")
    run_payload(TMP, "pre", user, CTX_PATH, leg_index=1, run_id="pre-1-bbbb")
    run_payload(TMP, "pre", user, CTX_PATH, leg_index=1, run_id="pre-1-bbbb")
    assert _count(counter) == 2, "expected one run per id (2), got %d" % _count(counter)


def t_once_guard_pre_raise_only_once():
    user, counter = _counter_hook("once_pre_raise", kind_raise=True)
    rid = "pre-0-cccc"
    r1, _ = run_payload(TMP, "pre", user, CTX_PATH, run_id=rid)
    r2, p2 = run_payload(TMP, "pre", user, CTX_PATH, run_id=rid)
    assert r1 is not None and r1.startswith("CAPTURE_ABORT: pre-record script failed -- "), r1
    assert r2 is None, "duplicate execution raised again: %s" % r2
    assert _count(counter) == 1, _count(counter)
    assert any("duplicate" in l for l in p2), p2


def t_once_guard_survives_separate_namespaces():
    # each payload execs the runner in a NEW dict, so the registry must
    # live process-wide (on sys), not in the runner's globals
    import sys as _sys
    reg = getattr(_sys, "_d4_rom_hook_run_ids", None)
    assert reg is not None, "no process-wide run-id registry on sys"
    assert "pre-0-cccc" in reg, "registry does not hold executed ids"


def t_no_run_id_is_unguarded():
    # an old-style payload without an id still runs (each call)
    user, counter = _counter_hook("once_no_id")
    run_payload(TMP, "post", user, CTX_PATH)
    run_payload(TMP, "post", user, CTX_PATH)
    assert _count(counter) == 2, _count(counter)


def t_l2_base_exceptions():
    # KeyboardInterrupt / GeneratorExit are BaseException, not Exception
    user = os.path.join(TMP, "kbi.py")
    write(user, "raise KeyboardInterrupt('stop')\n")
    raised, _ = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised and raised.startswith("CAPTURE_ABORT: pre-record script failed -- "), raised
    assert "KeyboardInterrupt" in raised, raised
    raised, _ = run_payload(TMP, "post", user, CTX_PATH)
    assert raised and raised.startswith("D4_HOOK_ERROR post: KeyboardInterrupt"), raised
    write(user, "raise GeneratorExit()\n")
    raised, _ = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised and "GeneratorExit" in raised and raised.startswith("CAPTURE_ABORT:"), raised


def t_l3_post_marker_neutralised():
    user = os.path.join(TMP, "post_marker.py")
    write(user, "raise RuntimeError('CAPTURE_ABORT: sneaky')\n")
    raised, _ = run_payload(TMP, "post", user, CTX_PATH)
    assert raised is not None, "POST error must still be relayed"
    assert "CAPTURE_ABORT:" not in raised, "POST relay still carries the abort marker: %s" % raised
    assert "CAPTURE_ABORT -" in raised, raised


def t_l7_system_encoding_fallback():
    user = os.path.join(TMP, "latin1_pre.py")
    out_path = os.path.join(TMP, "latin1_out.txt")
    with open(user, "wb") as f:
        f.write(b"# caf\xe9 (saved as Windows-1252, not UTF-8)\nopen(%r, 'w').write('ok')\n" % out_path.encode("ascii"))
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised is None, "a non-UTF-8 (system encoding) file must still run: %s" % raised
    with open(out_path) as f:
        assert f.read() == "ok"


def t_l7_undecodable_aborts_clearly():
    user = os.path.join(TMP, "undecodable_pre.py")
    with open(user, "wb") as f:
        f.write(b"x = 1  # \x81\x8d\x8f\x90\x9d\n")
    raised, _ = run_payload(TMP, "pre", user, CTX_PATH)
    assert raised and raised.startswith("CAPTURE_ABORT: pre-record script failed -- "), raised
    assert "could not read" in raised, raised


def t_m04_reentrant_duplicate_skipped():
    # the id is claimed BEFORE the user's code runs, so a duplicate that
    # arrives while the user script is still running is skipped too
    user, counter = _counter_hook("reentrant")
    rid = "pre-0-reentrant"
    with open(user, "a") as f:
        f.write("g = {'__name__': 'd4_rom_hook_runner', 'D4_HOOK_KIND': 'pre', 'D4_HOOK_USER_PATH': %r, "
                "'D4_HOOK_CONTEXT_PATH': %r, 'D4_HOOK_RUN_ID': %r}\n" % (user, CTX_PATH, rid))
        f.write("exec(compile(open(%r).read(), %r, 'exec'), g)\n" % (RUNNER_PATH, RUNNER_PATH))
    raised, printed = run_payload(TMP, "pre", user, CTX_PATH, run_id=rid)
    assert raised is None, raised
    assert _count(counter) == 1, "re-entrant duplicate ran the user code again (%d)" % _count(counter)
    assert any("duplicate" in l for l in printed), printed


def t_m18_cap_keeps_recent_ids():
    g = load_runner_functions()
    claim = g["claim_run_id"]
    cap = g.get("RUN_ID_REGISTRY_CAP", 1000)
    import sys as _s
    if hasattr(_s, "_d4_rom_hook_run_ids"):
        delattr(_s, "_d4_rom_hook_run_ids")
    # fill to just below the cap so the trim happens between the claims below
    for i in range(cap - 1):
        assert claim("fill-%d" % i), "fresh id refused"
    recent = []
    for i in range(3):
        rid = "recent-%d" % i
        assert claim(rid), "fresh id refused"
        recent.append(rid)
        # interleave more fresh ids right after
        assert claim("between-%d" % i)
    for rid in recent:
        assert not claim(rid), "a recently claimed id ran again after the cap trimmed: %s" % rid
    assert not claim("between-2"), "the newest id was forgotten"
    import sys as _sys
    assert len(getattr(_sys, "_d4_rom_hook_run_ids")) <= cap, "registry grew past the cap"


def _t87_ctx_for(kind, ctx_path, user_name):
    """Runs a user file that dumps D4_CTX and returns the dict."""
    user = os.path.join(TMP, user_name)
    out_path = os.path.join(TMP, user_name + ".json")
    write(user, "import json\nwith open(%r, 'w') as f:\n    json.dump(D4_CTX, f)\n" % out_path)
    raised, printed = run_payload(TMP, kind, user, ctx_path)
    assert raised is None, "unexpected raise: %s" % raised
    with io.open(out_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _t87_write_last_video(folder, text):
    with io.open(os.path.join(folder, "_last_video.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def t_t87_video_path_post_only():
    video = u"D:\\rec\\\u30c6\u30b9\u30c8_front_back.mp4"
    _t87_write_last_video(TMP, video + u"\n")
    try:
        post = _t87_ctx_for("post", CTX_PATH, "t87_post.py")
        assert post.get("video_path") == video, post
        pre = _t87_ctx_for("pre", CTX_PATH, "t87_pre.py")
        assert "video_path" not in pre, pre
    finally:
        os.remove(os.path.join(TMP, "_last_video.txt"))


def t_t87_video_path_empty_when_unavailable():
    empty_state = tempfile.mkdtemp(prefix="t87_state_", dir=TMP)
    ctx_path = os.path.join(empty_state, "_hook_context.json")
    write(ctx_path, json.dumps({"axis": "FrontBack", "state_dir": empty_state}))
    post = _t87_ctx_for("post", ctx_path, "t87_post_missing.py")
    assert post.get("video_path") == "", post
    _t87_write_last_video(empty_state, u"   \n")
    post = _t87_ctx_for("post", ctx_path, "t87_post_blank.py")
    assert post.get("video_path") == "", post


def t_t87_video_path_context_file_cannot_inject():
    state = tempfile.mkdtemp(prefix="t87_inject_", dir=TMP)
    ctx_path = os.path.join(state, "_hook_context.json")
    write(ctx_path, json.dumps({"axis": "FrontBack", "state_dir": state, "video_path": "C:\\bogus.mp4"}))
    pre = _t87_ctx_for("pre", ctx_path, "t87_pre_inject.py")
    assert "video_path" not in pre, pre
    _t87_write_last_video(state, u"C:\\real\\take_left_right.mkv")
    post = _t87_ctx_for("post", ctx_path, "t87_post_inject.py")
    assert post.get("video_path") == "C:\\real\\take_left_right.mkv", post


def t_t87_video_path_falls_back_to_context_folder():
    state = tempfile.mkdtemp(prefix="t87_fallback_", dir=TMP)
    ctx_path = os.path.join(state, "_hook_context.json")  # never written: context_error
    _t87_write_last_video(state, u"C:\\v\\take_front_back.mp4")
    post = _t87_ctx_for("post", ctx_path, "t87_post_fallback.py")
    assert "context_error" in post, post
    assert post.get("video_path") == "C:\\v\\take_front_back.mp4", post


def t_t87_video_path_undecodable_is_empty():
    state = tempfile.mkdtemp(prefix="t87_bad_", dir=TMP)
    ctx_path = os.path.join(state, "_hook_context.json")
    write(ctx_path, json.dumps({"axis": "FrontBack", "state_dir": state}))
    with io.open(os.path.join(state, "_last_video.txt"), "wb") as f:
        f.write(b"D:\\rec\\\xe9t\xe9.mp4\n")  # Windows-1252 bytes, not UTF-8
    import locale
    saved = locale.getpreferredencoding
    # a machine whose system code page is Windows-1252 would decode this as
    # mojibake through read_text_file's fallback; the video path must not
    locale.getpreferredencoding = lambda *a, **k: "cp1252"
    try:
        post = _t87_ctx_for("post", ctx_path, "t87_post_bad.py")
    finally:
        locale.getpreferredencoding = saved
    assert post.get("video_path") == "", post


def t_t87_post_template_documents_video_path():
    with io.open(os.path.join(TEMPLATE_DIR, "d4_rom_post_record.py"), "r", encoding="ascii") as f:
        text = f.read()
    assert "video_path" in text, "post template does not mention video_path"
    with io.open(os.path.join(TEMPLATE_DIR, "d4_rom_pre_record.py"), "r", encoding="ascii") as f:
        assert "video_path" not in f.read(), "pre template must not offer video_path"


for _name, _fn in [
    ("T87: video_path in D4_CTX for POST only", t_t87_video_path_post_only),
    ("T87: video_path is '' when the file is missing or blank", t_t87_video_path_empty_when_unavailable),
    ("T87: the context file cannot inject video_path", t_t87_video_path_context_file_cannot_inject),
    ("T87: video_path found next to a missing context file", t_t87_video_path_falls_back_to_context_folder),
    ("T87: post template documents video_path, pre does not", t_t87_post_template_documents_video_path),
    ("T87 LOW-5: undecodable _last_video.txt gives video_path ''", t_t87_video_path_undecodable_is_empty),
    ("runner file exists, ASCII, no BOM", t_runner_exists),
    ("loading without D4_HOOK_KIND only defines functions", t_load_without_kind_runs_nothing),
    ("comment/blank-only rule", t_has_code_rule),
    ("templates are ASCII and comment-only", t_templates_are_ascii_comment_only),
    ("ok path prints D4_HOOK_OK and calls fake cmds", t_ok_path),
    ("D4_CTX visible with per-call kind/leg", t_ctx_visible),
    ("PRE error raises one-line CAPTURE_ABORT + prints traceback", t_pre_error_aborts),
    ("POST error relays D4_HOOK_ERROR, never CAPTURE_ABORT", t_post_error_warns_only),
    ("SyntaxError in PRE aborts with line number", t_syntax_error),
    ("sys.exit in user code is caught", t_system_exit_is_caught),
    ("user code runs in a fresh dict", t_fresh_dict),
    ("missing user file is skipped, no abort", t_missing_file_skipped),
    ("comment-only user file is skipped", t_comment_only_skipped),
    ("missing context file still runs with context_error", t_missing_context_still_runs),
    ("unknown kind raises without abort marker", t_unknown_kind_raises),
    ("UTF-8 BOM user file runs", t_utf8_bom_user_file),
    ("once-guard: same run id twice runs the user file once", t_once_guard_same_id_runs_once),
    ("once-guard: a different run id runs again", t_once_guard_different_id_runs_again),
    ("once-guard: PRE abort raised only by the first execution", t_once_guard_pre_raise_only_once),
    ("once-guard: registry is process-wide (sys), not per namespace", t_once_guard_survives_separate_namespaces),
    ("no run id: unguarded, runs every call", t_no_run_id_is_unguarded),
    ("L2: KeyboardInterrupt/GeneratorExit abort PRE, warn POST", t_l2_base_exceptions),
    ("L3: POST relay never carries the CAPTURE_ABORT: marker", t_l3_post_marker_neutralised),
    ("L7: non-UTF-8 file falls back to the system encoding", t_l7_system_encoding_fallback),
    ("L7: undecodable PRE file aborts with a clear message", t_l7_undecodable_aborts_clearly),
    ("M04: re-entrant duplicate while the user script runs is skipped", t_m04_reentrant_duplicate_skipped),
    ("M18: registry cap keeps recently claimed ids", t_m18_cap_keeps_recent_ids),
]:
    check(_name, _fn)

shutil.rmtree(TMP, ignore_errors=True)

failed = [r for r in results if not r[1]]
for name, ok, detail in results:
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, (" -- " + detail) if detail else ""))
print("%d passed, %d failed" % (len(results) - len(failed), len(failed)))
sys.exit(1 if failed else 0)
