"""A cached Nix resolution whose secondary output is gone is re-acquired.

Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3: the helper's response
cache answers a repeated request without evaluating, but a cached answer whose
store paths no longer exist must be re-acquired through Nix instead of being
returned as a stale success.

The request uses a REMOTE, CONTENT-LOCKED selector (a pinned revision and NAR
hash) on purpose. The helper never answers a local-flake selector (``.#…``,
``path:``, …) from its cache (``is_mutable_local_nix_selector``), so a case
built on one evaluates on every request and passes whether or not the cache
checks its paths: this case used to do exactly that, and could not fail.
Edge-Derived-Identities.md §7 keeps content-locked remote selectors cacheable;
whether an UNLOCKED one (``nixpkgs#…`` resolved through the registry) may be
cached is still undecided, so this case does not depend on it.

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
SELECTOR = ("github:NixOS/nixpkgs/0123456789abcdef0123456789abcdef01234567"
            "?narHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            "#repro-two-output-tool^*")


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


@unittest.skipUnless(os.name == "posix", "the Nix helper serves only on POSIX hosts")
class NixDaemonSelectorStaysPure(unittest.TestCase):
    """A selector is evaluated in pure mode, and a request cannot turn that off.

    Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §2.2. The helper puts a
    request's selector on ``nix build``'s command line, and Nix reads a
    leading ``-`` there as a flag. A request whose selector was ``--impure``
    therefore made the helper evaluate the workspace flake (``nix build``'s
    default installable) impurely, against the environment of whichever
    client started the shared helper, and cached the answer under a key that
    looked remote. The request also brings its own Nix configuration, and
    three settings in it could undo pure evaluation: ``accept-flake-config``
    (the flake's ``nixConfig`` then sets ``pure-eval = false``),
    ``allow-unsafe-native-code-during-evaluation`` (``builtins.exec`` runs
    with the helper's environment) and ``plugin-files``. The helper pins all
    of them, and ``pure-eval`` itself, on the command line, which overrides
    the configuration. A flake setting the user once saved as trusted
    (``trusted-settings.json``) applies despite ``accept-flake-config``, so
    each command also gets an empty ``NIX_DATA_HOME``.

    Mock justification: as for ``NixDaemonCache`` above, the host ``nix`` is
    a script that records its argv. What is under test is which command the
    helper runs, or that it runs none; a real ``nix`` would show the impure
    answer too, but needs a store and a builder this case does not.

    Regression test for reprobuild-pm issue
    ``2026-11-16-nix-evaluation-daemon-does-not-pin-pure-evaluation-for-a-selector.md``.
    """

    def test_an_option_shaped_selector_is_refused_and_selectors_are_pinned_pure(self):
        with tempfile.TemporaryDirectory(prefix="rnp-", dir="/tmp") as directory:
            directory = Path(directory)
            root = directory / "workspace"
            root.mkdir()
            (root / "flake.nix").write_text("{ outputs = _: {}; }\n")
            out = directory / "store" / "out"
            invocations = directory / "nix-invocations"
            data_homes = directory / "nix-data-homes"
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            fake_nix = fake_bin / "nix"
            fake_nix.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                f"with open({str(invocations)!r}, 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                f"with open({str(data_homes)!r}, 'a') as log:\n"
                "    home = os.environ.get('NIX_DATA_HOME')\n"
                "    log.write(json.dumps([home, home is not None and os.path.isdir(home)\n"
                "                          and not os.listdir(home)]) + '\\n')\n"
                f"os.makedirs({str(out)!r}, exist_ok=True)\n"
                f"print({str(out)!r})\n")
            fake_nix.chmod(0o755)

            def argvs():
                if not invocations.exists():
                    return []
                return [json.loads(line) for line in invocations.read_text().splitlines()]

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

                    def request(selector):
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(30)
                            client.connect(str(endpoint))
                            payload = dict(action="resolve", selector=selector,
                                           workspaceRoot=str(root))
                            client.sendall((json.dumps(payload) + "\n").encode())
                            with client.makefile("rb") as response:
                                return json.loads(response.readline())

                    for hostile in ("--impure", "-L", "--option"):
                        result = request(hostile)
                        self.assertEqual(result["status"], "error",
                                         f"selector {hostile!r} reached nix: {result}")
                        self.assertEqual(argvs(), [],
                                         f"selector {hostile!r} ran nix as {argvs()}")

                    # Control: an ordinary selector is resolved, so the
                    # refusals above are not a helper that resolves nothing.
                    result = request(SELECTOR)
                    self.assertEqual(result["status"], "success", result)
                    [argv] = argvs()
                    self.assertNotIn("--impure", argv)
                    self.assertEqual(argv[-2:], ["--", SELECTOR],
                                     f"selector not after an end-of-options marker: {argv}")
                    pins = {argv[i + 1]: argv[i + 2] for i, arg in enumerate(argv[:-2])
                            if arg == "--option"}
                    self.assertEqual(pins, {
                        "pure-eval": "true",
                        "accept-flake-config": "false",
                        "allow-unsafe-native-code-during-evaluation": "false",
                        "plugin-files": "",
                    }, f"pure evaluation is not pinned: {argv}")
                    # Saved flake settings (``trusted-settings.json`` in
                    # Nix's data directory) apply even with
                    # ``accept-flake-config`` false, so the command gets a
                    # fresh, empty data directory of its own.
                    [[home, empty]] = [json.loads(line) for line in
                                       data_homes.read_text().splitlines()]
                    self.assertIsNotNone(home, "NIX_DATA_HOME is not set")
                    self.assertTrue(empty, f"NIX_DATA_HOME {home} is not a fresh empty directory")
                    self.assertFalse(Path(home).exists(), "the data directory outlived the command")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
