"""Real CLI/process regression; no mocks. Called by the Nim suite entrypoint.

The child publishes readiness only after installing its signal dispositions.
Cleanup kills both the wrapper and child on the unfixed implementation, so a
failed regression leaves no orphan. No provider/build wall-clock deadline is
imposed; once ready, signal delivery itself has a five-second budget.
"""
import json
import os
from pathlib import Path
import signal
import shutil
import resource
import subprocess
import sys
import tempfile
import time


def child():
    mode, ready = sys.argv[2:4]
    if mode == "handled":
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            signal.signal(sig, lambda received, frame: sys.exit(70 + received))
    else:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            signal.signal(sig, signal.SIG_DFL)
    pending = Path(ready + ".pending")
    pending.write_text(json.dumps({"pid": os.getpid(),
        "cwd": os.getcwd(), "argv": sys.argv[4:],
        "env": os.environ.get("EXEC_SIGNAL_VALUE"),
        "unset": os.environ.get("EXEC_SIGNAL_UNSET")}))
    pending.replace(ready)
    if mode == "normal":
        sys.exit(23)
    while True:
        signal.pause()


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    cli = str(Path(sys.argv[1]).resolve())
    probe = str(Path(__file__).resolve())
    with tempfile.TemporaryDirectory(prefix="repro-exec-signals-") as temp:
        project = Path(temp).resolve()
        (project / "repro.nim").write_text(
            'import repro_project_dsl\npackage fixture:\n'
            '  defaultToolProvisioning "path"\n'
            '  devEnv:\n'
            '    setEnv "EXEC_SIGNAL_VALUE", "activated value"\n'
            '    unsetEnv "EXEC_SIGNAL_UNSET"\n'
            '    prependPath "PATH", "tools"\n')
        tools = project / "tools"
        tools.mkdir()
        (tools / "signal-probe-python").symlink_to(sys.executable)
        env = dict(os.environ, EXEC_SIGNAL_UNSET="ambient",
            REPROBUILD_ACTION_CACHE_ROOT=str(project / "action-cache"),
            XDG_CACHE_HOME=str(project / "user-cache"),
            REPRO_ACTION_CACHE_SHM="0", REPRO_DAEMON="off",
            REPRO_PROVIDER_PARALLEL_BUILD="2",
            REPRO_NIM_COMPILER=shutil.which("nim"),
            REPRO_BOOTSTRAP_CC=shutil.which("cc"))
        shadow = project / "cwd-command-outside-path"
        shadow.write_text("#!/bin/sh\nexit 0\n")
        shadow.chmod(0o755)
        nonexecutable = tools / "non-executable-command"
        nonexecutable.write_text("#!/bin/sh\nexit 0\n")
        # Keep cwd out of the inherited PATH; only the recipe's tools entry
        # may resolve relative to the activated working directory.
        env["PATH"] = os.pathsep.join(entry for entry in env["PATH"].split(os.pathsep)
            if os.path.isabs(entry))
        for command in ("./command-that-does-not-exist",
                "cwd-command-outside-path", "non-executable-command"):
            missing = subprocess.run([cli, "exec", str(project), "--", command],
                env=env, capture_output=True, text=True)
            assert missing.returncode != 0, (command, "reported success")
            assert command in missing.stderr, missing.stderr
        # These are literal argv values; shell parsing must never touch them.
        arguments = ["", "two words", "quote'\"", "$HOME; *"]
        cases = [("normal", None, executable) for executable in
            (sys.executable, "signal-probe-python", "./tools/signal-probe-python")] + [(mode, sig, "signal-probe-python")
            for mode in ("handled", "default")
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT)]
        for number, (mode, sig, executable) in enumerate(cases):
            ready = project / ("ready-" + str(number))
            process = subprocess.Popen([cli, "exec", str(project), "--",
                executable, probe, "--child", mode, str(ready), *arguments],
                env=env, start_new_session=True)
            child_pid = None
            try:
                while not ready.exists():
                    if process.poll() is not None and not ready.exists():
                        raise AssertionError("CLI exited before child readiness")
                    time.sleep(0.02)
                report = json.loads(ready.read_text())
                child_pid = report["pid"]
                assert report["cwd"] == str(project), report
                assert report["argv"] == arguments, report
                assert report["env"] == "activated value", report
                assert report["unset"] is None, report
                if sig is not None:
                    # Signal the caller's PID, never the process group or child.
                    os.kill(process.pid, sig)
                status = process.wait(timeout=5)
                expected = 23 if mode == "normal" else (70 + sig if mode == "handled" else -sig)
                if status != expected:
                    try:
                        os.kill(child_pid, 0)
                        child_alive = True
                    except ProcessLookupError:
                        child_alive = False
                    raise AssertionError({"mode": mode, "signal": sig,
                        "status": status, "expected": expected,
                        "wrapper_pid": process.pid, "command_pid": child_pid,
                        "command_alive_after_wrapper_exit": child_alive})
                if sig is not None:
                    assert child_pid == process.pid, ("command did not replace repro", child_pid, process.pid)
                print("PASS", mode, sig, "status", status, flush=True)
            finally:
                # The group is private to this case; it also contains orphaned
                # children on the unfixed code. Always reap the direct child.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                if child_pid and child_pid != process.pid:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        child()
    else:
        main()
