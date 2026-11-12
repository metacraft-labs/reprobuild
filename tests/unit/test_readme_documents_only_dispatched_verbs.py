"""The README may only show `repro` verbs that the CLI dispatches.

WHY THIS FILE EXISTS

README.md presented `repro init`, `repro search`, `repro upgrade` and
`repro infra rollback` as working commands. The dispatcher
(`runThinAppDispatch`) has no arm for the first three, so each printed the
usage text and exited 2 -- the README's "Starting a New Project" path failed at
its first command -- and `rollback` is a `repro home` / `repro system`
subcommand, not an `infra` one. `repro add` / `repro remove` were described as
package-dependency commands although they add and remove workspace
repositories (reprobuild-pm issue
2026-11-11-readme-documents-repro-verbs-the-cli-does-not-dispatch).

WHAT IS AND IS NOT MOCKED

Nothing. The test reads the real README and the real dispatcher sources and
checks every `repro <verb>` (and `repro infra <sub>`) the README shows against
the `args[0] == "<verb>"` arms / `of "<sub>":` arms in them.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "libs" / "repro_cli_support" / "src"
README = (ROOT / "README.md").read_text(encoding="utf-8")
DISPATCH = (SUPPORT / "repro_cli_support.nim").read_text(encoding="utf-8")
INFRA = (SUPPORT / "repro_cli_support" / "infra.nim").read_text(encoding="utf-8")


def documented_verbs(text):
    return sorted(set(re.findall(r"\brepro ([a-z][a-z-]*)", text)))


class ReadmeMatchesDispatcher(unittest.TestCase):
    def test_every_documented_verb_has_a_dispatch_arm(self):
        missing = [
            v for v in documented_verbs(README)
            if f'args[0] == "{v}"' not in DISPATCH
        ]
        self.assertEqual(missing, [], f"README documents undispatched verbs: {missing}")

    def test_every_documented_infra_subcommand_is_dispatched(self):
        arms = set(re.findall(r'^\s+of "([a-z-]+)": return runInfra', INFRA, re.M))
        self.assertIn("plan", arms)
        documented = set(re.findall(r"\brepro infra ([a-z][a-z-]*)", README))
        self.assertEqual(sorted(documented - arms), [])

    def test_add_and_remove_are_described_as_workspace_membership(self):
        for line in README.splitlines():
            if "`repro add" in line:
                self.assertNotIn("dependenc", line)
                self.assertIn("repositor", line)


if __name__ == "__main__":
    unittest.main()
