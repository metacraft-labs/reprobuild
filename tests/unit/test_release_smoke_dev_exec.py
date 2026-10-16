"""Tests for scripts/release/smoke_release_dev_exec.sh under various shells.

Verifies that release smoke verification runs successfully under stock macOS
shells (/bin/bash 3.2) even when optional host utilities like GNU timeout are
not installed on PATH.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SMOKE_SCRIPT = ROOT / "scripts" / "release" / "smoke_release_dev_exec.sh"


def _clean_path_without_timeout(work_dir: Path) -> str:
    """Return a PATH string guaranteed not to include `timeout` or `gtimeout`."""
    system_paths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    candidate = os.pathsep.join(system_paths)
    if shutil.which("timeout", path=candidate) is None and shutil.which("gtimeout", path=candidate) is None:
        return candidate

    shadow = work_dir / "bin_without_timeout"
    shadow.mkdir(parents=True, exist_ok=True)
    for directory in system_paths:
        if not os.path.isdir(directory):
            continue
        for entry in os.listdir(directory):
            if entry in ("timeout", "gtimeout"):
                continue
            src = os.path.join(directory, entry)
            dst = shadow / entry
            if not dst.exists() and not dst.is_symlink():
                try:
                    dst.symlink_to(src)
                except OSError:
                    pass
    return str(shadow)


@unittest.skipIf(os.name == "nt", "POSIX release smoke script runs on Unix hosts")
class ReleaseSmokeDevExecTests(unittest.TestCase):
    def setUp(self):
        self.work_dir = tempfile.TemporaryDirectory(prefix="repro-test-smoke-")
        self.addCleanup(self.work_dir.cleanup)
        self.work = Path(self.work_dir.name)

        # Mock package layout with bin/repro
        self.pkg = self.work / "mock-package"
        bin_dir = self.pkg / "bin"
        bin_dir.mkdir(parents=True)
        repro_bin = bin_dir / "repro"
        repro_bin.write_text(
            "#!/bin/sh\n"
            "here=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"
            "export REPROBUILD_SOURCE_ROOT=\"$here/share/repro/source\"\n"
            "if [ \"$1\" = \"exec\" ] && [ \"$2\" = \"--\" ]; then\n"
            "  shift 2\n"
            "fi\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        repro_bin.chmod(0o755)

    def _run_smoke(self, bash_binary: str, env: dict) -> subprocess.CompletedProcess:
        return subprocess.run(
            [bash_binary, str(SMOKE_SCRIPT), str(self.pkg)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_smoke_dev_exec_under_system_bash_without_timeout(self):
        """macOS system /bin/bash (3.2) without timeout on PATH must succeed."""
        system_bash = "/bin/bash"
        if not os.path.exists(system_bash):
            self.skipTest(f"{system_bash} does not exist on this host")

        no_timeout_path = _clean_path_without_timeout(self.work)
        env = {
            "PATH": no_timeout_path,
            "TMPDIR": str(self.work),
        }
        res = self._run_smoke(system_bash, env)
        self.assertNotIn("unbound variable", res.stdout + res.stderr)
        self.assertEqual(0, res.returncode, f"stdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("=== repro exec smoke test PASSED", res.stdout)

    def test_smoke_dev_exec_under_path_bash_without_timeout(self):
        """Default bash on PATH without timeout must succeed."""
        bash_path = shutil.which("bash")
        self.assertIsNotNone(bash_path, "bash must be available on PATH")

        no_timeout_path = _clean_path_without_timeout(self.work)
        # Ensure the selected bash is callable with no_timeout_path, or prepend its directory
        bash_dir = str(Path(bash_path).parent)
        env_path = no_timeout_path
        if shutil.which("bash", path=env_path) is None:
            env_path = f"{bash_dir}{os.pathsep}{no_timeout_path}"

        env = {
            "PATH": env_path,
            "TMPDIR": str(self.work),
        }
        res = self._run_smoke(bash_path, env)
        self.assertNotIn("unbound variable", res.stdout + res.stderr)
        self.assertEqual(0, res.returncode, f"stdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("=== repro exec smoke test PASSED", res.stdout)

    def test_smoke_dev_exec_with_timeout(self):
        """When timeout is available on PATH, smoke execution succeeds with bounded command."""
        timeout_path = shutil.which("timeout")
        if not timeout_path:
            self.skipTest("timeout utility not found on PATH")

        bash_path = shutil.which("bash") or "/bin/bash"
        env = dict(os.environ)
        env["TMPDIR"] = str(self.work)
        res = self._run_smoke(bash_path, env)
        self.assertEqual(0, res.returncode, f"stdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("=== repro exec smoke test PASSED", res.stdout)


if __name__ == "__main__":
    unittest.main()
