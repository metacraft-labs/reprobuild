"""Cold repro exec must resolve a recipe-local Nix tool in the caller's flake.

No mocks: the real CLI compiles the recipe/provider, the real Nix helper
realizes the fixture flake, and the declared executable prints its marker.
The consumer directory differs from the engine's compiler/library directory.
"""

import os
import re
import select
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "tests/fixtures/nix-daemon-local-flake"


@unittest.skipUnless(os.name == "posix", "Nix provisioning requires a POSIX host")
class DevEnvLocalFlakeRoot(unittest.TestCase):
    def assert_cold_exec(self, expression_file=False, imported_file=False):
        executable = Path(os.environ.get("REPRO_TEST_EXECUTABLE", REPO / "build/bin/repro"))
        self.assertTrue(executable.is_file(), f"build the real CLI first: {executable}")
        self.assertIsNotNone(shutil.which("nix"), "the Nix integration gate requires Nix")
        # Keep Unix socket names short even under the suite's long TMPDIR.
        with tempfile.TemporaryDirectory(prefix="repro-exec-local-flake-") as directory, \
                tempfile.TemporaryDirectory(prefix="rn-", dir="/tmp") as socket_directory:
            root = Path(directory)
            for name in ("flake.nix", "flake.lock"):
                shutil.copyfile(FIXTURE / name, root / name)
            provisioning = ('nixPackage "caller-expression", '
                            'executablePath = "bin/reprobuild-nix-daemon-fixture", '
                            'expressionFile = "tool.nix"' if expression_file else
                            'nixPackage ".#hello-sh", '
                            'executablePath = "bin/reprobuild-nix-daemon-fixture"')
            if expression_file:
                (root / "tool.nix").write_text('''let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  pin = lock.nodes.nixpkgs.locked;
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/${pin.owner}/${pin.repo}/archive/${pin.rev}.tar.gz";
    sha256 = pin.narHash;
  }) {};
in pkgs.writeShellScriptBin "reprobuild-nix-daemon-fixture" "echo reprobuild-nix-daemon-fixture"
''')
            if imported_file:
                flake = (root / "flake.nix").read_text()
                start = flake.index("text = ''")
                end = flake.index("'';", start) + 3
                (root / "flake.nix").write_text(
                    flake[:start] + "text = import ./marker.nix;" + flake[end:])
                (root / "marker.nix").write_text('"echo reprobuild-nix-daemon-fixture"')
            (root / "repro.nim").write_text('''import repro_project_dsl

package `caller-probe`:
  provisioning:
    PROVISIONING

package consumer:
  defaultToolProvisioning nix
  uses:
    "caller-probe"
  devEnv:
    setEnv("LOCAL_FLAKE_CONSUMER_READY", "yes")
'''.replace('PROVISIONING', provisioning))
            environment = os.environ.copy()
            sockets = Path(socket_directory)
            environment["REPROBUILD_NIX_DAEMON_SOCKET_DIR"] = str(sockets)

            def helper_identity():
                endpoints = list(sockets.glob("*.sock"))
                self.assertEqual(len(endpoints), 1, endpoints)
                endpoint = endpoints[0]
                pid = None
                if hasattr(socket, "SO_PEERCRED"):
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.connect(str(endpoint))
                        credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
                        pid = struct.unpack("3i", credentials)[0]
                else:
                    # The helper logs its PID when binding this private
                    # endpoint; use that identity on POSIX without SO_PEERCRED.
                    log = Path(str(endpoint) + ".log").read_text()
                    started = re.findall(r" pid (\d+): serving ", log)
                    self.assertTrue(started, log)
                    pid = int(started[-1])
                return endpoint.stat().st_ino, pid

            def stop_owned_helper():
                # This socket directory is private to this fixture. Kernel
                # peer credentials identify its helper, never a shared one.
                if list(sockets.glob("*.sock")):
                    _, pid = helper_identity()
                    # Observe exit before removing the helper's log/socket
                    # directory. Register before signalling so an immediate
                    # exit cannot be missed; neither wait has a time cutoff.
                    if hasattr(os, "pidfd_open"):
                        process = os.pidfd_open(pid)
                        try:
                            signal.pidfd_send_signal(process, signal.SIGTERM)
                            ready, _, _ = select.select([process], [], [])
                            self.assertEqual(ready, [process])
                        finally:
                            os.close(process)
                    elif hasattr(select, "kqueue"):
                        queue = select.kqueue()
                        try:
                            watch = select.kevent(
                                pid, filter=select.KQ_FILTER_PROC,
                                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                fflags=select.KQ_NOTE_EXIT)
                            queue.control([watch], 0, 0)
                            os.kill(pid, signal.SIGTERM)
                            events = queue.control(None, 1)
                            self.assertEqual(len(events), 1)
                            self.assertEqual(events[0].ident, pid)
                            self.assertTrue(events[0].fflags & select.KQ_NOTE_EXIT)
                        finally:
                            queue.close()
                    else:
                        self.fail("owned helper exit observation requires pidfd or kqueue")
            # Select independent activation state; changing the engine's
            # compilation cwd must never select a different project's flake.
            def execute(expected):
                completed = subprocess.run(
                    [str(executable), "exec", "--work-root", str(root / "activation"),
                     "--", "reprobuild-nix-daemon-fixture"],
                    cwd=root, env=environment, text=True, capture_output=True)
                self.assertEqual(completed.returncode, 0,
                                 completed.stdout + completed.stderr)
                self.assertEqual(completed.stdout.strip(), expected, completed.stderr)

            try:
                marker = "reprobuild-nix-daemon-fixture"
                execute(marker)
                helper = helper_identity()
                self.assertTrue((root / "activation").is_dir())
                execute(marker)
                self.assertEqual(helper_identity(), helper)
                # Keep the same selector/root and activation directory. The
                # helper runs outside the action monitor, so explicit mutable
                # local source must re-evaluate without a predicted cache key.
                changed = marker + "-edited"
                original_flake = (root / "flake.nix").read_bytes()
                original_lock = (root / "flake.lock").read_bytes()
                source = root / ("marker.nix" if imported_file else
                                 "tool.nix" if expression_file else "flake.nix")
                text = source.read_text()
                if expression_file or imported_file:
                    text = text.replace("echo " + marker, "echo " + changed)
                else:
                    text = text.replace("printf '%s\\n' " + marker,
                                        "printf '%s\\n' " + changed)
                self.assertNotEqual(text, source.read_text())
                source.write_text(text)
                if imported_file:
                    self.assertEqual((root / "flake.nix").read_bytes(), original_flake)
                    self.assertEqual((root / "flake.lock").read_bytes(), original_lock)
                execute(changed)
                self.assertEqual(helper_identity(), helper)
            finally:
                stop_owned_helper()

    def test_cold_exec_resolves_the_callers_local_flake_tool(self):
        self.assert_cold_exec()

    def test_cold_exec_forwards_the_tools_expression_file(self):
        self.assert_cold_exec(expression_file=True)

    def test_same_live_helper_rechecks_imported_content(self):
        self.assert_cold_exec(imported_file=True)


if __name__ == "__main__":
    unittest.main()
