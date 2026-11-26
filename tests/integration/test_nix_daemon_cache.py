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
import platform
import shutil
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


@unittest.skipUnless(os.name == "posix", "the Nix helper serves only on POSIX hosts")
class NixDaemonFileTransportIsNeverCached(unittest.TestCase):
    """A selector fetched over the ``file`` transport is evaluated every time.

    Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3 item 4: a selector
    that names the client's own files can change under the same selector, so
    the helper never answers it from its cache. The helper used to decide
    "local" from a list of prefixes (``path:``, ``file:``, ``git+file:``) and
    took ``tarball+file:``, ``file+file:``, ``hg+file:`` and a bare relative
    path such as ``sub.d#…`` (which Nix reads as a path) for remote ones:
    after the tarball was rewritten, the same request was answered from the
    cache with the old tarball's store path.

    Mock justification: as for ``NixDaemonCache`` above, the host ``nix`` is a
    script. It "realises" a store path named after the current bytes of the
    tarball the selector names, so a stale cached answer is visible as the
    old name; a real ``nix build`` would need a store and a builder. The
    helper, its socket, its cache and the tarball on disk are real.

    Regression test for reprobuild-pm issue
    ``2026-11-18-nix-evaluation-daemon-caches-local-file-selectors-it-takes-for-remote.md``.
    """

    def test_a_rewritten_file_transport_source_is_never_served_stale(self):
        with tempfile.TemporaryDirectory(prefix="rnf-", dir="/tmp") as directory:
            directory = Path(directory)
            root = directory / "workspace"
            root.mkdir()
            (root / "flake.nix").write_text("{ outputs = _: {}; }\n")
            source = directory / "source"
            source.mkdir()
            store = directory / "store"
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            fake_nix = fake_bin / "nix"
            # The output is named after the bytes of the file the selector's
            # URL names, as a real evaluation of that source would differ.
            fake_nix.write_text(
                f"#!{sys.executable}\n"
                "import hashlib, os, sys, urllib.parse\n"
                "ref = next(a for a in sys.argv[1:] if '#packages.' in a)\n"
                "base = ref.split('#')[0]\n"
                "path = (urllib.parse.urlparse(base).path if '://' in base\n"
                "        else os.path.join(os.getcwd(), base, 'flake.nix'))\n"
                "digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()[:12]\n"
                f"out = os.path.join({str(store)!r}, digest)\n"
                "os.makedirs(out, exist_ok=True)\n"
                "print(out)\n")
            fake_nix.chmod(0o755)

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
                                           workspaceRoot=str(root), evaluateOnly=True)
                            client.sendall((json.dumps(payload) + "\n").encode())
                            with client.makefile("rb") as response:
                                result = json.loads(response.readline())
                            self.assertEqual(result["status"], "success", result)
                            return result["paths"]

                    # A bare relative path that is not shaped like a registry
                    # name is a path to Nix (relative to the workspace), too.
                    (root / "sub.d").mkdir()
                    for scheme, name in (("tarball+file", "f.tar.gz"),
                                         ("file+file", "f.bin"),
                                         ("hg+file", "repo"),
                                         ("git+file", "checkout"),
                                         ("", "sub.d")):
                        with self.subTest(scheme=scheme or "bare relative path"):
                            if scheme:
                                target = source / name
                                selector = f"{scheme}://{target}#packages.x86_64-linux.default"
                            else:
                                target = root / name / "flake.nix"
                                selector = f"{name}#packages.x86_64-linux.default"
                            target.write_bytes(b"one " + scheme.encode())
                            first = request(selector)
                            target.write_bytes(b"two " + scheme.encode())
                            second = request(selector)
                            self.assertNotEqual(
                                second, first,
                                f"{selector}: the rewritten source was served from the cache")
                    self.assertIsNone(process.poll(), "the helper must survive the requests")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)


def host_nix_system() -> str:
    """The Nix system string of this host (``x86_64-linux``, ...)."""
    machine = platform.machine().lower()
    cpu = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    kernel = "darwin" if sys.platform == "darwin" else "linux"
    return f"{cpu}-{kernel}"


def path_fallback_flake(tag: str, system: str) -> str:
    """A flake whose default package is a derivation named ``tag``.

    The store path names the bytes that were evaluated, so an answer served
    from the helper's cache after a rewrite is visible as the old name. It
    builds offline with ``/bin/sh`` and no inputs.
    """
    return (
        "{ outputs = _: { packages.%s.default = derivation {"
        " name = \"%s\"; system = \"%s\"; builder = \"/bin/sh\";"
        " args = [ \"-c\" \"echo %s > $out\" ]; }; }; }\n"
        % (system, tag, system, tag))


@unittest.skipUnless(os.name == "posix", "the Nix helper serves only on POSIX hosts")
@unittest.skipUnless(shutil.which("nix"), "needs `nix` on PATH: what is under test is "
                     "where Nix itself reads a selector it rejects as a URL")
class NixDaemonPathFallbackIsNeverCached(unittest.TestCase):
    """A selector Nix falls back to reading as a workspace path is never cached.

    Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3 item 4. When Nix
    rejects a selector it first parsed as a URL -- its URL parser rejects
    ``https://h:0/x#...`` (port out of range) on every version, and Nix
    2.34's fetcher also rejects ``github:o#...`` (no repository) -- it reads
    the text before the first ``?`` or ``#`` as a path relative to its
    working directory, which the helper sets to the request's workspace.
    The helper used to decide "remote" from the selector text alone, so with
    a flake at ``<workspace>/github:o`` it cached the first answer and served
    it after the flake was rewritten. The helper now also classifies a
    selector local when such a fallback path exists in the workspace.

    Uses REAL Nix, deliberately: what is under test is how Nix itself reads
    the selector, and that depends on the Nix version (the fetcher-rejection
    fallback is 2.34.x only). A script standing in for ``nix`` would encode
    the assumption under test. Each selector is first built directly, the
    way the helper builds it; a version that does not read it as the
    workspace path skips that selector with the reason, and the port-0 URL,
    whose fallback every version has, must not be skipped that way. The
    builds are two trivial offline derivations per selector, left in the
    host store for its garbage collector.
    """

    SELECTORS = (
        # URL-parser rejection: falls back on every Nix version.
        ("https://h:0/x", True),
        # Fetcher rejection: falls back on Nix 2.34.x only.
        ("github:o", False),
    )

    def nix_build(self, selector: str, cwd: Path):
        with tempfile.TemporaryDirectory(prefix="nix-data-") as data_home:
            env = dict(os.environ, NIX_DATA_HOME=data_home)
            return subprocess.run(
                ["nix", "--extra-experimental-features", "nix-command flakes",
                 "build", "--no-link", "--print-out-paths", "--", selector],
                cwd=str(cwd), env=env, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False)

    def test_a_rewritten_path_fallback_flake_is_never_served_stale(self):
        system = host_nix_system()
        with tempfile.TemporaryDirectory(prefix="rnq-", dir="/tmp") as directory:
            directory = Path(directory)
            version = subprocess.run(["nix", "--version"], text=True,
                                     stdout=subprocess.PIPE, check=False).stdout.strip()

            # Control: this host's Nix can build the trivial flake at all.
            # Without it, every skip below could be a broken Nix rather than
            # a version without the fallback.
            control = directory / "control"
            control.mkdir()
            (control / "flake.nix").write_text(path_fallback_flake("control", system))
            built = self.nix_build(f"path:{control}#packages.{system}.default", directory)
            if built.returncode != 0:
                self.skipTest(f"{version} cannot build a trivial offline flake here: "
                              f"{built.stderr.strip()[-500:]}")

            endpoint = directory / "d.sock"
            with (directory / "daemon.log").open("w+") as log:
                process = subprocess.Popen(
                    [sys.executable, str(DAEMON), "--socket-path", str(endpoint),
                     "--idle-exit-ms=120000"], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 5
                    while not endpoint.exists():
                        self.assertIsNone(process.poll(), "helper exited before readiness")
                        self.assertLess(time.monotonic(), deadline, "helper did not bind")
                        time.sleep(0.01)

                    def request(selector, root):
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(300)
                            client.connect(str(endpoint))
                            payload = dict(action="resolve", selector=selector,
                                           workspaceRoot=str(root))
                            client.sendall((json.dumps(payload) + "\n").encode())
                            with client.makefile("rb") as response:
                                result = json.loads(response.readline())
                            self.assertEqual(result["status"], "success", result)
                            return result["paths"]

                    for index, (prefix, every_version) in enumerate(self.SELECTORS):
                        selector = f"{prefix}#packages.{system}.default"
                        with self.subTest(selector=selector):
                            root = directory / f"workspace-{index}"
                            flake = root / prefix
                            flake.mkdir(parents=True)
                            tag = f"fallback-{index}"
                            (flake / "flake.nix").write_text(path_fallback_flake(tag + "-probe", system))
                            probe = self.nix_build(selector, root)
                            if probe.returncode != 0 or not probe.stdout.strip().endswith(
                                    tag + "-probe"):
                                detail = probe.stderr.strip()[-500:]
                                if every_version:
                                    self.fail(f"{version} did not read {selector!r} as "
                                              f"<workspace>/{prefix}: {detail}")
                                self.skipTest(f"{version} does not read {selector!r} as "
                                              f"<workspace>/{prefix}: {detail}")

                            (flake / "flake.nix").write_text(path_fallback_flake(tag + "-one", system))
                            first = request(selector, root)
                            self.assertTrue(first[0].endswith(tag + "-one"), first)
                            (flake / "flake.nix").write_text(path_fallback_flake(tag + "-two", system))
                            second = request(selector, root)
                            self.assertNotEqual(
                                second, first,
                                f"{selector}: the rewritten <workspace>/{prefix} flake was "
                                "served from the cache")
                            self.assertTrue(second[0].endswith(tag + "-two"), second)
                    self.assertIsNone(process.poll(), "the helper must survive the requests")
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
