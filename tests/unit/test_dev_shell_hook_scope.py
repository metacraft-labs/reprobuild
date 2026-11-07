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

    def test_guard_encloses_the_hook_installer_and_dispatcher_assertion(self):
        flake = (ROOT / "flake.nix").read_text(encoding="utf-8")
        # The default shell's hook is the one the repository guard opens.
        hook = flake[flake.index("devShells"):]
        guard = hook.index("${./scripts/is_reprobuild_checkout.sh}; then")
        installer = hook.index("${./scripts/install-git-hooks.sh}")
        ensure = hook.index("hooks ensure --vcs")
        end = hook.index("\n              fi", ensure)
        self.assertLess(guard, installer)
        self.assertLess(installer, ensure)
        self.assertLess(ensure, end)

    def test_upstream_installer_is_not_used(self):
        # git-hooks.nix's installer refuses to replace the committed
        # .pre-commit-config.yaml and then installs no hook at all.
        flake = (ROOT / "flake.nix").read_text(encoding="utf-8")
        shells = flake[flake.index("devShells"):]
        self.assertNotIn("pre-commit-check.shellHook", shells)
        self.assertNotIn("installationScript", shells)

if __name__ == "__main__":
    unittest.main()
