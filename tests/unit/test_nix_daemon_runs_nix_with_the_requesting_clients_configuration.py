"""The shared Nix helper runs each request's ``nix`` with that request's Nix
configuration, never with its own.

The helper (``tools/reprobuild-nix-daemon``) is shared by every reprobuild
process of the user and outlives the process that started it. It used to run
every ``nix`` with its own environment, so a client's ``NIX_CONFIG`` -- on CI
an ``!include`` of the file the job's credential broker keeps re-minting the
GitHub token into -- never reached the ``nix`` that fetched for it. The fetch
presented whichever credential the helper's starter had, or none, and GitHub
answered HTTP 401 "Bad credentials" (reprobuild-pm issue
``2026-11-10-repro-daemon-nix-fetch-gets-http-401-on-a-persistent-macos-runner.md``).

Each request now names the client's value of every Nix configuration
variable (``nixEnvironment``; ``repro_core/nix_configuration_env`` composes
it) and the helper runs that request's commands with exactly those values.

WHY A FAKE ``nix``. The property under test is which environment the
helper hands the ``nix`` process it starts; what a real ``nix`` then does
with a credential needs network access to GitHub and a real token, neither
of which a unit test may assume. So a stand-in ``nix`` / ``nix-build`` on
``PATH`` records the Nix configuration variables it was started with and
prints a store-like output directory. Everything above that process boundary
is the real helper: request parsing, ``ResolveCache``, ``run_command``'s
``subprocess`` launch and, in the last case, the helper running as its own
process behind its socket, started with a configuration of its own.
"""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = (Path(__file__).resolve().parents[2]
          / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon")

NAMES = ("NIX_CONFIG", "NIX_USER_CONF_FILES", "NIX_CONF_DIR",
         "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS")

# What the process that started the helper had: a credential from an earlier
# job. No request may ever be run with it.
STALE = "access-tokens = github.com=stale-token-of-the-starting-job"

FAKE_NIX = """#!{python}
import json, os, sys
from pathlib import Path
names = {names!r}
selector = sys.argv[-1]
with open(os.environ["FAKE_NIX_RECORD"], "a", encoding="utf-8") as record:
    record.write(json.dumps({{
        "selector": selector,
        "env": {{name: os.environ.get(name) for name in names}},
    }}) + "\\n")
if "fails" in selector:
    sys.stderr.write("error: unable to download: HTTP error 401\\n")
    sys.exit(1)
out = Path(os.environ["FAKE_NIX_STORE"]) / selector.replace("#", "-").replace("/", "-")
out.mkdir(parents=True, exist_ok=True)
print(out)
"""


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "reprobuild_nix_daemon_client_config", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def client_environment(**values):
    """A request's ``nixEnvironment`` as the Nim client composes it: every
    name, ``None`` (JSON null) for one the client does not set."""
    return {name: values.get(name) for name in NAMES}


class HelperRunsNixWithTheClientsConfiguration(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rnd-nixcfg-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / "ws"
        self.workspace.mkdir()
        (self.workspace / "default.nix").write_text("{}\n", encoding="utf-8")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("nix", "nix-build"):
            path = self.bin / tool
            path.write_text(FAKE_NIX.format(python=sys.executable, names=NAMES),
                            encoding="utf-8")
            path.chmod(0o755)
        self.record = self.root / "record.jsonl"
        # The helper's OWN environment: a fake nix first on PATH, and a Nix
        # configuration of its own that must never reach a request's nix.
        self.helper_env = {
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            "FAKE_NIX_RECORD": str(self.record),
            "FAKE_NIX_STORE": str(self.root / "store"),
            "NIX_CONFIG": STALE,
            "NIX_USER_CONF_FILES": str(self.root / "stale-user.conf"),
            "XDG_CONFIG_HOME": str(self.root / "stale-xdg"),
        }

    def in_process(self):
        """The helper module, with its own environment set to
        ``helper_env`` for the duration of the test."""
        saved = {name: os.environ.get(name) for name in self.helper_env}
        for name in NAMES:
            saved.setdefault(name, os.environ.get(name))

        def restore():
            for name, value in saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        self.addCleanup(restore)
        os.environ.update(self.helper_env)
        return load_helper()

    def records(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in
                self.record.read_text(encoding="utf-8").splitlines()]

    def request(self, helper, cache, selector, nix_environment=None,
                expression=False):
        payload = {"action": "resolve", "selector": selector,
                   "workspaceRoot": str(self.workspace)}
        if expression:
            payload["expressionFile"] = "default.nix"
        if nix_environment is not None:
            payload["nixEnvironment"] = nix_environment
        # A Nix failure raises out of ``response_for``; the server answers
        # it as an error (``Server.finish``), and so does this harness.
        try:
            return helper.response_for(json.dumps(payload).encode(), cache)
        except Exception as exc:
            return {"status": "error", "error": str(exc)}

    def test_each_request_runs_nix_with_its_own_credential(self):
        helper = self.in_process()
        cache = helper.ResolveCache()
        first = self.request(helper, cache, "nixpkgs#first", client_environment(
            NIX_CONFIG="!include /job-one/nix-access-tokens.conf"))
        second = self.request(helper, cache, "nixpkgs#second", client_environment(
            NIX_CONFIG="!include /job-two/nix-access-tokens.conf",
            XDG_CONFIG_HOME="/job-two/xdg"))
        self.assertEqual(first["status"], "success", first)
        self.assertEqual(second["status"], "success", second)
        seen = {r["selector"]: r["env"] for r in self.records()}
        self.assertEqual(seen["nixpkgs#first"], client_environment(
            NIX_CONFIG="!include /job-one/nix-access-tokens.conf"))
        self.assertEqual(seen["nixpkgs#second"], client_environment(
            NIX_CONFIG="!include /job-two/nix-access-tokens.conf",
            XDG_CONFIG_HOME="/job-two/xdg"))

    def test_a_variable_the_client_does_not_set_is_unset_not_the_helpers(self):
        helper = self.in_process()
        cache = helper.ResolveCache()
        # Both forms: the null a current client sends, and a request that
        # carries no ``nixEnvironment`` at all. Neither inherits the helper's.
        self.request(helper, cache, "nixpkgs#nulls", client_environment())
        self.request(helper, cache, "nixpkgs#absent")
        # And the never-cached route, ``nix-build`` of an expression file.
        self.request(helper, cache, "expr", client_environment(
            NIX_CONFIG="!include /job/nix-access-tokens.conf"), expression=True)
        seen = {r["selector"]: r["env"] for r in self.records()}
        self.assertEqual(seen["nixpkgs#nulls"], client_environment())
        self.assertEqual(seen["nixpkgs#absent"], client_environment())
        self.assertEqual(
            seen[str((self.workspace / "default.nix").resolve())],
            client_environment(NIX_CONFIG="!include /job/nix-access-tokens.conf"))

    def test_a_failure_names_the_configuration_source_and_not_its_value(self):
        helper = self.in_process()
        cache = helper.ResolveCache()
        secret = "access-tokens = github.com=ghs_secret_value"
        answer = self.request(helper, cache, "nixpkgs#fails",
                              client_environment(NIX_CONFIG=secret))
        self.assertEqual(answer["status"], "error", answer)
        self.assertIn("HTTP error 401", answer["error"])
        self.assertIn("the requesting client's NIX_CONFIG", answer["error"])
        self.assertIn("XDG_CONFIG_HOME", answer["error"])
        self.assertNotIn("ghs_secret_value", answer["error"])
        # A failed resolution is not cached: the next client resolves with
        # its own configuration.
        retried = self.request(helper, cache, "nixpkgs#fails",
                               client_environment(NIX_CONFIG="other"))
        self.assertEqual(retried["status"], "error")
        self.assertEqual([r["env"]["NIX_CONFIG"] for r in self.records()],
                         [secret, "other"])

    def test_only_nix_configuration_variables_are_accepted(self):
        helper = self.in_process()
        cache = helper.ResolveCache()
        for bad in ({"LD_PRELOAD": "/evil.so"}, {"NIX_CONFIG": 7}, ["NIX_CONFIG"]):
            answer = self.request(helper, cache, "nixpkgs#refused", bad)
            self.assertEqual(answer["status"], "error", (bad, answer))
        self.assertEqual(self.records(), [],
                         "a refused request reached nix")

    def test_a_running_helper_uses_each_clients_configuration_not_its_starters(self):
        # The helper as it runs in production: its own process, started with
        # a Nix configuration of its own (``STALE``), serving two clients in
        # turn over its socket.
        socket_path = self.root / "helper.sock"
        env = dict(os.environ)
        env.update(self.helper_env)
        helper = subprocess.Popen(
            [sys.executable, str(HELPER), "--idle-exit-ms=60000",
             f"--socket-path={socket_path}"],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)

        def stop():
            if helper.poll() is None:
                helper.send_signal(signal.SIGTERM)
                try:
                    helper.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    helper.kill()
                    helper.wait()
        self.addCleanup(stop)

        def exchange(payload):
            deadline = time.monotonic() + 60
            while True:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    client.connect(str(socket_path))
                    break
                except OSError:
                    client.close()
                    if helper.poll() is not None:
                        self.fail(f"the helper exited {helper.returncode}")
                    if time.monotonic() > deadline:
                        self.fail("the helper never accepted")
                    time.sleep(0.05)
            with client:
                client.sendall((json.dumps(payload) + "\n").encode())
                data = b""
                while not data.endswith(b"\n"):
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    data += chunk
            return json.loads(data)

        for job in ("one", "two"):
            answer = exchange({
                "action": "resolve", "selector": f"nixpkgs#job-{job}",
                "workspaceRoot": str(self.workspace),
                "nixEnvironment": client_environment(
                    NIX_CONFIG=f"!include /job-{job}/nix-access-tokens.conf"),
            })
            self.assertEqual(answer["status"], "success", answer)
        seen = {r["selector"]: r["env"] for r in self.records()}
        for job in ("one", "two"):
            self.assertEqual(seen[f"nixpkgs#job-{job}"], client_environment(
                NIX_CONFIG=f"!include /job-{job}/nix-access-tokens.conf"))


if __name__ == "__main__":
    unittest.main()
