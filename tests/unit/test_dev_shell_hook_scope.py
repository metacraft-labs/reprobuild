"""A borrowed toolchain must not install another project's repository hooks."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "scripts/is_reprobuild_checkout.sh"
MARKERS = ("flake.nix", "repro.nim", "scripts/pre_commit_hook_handoff.sh")


@unittest.skipIf(os.name == "nt", "Nix dev-shell hooks execute on Unix hosts")
class DevShellHookScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="repro-hook-scope-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bash = shutil.which("bash")
        self.assertIsNotNone(self.bash, "Bash is required by this shell-hook test")

    def git(self, *arguments):
        subprocess.run(["git", *arguments], cwd=self.root, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def initialize(self, tracked=True):
        self.git("init", "-q")
        for name in MARKERS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n", encoding="ascii")
        if tracked:
            self.git("add", "--", *MARKERS)

    def allowed(self, cwd=None):
        result = subprocess.run([self.bash, str(PROBE)], cwd=cwd or self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")
        return result.returncode == 0

    def test_own_checkout_allows_repository_hooks(self):
        self.initialize()
        self.assertTrue(self.allowed())

    def test_foreign_repository_is_untouched(self):
        self.git("init", "-q")
        self.assertFalse(self.allowed())

    def test_untracked_lookalike_is_not_a_checkout(self):
        self.initialize(tracked=False)
        self.assertFalse(self.allowed())

    def test_subdirectory_cannot_receive_root_configuration(self):
        self.initialize()
        self.assertFalse(self.allowed(self.root / "scripts"))

    def test_non_repository_is_untouched(self):
        self.assertFalse(self.allowed())

    def test_guard_encloses_the_generated_installer_and_handoff(self):
        flake = (ROOT / "flake.nix").read_text(encoding="utf-8")
        start = flake.index("shellHook = ''", flake.index("devShells"))
        hook = flake[start:]
        guard = hook.index("${./scripts/is_reprobuild_checkout.sh}; then")
        before = hook.index("${./scripts/pre_commit_hook_handoff.sh} before")
        installer = hook.index("+ pre-commit-check.shellHook")
        after = hook.index("${./scripts/pre_commit_hook_handoff.sh} after")
        end = hook.index("\n              fi", after)
        self.assertLess(guard, before)
        self.assertLess(before, installer)
        self.assertLess(installer, after)
        self.assertLess(after, end)


if __name__ == "__main__":
    unittest.main()
