r"""
D4 ROM Capture -- runner for the user's pre/post record scripts (T97).

Runs INSIDE Maya. rom_launcher.ps1 sends ONE line through send_to_maya.ps1
-Code (send_to_maya passes no script arguments, so the arguments travel as
the exec globals instead of a second wrapper file):

    exec(compile(open(r'<this file>').read(), r'<this file>', 'exec'),
         {'__name__': 'd4_rom_hook_runner', 'D4_HOOK_KIND': 'pre',
          'D4_HOOK_USER_PATH': r'<install root>\user_hooks\d4_rom_pre_record.py',
          'D4_HOOK_CONTEXT_PATH': r'<scripts>\state\_hook_context.json',
          'D4_HOOK_LEG_INDEX': 0, 'D4_HOOK_LEG_AXIS': 'FrontBack',
          'D4_HOOK_RUN_ID': 'pre-0-<guid>'})

D4_HOOK_RUN_ID is unique per hook step (kind, video, recording run): Maya's
command port executes every payload TWICE, so the runner remembers the ids
it already ran (process-wide, on sys) and skips the repeat -- the user's
script runs exactly once per call (see claim_run_id).

What it does:
  * reads the context file the launcher wrote before the run and builds the
    D4_CTX dict (run-level keys from the file + kind/leg_index/leg_axis of
    this call);
  * execs the user's file in a FRESH dict (nothing leaks between calls,
    nothing of this runner is visible to the user's code);
  * prints D4_HOOK_OK <kind> or D4_HOOK_ERROR <kind>: <traceback> to the
    Script Editor.

Why errors are RAISED, not printed: print() output never crosses Maya's
command port, only an exception's text does (see Get-NoteworthyMayaOutput
in rom_launcher_logic.ps1 and every CAPTURE_ABORT site in scripts\maya\).
So:
  * PRE fails  -> RuntimeError('CAPTURE_ABORT: pre-record script failed --
                  <msg>'): the launcher's existing CAPTURE_ABORT watcher
                  stops the run (Complete-Run -Aborted, taskbar restored).
  * POST fails -> RuntimeError('D4_HOOK_ERROR post: <msg>'): no abort
                  marker, so the launcher only logs it and carries on.
  * a missing or comment-only user file is skipped (one printed line, no
    error) -- the launcher normally adds no step for those at all.

Offline-testable: loading this file WITHOUT D4_HOOK_KIND in its globals
only defines the functions (tests/test_prepost_runner.py does that with a
fake maya.cmds). ASCII only.
"""

HOOK_ABORT_PREFIX = "CAPTURE_ABORT: pre-record script failed -- "


def hook_source_has_code(source):
    """True when at least one line is left after dropping blank lines and
    lines whose first non-blank character is '#'. Same rule as
    Get-HookState in rom_launcher_logic.ps1."""
    for line in source.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return True
    return False


def read_text_file(path):
    """UTF-8 (BOM allowed) first; a file saved in the system encoding
    (e.g. Windows-1252 from an old editor) still runs; anything neither
    can decode raises a clear ValueError."""
    import io
    import locale
    with io.open(path, "rb") as f:
        data = f.read()
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        pass
    fallback = locale.getpreferredencoding(False) or "ascii"
    try:
        return data.decode(fallback)
    except (UnicodeDecodeError, LookupError):
        raise ValueError("could not read %s: it is neither UTF-8 nor %s text -- save it as UTF-8" % (path, fallback))


def build_context(context_path, kind, leg_index, leg_axis):
    """D4_CTX for one call. Run-level keys come from the launcher's context
    file; kind, leg_index and leg_axis are this call's own. A missing or
    broken context file is reported in 'context_error' instead of failing
    the user's script over a tool-side problem."""
    import json
    ctx = {
        "kind": kind,
        "axis": None,
        "leg_axis": leg_axis,
        "leg_index": leg_index,
        "leg_count": None,
        "start_frame": None,
        "end_frame": None,
        "tool_version": None,
        "scripts_dir": None,
        "state_dir": None,
    }
    try:
        data = json.loads(read_text_file(context_path))
        if not isinstance(data, dict):
            raise ValueError("context file is not a JSON object")
        for key, value in data.items():
            if key in ("kind", "leg_index", "leg_axis"):
                continue
            ctx[key] = value
    except Exception as exc:
        ctx["context_error"] = "%s: %s" % (type(exc).__name__, exc)
    return ctx


def short_error_text(exc, user_path, tb):
    """One-line '<Type>: <msg> (line N)' for the relayed message. The full
    traceback is printed to the Script Editor separately."""
    import traceback
    lines = [l.strip() for l in traceback.format_exception_only(type(exc), exc) if l.strip()]
    text = lines[-1] if lines else type(exc).__name__
    line_no = None
    if isinstance(exc, SyntaxError):
        line_no = exc.lineno
    else:
        for frame in traceback.extract_tb(tb):
            if frame[0] == user_path:
                line_no = frame[1]
    if line_no:
        text = "%s (line %s)" % (text, line_no)
    return " ".join(text.split())


def run_user_hook(kind, user_path, ctx, out=None):
    """Runs one user hook file. Returns a dict:
        status: 'ok' | 'skipped' | 'error'
        line:   the D4_HOOK_* line that was printed
        message: one-line error text ('' unless status == 'error')
    Never raises for user-code errors (SystemExit included)."""
    import os
    import sys
    import traceback
    if out is None:
        def out(text):
            print(text)
    result = {"status": "ok", "line": "", "message": ""}
    if not os.path.isfile(user_path):
        result["status"] = "skipped"
        result["line"] = "D4_HOOK_SKIPPED %s: file not found: %s" % (kind, user_path)
        out(result["line"])
        return result
    try:
        source = read_text_file(user_path)
        if not hook_source_has_code(source):
            result["status"] = "skipped"
            result["line"] = "D4_HOOK_SKIPPED %s: no code in %s" % (kind, user_path)
            out(result["line"])
            return result
        try:
            import builtins as builtins_module
        except ImportError:
            import __builtin__ as builtins_module
        user_globals = {
            "__name__": "__d4_rom_%s_record__" % kind,
            "__file__": user_path,
            "__builtins__": builtins_module,
            "D4_CTX": ctx,
        }
        code = compile(source, user_path, "exec")
        exec(code, user_globals)
    except BaseException as exc:  # incl. SystemExit, KeyboardInterrupt, GeneratorExit
        tb = sys.exc_info()[2]
        result["status"] = "error"
        result["message"] = short_error_text(exc, user_path, tb)
        result["line"] = "D4_HOOK_ERROR %s: %s" % (kind, traceback.format_exc().rstrip())
        out(result["line"])
        return result
    result["line"] = "D4_HOOK_OK %s" % kind
    out(result["line"])
    return result


def relay_error_for(kind, result):
    """The exception text the launcher should see for a failed hook, or
    None when nothing must be raised. PRE errors carry the CAPTURE_ABORT
    marker; POST errors deliberately do not."""
    if result.get("status") != "error":
        return None
    if kind == "pre":
        return HOOK_ABORT_PREFIX + result["message"]
    # a POST message must never trip the launcher's CAPTURE_ABORT watcher
    return "D4_HOOK_ERROR %s: %s" % (kind, result["message"].replace("CAPTURE_ABORT:", "CAPTURE_ABORT -"))


RUN_ID_REGISTRY_ATTR = "_d4_rom_hook_run_ids"
RUN_ID_REGISTRY_CAP = 1000


def claim_run_id(run_id):
    """True the FIRST time this run id is seen in this Maya process, False
    on any repeat. Maya's command port executes every payload twice (~1 ms
    apart, same process), and a user's script must run once per hook
    call. Each payload execs this runner in a NEW dict, so the registry
    lives on the sys module (process-wide), created on first use. The id
    is recorded BEFORE the user's code runs, so a failing first run is not
    retried by the duplicate either."""
    import sys
    registry = getattr(sys, RUN_ID_REGISTRY_ATTR, None)
    if not isinstance(registry, list):
        # a list keeps claim order, so the cap drops only the OLDEST ids
        # (a set left by an earlier runner version is carried over)
        registry = list(registry) if isinstance(registry, set) else []
        setattr(sys, RUN_ID_REGISTRY_ATTR, registry)
    if run_id in registry:
        return False
    registry.append(run_id)
    if len(registry) > RUN_ID_REGISTRY_CAP:
        del registry[:len(registry) - RUN_ID_REGISTRY_CAP]
    return True


def main(params, out=None):
    """Entry point for the command-port payload. params = the exec globals
    the launcher passed (D4_HOOK_KIND, D4_HOOK_USER_PATH,
    D4_HOOK_CONTEXT_PATH, D4_HOOK_LEG_INDEX, D4_HOOK_LEG_AXIS,
    D4_HOOK_RUN_ID)."""
    kind = params.get("D4_HOOK_KIND")
    if kind not in ("pre", "post"):
        raise RuntimeError("D4_HOOK_ERROR: unknown hook kind %r" % (kind,))
    run_id = params.get("D4_HOOK_RUN_ID")
    if run_id and not claim_run_id(run_id):
        # the command port's duplicate execution: no second run, and no
        # second abort/error either (the first execution already raised)
        line = "D4_HOOK_SKIPPED %s duplicate: run id %s already ran" % (kind, run_id)
        if out is None:
            print(line)
        else:
            out(line)
        return {"status": "duplicate", "line": line, "message": ""}
    ctx = build_context(params.get("D4_HOOK_CONTEXT_PATH", ""), kind,
                        params.get("D4_HOOK_LEG_INDEX", 0),
                        params.get("D4_HOOK_LEG_AXIS"))
    result = run_user_hook(kind, params.get("D4_HOOK_USER_PATH", ""), ctx, out=out)
    relay = relay_error_for(kind, result)
    if relay:
        raise RuntimeError(relay)
    return result


if "D4_HOOK_KIND" in globals():
    main(globals())
