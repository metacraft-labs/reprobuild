"""A cached Nix resolution whose secondary output is gone is re-acquired.

Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3: the helper's response
cache answers a repeated request without evaluating, but a cached answer whose
store paths no longer exist must be re-acquired through Nix instead of being
returned as a stale success.

The request uses a REMOTE selector (``nixpkgs#…``) on purpose. The helper never
answers a local-flake selector (``.#…``, ``path:``, …) from its cache
(``is_mutable_local_nix_selector``), so a case built on one evaluates on every
request and passes whether or not the cache checks its paths: this case used to
do exactly that, and could not fail.

Mock justification: the one thing replaced is the host ``nix`` executable,
with a script on ``PATH`` that records each invocation and "realises" two
outputs by creating them. Counting invocations is the only way to observe the
helper's cache decision directly -- a real ``nix build`` of an already-built
path is not distinguishable from a cache hit by its result -- and a real remote
selector would need the network and a substituter. Everything else is real:
the helper runs as its own process, is reached over its Unix socket, and its
cache sees the real filesystem when the output is removed.

Only the SECOND output is removed and the first must survive, so a cache that
checked only the first returned path cannot satisfy the case.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon"
SELECTOR = "nixpkgs#repro-two-output-tool^*"


@unittest.skipUnless(os.name == "posix", "the Nix helper serves only on POSIX hosts")
class NixDaemonCache(unittest.TestCase):
    def test_reacquires_a_removed_secondary_output(self):
        with tempfile.TemporaryDirectory(prefix="rnc-", dir="/tmp") as directory:
            directory = Path(directory)
            root = directory / "workspace"
            root.mkdir()
            (root / "flake.nix").write_text("{ outputs = _: {}; }\n")
            primary = directory / "store" / "out"
            secondary = directory / "store" / "support"
            invocations = directory / "nix-invocations"
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            fake_nix = fake_bin / "nix"
            # Each run realises both outputs, as `nix build` does for `^*`,
            # and prints them primary first. The test's own interpreter runs
            # it, so it needs no other tool on the action's declared PATH.
            fake_nix.write_text(
                f"#!{sys.executable}\n"
                "import os\n"
                f"with open({str(invocations)!r}, 'a') as log:\n"
                "    log.write('invoked\\n')\n"
                f"for path in ({str(primary)!r}, {str(secondary)!r}):\n"
                "    os.makedirs(path, exist_ok=True)\n"
                "    print(path)\n")
            fake_nix.chmod(0o755)

            def evaluations():
                if not invocations.exists():
                    return 0
                return invocations.read_text().count("invoked")

            env = dict(os.environ)
            env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
            endpoint = directory / "d.sock"
            with (directory / "daemon.log").open("w+") as log:
                process = subprocess.Popen(
                    [sys.executable, str(DAEMON), "--socket-path", str(endpoint),
                     "--idle-exit-ms=120000"], stdout=log, stderr=log, env=env)
                try:
                    deadline = time.monotonic() + 5
                    while not endpoint.exists():
                        self.assertIsNone(process.poll(), "helper exited before readiness")
                        self.assertLess(time.monotonic(), deadline, "helper did not bind")
                        time.sleep(0.01)

                    def request():
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(30)
                            client.connect(str(endpoint))
                            payload = dict(action="resolve", selector=SELECTOR,
                                           workspaceRoot=str(root), evaluateOnly=True)
                            client.sendall((json.dumps(payload) + "\n").encode())
                            with client.makefile("rb") as response:
                                result = json.loads(response.readline())
                            self.assertEqual(result["status"], "success", result)
                            return result

                    cold = request()
                    self.assertEqual(cold["paths"], [str(primary), str(secondary)], cold)
                    self.assertEqual(evaluations(), 1)

                    # Control: with both outputs present the selector is
                    # answered from the cache. Without this, the count below
                    # would also be reached by a helper that never caches.
                    self.assertEqual(request(), cold, "warm request changed its evidence")
                    self.assertEqual(evaluations(), 1, "a warm remote request evaluated")

                    secondary.rmdir()
                    self.assertTrue(primary.exists())

                    repaired = request()
                    self.assertEqual(repaired, cold)
                    self.assertEqual(evaluations(), 2,
                                     "cached success named a deleted output")
                    self.assertTrue(secondary.exists())

                    # The re-acquired answer is cached again.
                    self.assertEqual(request(), cold)
                    self.assertEqual(evaluations(), 2)
                    self.assertIsNone(process.poll(), "recovery must use the same helper")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
