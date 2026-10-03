"""Real Nix helper/cache/store integration; no mocks or global garbage collection.

Only this test's uniquely named, unreferenced output is removed. Nix's normal
liveness checks remain enabled. The other output must survive, so checking only
the first returned path cannot satisfy the regression.
"""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


REPO = Path(__file__).resolve().parents[2]
DAEMON = REPO / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon"
FIXTURE = REPO / "tests/fixtures/nix-daemon-local-flake"


@unittest.skipUnless(os.name == "posix", "Nix provisioning requires a POSIX host")
class NixDaemonCache(unittest.TestCase):
    def test_reacquires_a_removed_secondary_output(self):
        self.assertIsNotNone(shutil.which("nix"), "the Nix integration gate requires Nix")
        self.assertIsNotNone(shutil.which("nix-store"))
        with tempfile.TemporaryDirectory(prefix="rnc-", dir="/tmp") as directory:
            root = Path(directory) / "flake"
            root.mkdir()
            name = "repro-nix-cache-" + uuid.uuid4().hex
            flake = (FIXTURE / "flake.nix").read_text()
            start = flake.index("        hello-sh = ")
            end = flake.index("        default = ", start)
            flake = flake[:start] + f'''        hello-sh = pkgs.runCommand "{name}" {{
          outputs = [ "out" "support" ];
        }} ''
          mkdir -p "$out/bin" "$support"
          printf '%s\\n' '{name}' > "$out/bin/control"
          printf '%s\\n' '{name}-support' > "$support/control"
        '';
''' + flake[end:]
            (root / "flake.nix").write_text(flake)
            shutil.copyfile(FIXTURE / "flake.lock", root / "flake.lock")
            endpoint = Path(directory) / "d.sock"
            with (Path(directory) / "daemon.log").open("w+") as log:
                process = subprocess.Popen(
                    [sys.executable, str(DAEMON), "--socket-path", str(endpoint),
                     "--idle-exit-ms=120000"], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 5
                    while not endpoint.exists():
                        self.assertIsNone(process.poll(), "helper exited before readiness")
                        self.assertLess(time.monotonic(), deadline, "helper did not bind")
                        time.sleep(0.01)

                    def request():
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(90)
                            client.connect(str(endpoint))
                            payload = dict(action="resolve", selector=".#hello-sh^*",
                                           workspaceRoot=str(root), evaluateOnly=True)
                            client.sendall((json.dumps(payload) + "\n").encode())
                            with client.makefile("rb") as response:
                                result = json.loads(response.readline())
                            self.assertEqual(result["status"], "success", result)
                            return result

                    cold = request()
                    self.assertEqual(len(cold["paths"]), 2, cold)
                    primary, secondary = map(Path, cold["paths"])
                    self.assertEqual(primary.parent, Path("/nix/store"))
                    self.assertTrue(primary.name.endswith("-" + name))
                    self.assertEqual(secondary.parent, Path("/nix/store"))
                    self.assertTrue(secondary.name.endswith("-" + name + "-support"))
                    self.assertEqual((primary / "bin/control").read_text().strip(), name)
                    self.assertEqual((secondary / "control").read_text().strip(), name + "-support")
                    self.assertEqual(request(), cold, "warm request changed its evidence")

                    # Refuse to touch a rooted or referenced path, including if
                    # some other process unexpectedly acquired this private one.
                    for query in ("--roots", "--referrers"):
                        references = subprocess.check_output(
                            ["nix-store", "--query", query, str(secondary)], text=True)
                        self.assertEqual(references.strip(), "", references)
                    subprocess.run(["nix-store", "--delete", str(secondary)],
                                   check=True, capture_output=True, timeout=30)
                    self.assertFalse(secondary.exists())
                    self.assertTrue(primary.exists())

                    repaired = request()
                    self.assertEqual(repaired, cold)
                    self.assertTrue(secondary.exists(), "cached success named a deleted output")
                    self.assertEqual((secondary / "control").read_text().strip(), name + "-support")
                    self.assertEqual((primary / "bin/control").read_text().strip(), name)
                    self.assertIsNone(process.poll(), "recovery must use the same helper")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
