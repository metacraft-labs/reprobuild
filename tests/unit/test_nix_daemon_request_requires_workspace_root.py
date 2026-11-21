"""A resolve request names its ``workspaceRoot``; the Nix helper never guesses it.

The helper is shared and runs from ``/`` (it leaves its launcher's directory,
see ``main``), so its own working directory says nothing about any request.
A request without a root used to fall back to that directory, which answered
for whichever client had started the helper, and after the chdir it would
have resolved a ``.#`` selector against ``/`` without a word. A missing or
relative root is therefore refused, the way a missing selector is.

``run_command`` is the helper's one boundary to Nix; it is replaced here by a
recorder, so the test runs on every host and can show that a refused request
never reaches Nix. Everything above that boundary -- request parsing,
validation and ``response_for`` in both modes the server uses -- is the real
helper.
"""

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


HELPER = (Path(__file__).resolve().parents[2]
          / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon")


def load_helper():
    loader = importlib.machinery.SourceFileLoader("reprobuild_nix_daemon_helper",
                                                  str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class RequestRequiresWorkspaceRoot(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        temporary = tempfile.TemporaryDirectory(prefix="rnd-root-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "store-tool"
        self.output.mkdir()
        self.commands = []

        def record(argv, cwd):
            self.commands.append((list(argv), Path(cwd)))
            return [str(self.output)]

        self.helper.run_command = record
        self.cache = self.helper.ResolveCache()

    def respond(self, cached_only=False, **fields):
        line = json.dumps(dict(action="resolve", selector=".#tool", **fields))
        return self.helper.response_for(line.encode(), self.cache,
                                        cached_only=cached_only)

    def test_a_missing_root_is_refused_without_reaching_nix(self):
        for fields in ({}, {"workspaceRoot": ""}, {"workspaceRoot": None}):
            for cached_only in (False, True):
                with self.subTest(fields=fields, cached_only=cached_only):
                    self.assertEqual(self.respond(cached_only, **fields),
                                     {"status": "error",
                                      "error": "missing workspaceRoot"})
        self.assertEqual(self.commands, [])

    def test_a_relative_root_is_refused_without_reaching_nix(self):
        response = self.respond(workspaceRoot="project")
        self.assertEqual(response["status"], "error", response)
        self.assertIn("not an absolute path: project", response["error"])
        self.assertEqual(self.commands, [])

    def test_an_absolute_root_is_where_nix_runs(self):
        # The control: the harness does reach Nix, so the refusals above are
        # the validation and not a recorder that is never called.
        response = self.respond(workspaceRoot=str(self.root))
        self.assertEqual(response["status"], "success", response)
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.commands[0][1], self.root.resolve())

    def test_a_home_relative_root_is_expanded_not_refused(self):
        # ``~`` was accepted before the rule and names an absolute directory.
        response = self.respond(workspaceRoot="~")
        self.assertEqual(response["status"], "success", response)
        self.assertEqual(self.commands[0][1], Path("~").expanduser().resolve())


if __name__ == "__main__":
    unittest.main()
