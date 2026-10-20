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
    """Return a PATH string guaranteed not to include `timeout` or `gtimeout`.

    The smoke script needs ordinary utilities (`mktemp`, `rm`, ...), so the
    PATH must offer everything a normal shell PATH does except the two
    timeout commands. On NixOS the FHS directories hold almost nothing (no
    `mktemp`), so the candidates are this process's PATH directories as well
    as the FHS ones, shadowed into one directory without `timeout`.
    """
    system_paths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    inherited = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d]
    directories = []
    for directory in inherited + system_paths:
        if directory not in directories:
            directories.append(directory)

    shadow = work_dir / "bin_without_timeout"
    shadow.mkdir(parents=True, exist_ok=True)
    for directory in directories:
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

        # Mock package layout with bin/repro and bin/runquotad. The mock's
        # `build` behaves like the engine under --tool-provisioning=tarball:
        # it is refused unless it can find a runquotad on PATH.
        self.pkg = self.work / "mock-package"
        bin_dir = self.pkg / "bin"
        bin_dir.mkdir(parents=True)
        repro_bin = bin_dir / "repro"
        repro_bin.write_text(
            "#!/bin/sh\n"
            "here=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"
            "export REPROBUILD_SOURCE_ROOT=\"$here/share/repro/source\"\n"
            "if [ \"$1\" = \"build\" ]; then\n"
            f"{self.BUILD_BODY}"
            "fi\n"
            "if [ \"$1\" = \"exec\" ] && [ \"$2\" = \"--\" ]; then\n"
            "  shift 2\n"
            "fi\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        repro_bin.chmod(0o755)
        self.runquotad = bin_dir / "runquotad"
        self.runquotad.write_text("#!/bin/sh\n", encoding="utf-8")
        self.runquotad.chmod(0o755)

    BUILD_BODY = (
        "  command -v runquotad >/dev/null 2>&1 && exit 0\n"
        "  echo 'runquota daemon unreachable and bypass is disabled.' >&2\n"
        "  exit 1\n"
    )

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
        self.assertIn("=== repro build smoke test PASSED", res.stdout)

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
        self.assertIn("=== repro build smoke test PASSED", res.stdout)

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
        self.assertIn("=== repro build smoke test PASSED", res.stdout)

    def _env_with(self, *dirs: Path) -> dict:
        path = os.pathsep.join([str(d) for d in dirs] + [os.environ.get("PATH", "")])
        return {"PATH": path, "TMPDIR": str(self.work)}

    def test_build_fails_when_the_archive_has_no_runquotad(self):
        """v0.2.12's archives: no daemon in bin/ is a failed smoke."""
        self.runquotad.unlink()
        res = self._run_smoke(shutil.which("bash") or "/bin/bash", self._env_with())
        self.assertNotEqual(0, res.returncode, res.stdout)
        self.assertIn("no bin/runquotad", res.stderr)

    def test_a_runquotad_elsewhere_on_path_is_not_reached(self):
        """Another runquotad on PATH must not answer for the archive."""
        foreign = self.work / "foreign-bin"
        foreign.mkdir()
        (foreign / "runquotad").write_text("#!/bin/sh\n", encoding="utf-8")
        (foreign / "runquotad").chmod(0o755)
        res = self._run_smoke(shutil.which("bash") or "/bin/bash", self._env_with(foreign))
        self.assertEqual(0, res.returncode, f"stdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("=== repro build smoke test PASSED", res.stdout)

    def test_a_build_that_is_never_refused_fails_the_control(self):
        """If the hidden-daemon build still succeeds, something else served it."""
        repro_bin = self.pkg / "bin" / "repro"
        repro_bin.write_text(
            repro_bin.read_text(encoding="utf-8").replace(self.BUILD_BODY, "  exit 0\n"),
            encoding="utf-8")
        res = self._run_smoke(shutil.which("bash") or "/bin/bash", self._env_with())
        self.assertNotEqual(0, res.returncode, res.stdout)
        self.assertIn("was not refused", res.stderr)


if __name__ == "__main__":
    unittest.main()
