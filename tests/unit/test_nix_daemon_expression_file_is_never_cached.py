"""The Nix helper never serves a cached resolution for an ``expressionFile``.

Owner decision 2026-10-14 (reprobuild-specs Edge-Derived-Identities.md §7
rider): until campaign M19's monitored ``nix-eval`` / ``nix-realise`` edges
exist, a Nix tool use with an ``expressionFile`` is UNCACHEABLE everywhere.
The tool-identity key, the materialization key and the tool provision edge
already treat it so; this file pins the last cache on the route, the shared
helper's in-memory response cache.

That cache keys a request on the selector, the workspace root, the top-level
expression file's content and the workspace's ``flake.nix`` / ``flake.lock``.
It cannot see the files the expression IMPORTS, so before this fix an edit to
``pinned.nix`` (imported by ``default.nix``) left the key unchanged and the
long-lived helper answered with the store paths of the OLD evaluation: a stale
realization served for an expressionFile tool, behind every uncacheable key
upstream of it.

``run_command`` is the helper's one boundary to Nix (``nix-build``); it is
replaced here by an evaluator that reads the expression and what it imports,
so the test runs on every host. Everything above that boundary -- request
parsing, the cache key, ``ResolveCache`` and both ``response_for`` modes the
server uses -- is the real helper.
"""

import hashlib
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


class ExpressionFileIsNeverCached(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        temporary = tempfile.TemporaryDirectory(prefix="rnd-expr-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / "ws"
        self.workspace.mkdir()
        self.store = self.root / "store"
        self.store.mkdir()
        (self.workspace / "default.nix").write_text(
            "import ./pinned.nix\n", encoding="utf-8")
        (self.workspace / "pinned.nix").write_text(
            "{ version = \"1\"; }\n", encoding="utf-8")
        self.evaluations = []

        def evaluate(argv, cwd):
            # ``nix-build --no-out-link <file>`` or ``nix build ... <selector>``:
            # the output path is a function of the expression AND of every
            # ``.nix`` file beside it it may import -- what Nix reads.
            self.evaluations.append(list(argv))
            digest = hashlib.sha256()
            for path in sorted(Path(cwd).glob("*.nix")):
                digest.update(path.name.encode())
                digest.update(path.read_bytes())
            digest.update(argv[-1].encode())
            out = self.store / (digest.hexdigest()[:32] + "-tool")
            out.mkdir(exist_ok=True)
            return [str(out)]

        self.helper.run_command = evaluate
        self.cache = self.helper.ResolveCache()

    def request(self, expression=True, cached_only=False):
        payload = {"action": "resolve", "selector": "tool",
                   "workspaceRoot": str(self.workspace)}
        if expression:
            payload["expressionFile"] = "default.nix"
        line = json.dumps(payload).encode()
        return self.helper.response_for(line, self.cache,
                                        cached_only=cached_only)

    def test_an_edited_import_is_evaluated_again_not_served_from_the_cache(self):
        first = self.request()
        self.assertEqual(first["status"], "success", first)
        # Only an IMPORTED file changes: the request's key inputs (selector,
        # workspace, default.nix, flake files) are byte-identical.
        (self.workspace / "pinned.nix").write_text(
            "{ version = \"2\"; }\n", encoding="utf-8")
        second = self.request()
        self.assertEqual(second["status"], "success", second)
        self.assertEqual(len(self.evaluations), 2,
                         "the second request was answered from the cache")
        self.assertNotEqual(first["paths"], second["paths"])

    def test_an_unchanged_expression_is_still_evaluated_every_time(self):
        self.request()
        self.request()
        self.assertEqual(len(self.evaluations), 2)

    def test_the_inline_cached_only_answer_never_serves_an_expression(self):
        # The server answers a fast request inline from the cache
        # (``cached_only``); for an expressionFile there is nothing to serve.
        self.request()
        self.assertIsNone(self.request(cached_only=True))
        self.assertEqual(len(self.evaluations), 1)

    def test_a_selector_only_request_is_still_cached(self):
        # The control: this harness does reach the cache, so the cases above
        # measure the expressionFile rule and not a cache that never hits.
        first = self.request(expression=False)
        second = self.request(expression=False)
        self.assertEqual(first, second)
        self.assertEqual(len(self.evaluations), 1)
        self.assertEqual(self.request(expression=False, cached_only=True), first)


if __name__ == "__main__":
    unittest.main()
