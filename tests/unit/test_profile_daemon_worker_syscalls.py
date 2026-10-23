"""Exercise the real profiler, its output file and shell error propagation.

WHY FAKE EXECUTABLES: sudo/systemd-run/strace must not install units, gain
privileges or trace a real worker in a unit test. Their stand-ins execute a
real scratch workload and supply a deterministic trace. systemd-analyze is
substituted to reproduce loader failures, empty and nested groups regardless
of the host's systemd version. Only the profiler and the shipped unit are
copied; all writes and workload effects stay inside a TemporaryDirectory.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform.startswith("linux"), "the profiler requires Linux systemd units")
class WorkerProfilerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="repro-conf3-profile-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/profile_daemon_worker_syscalls.sh"
        shutil.copyfile(ROOT / "scripts" / self.script.name, self.script)
        recipe = self.root / "recipes/repro-daemon-worker"
        (recipe / "systemd-units").mkdir(parents=True)
        shutil.copyfile(ROOT / "recipes/repro-daemon-worker/systemd-units/repro-daemon-worker.service",
                        recipe / "systemd-units/repro-daemon-worker.service")
        self.output = recipe / "syscalls"
        self.output.write_bytes(b"# existing profile\noriginal_call\n")
        self.original = self.output.read_bytes()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        FIXTURE=str(self.root))
        self.executable("sudo", '''shift
case "$1" in
  systemctl) exit 0 ;;
  systemd-run) shift; while [[ $1 != -- ]]; do shift; done; shift; exec "$@" ;;
  *) exec "$@" ;;
esac
''')
        self.executable("strace", '''while [[ $1 != -- ]]; do
  if [[ $1 == -o ]]; then shift; trace=$1; fi
  shift
done
shift
printf '123 read(0) = 0\\n123 close(0) = 0\\n123 mount(0) = 0\\n123 special_call(0) = 0\\n' > "$trace"
exec "$@"
''')
        self.env["STRACE"] = str(self.bin / "strace")
        self.workload = self.executable("workload", 'touch "$FIXTURE/workload-ran"\n')
        self.executable("systemd-analyze", 'touch "$FIXTURE/host-ran"; exit 99\n')
        self.analyzer = self.executable("pinned-analyze", '''group=${@: -1}
echo "$group" >> "$FIXTURE/analyzed"
if [[ $group == "${FAIL_GROUP:-}" ]]; then
  echo 'loader failure: GLIBC_ABI_DT_X86_64_PLT not found' >&2
  # Partial stdout must not turn a failed analysis into valid input.
  if [[ ${FAIL_PARTIAL:-} == 1 ]]; then printf '%s\\n  read\\n' "$group"; fi
  exit 42
fi
echo "$group"
if [[ $group == "${EMPTY_GROUP:-}" ]]; then
  echo '# no members'
  echo 'empty-group diagnostic' >&2
  exit 0
fi
case "$group" in
  @system-service) printf '  read\\n  @nested\\n  mount\\n' ;;
  @nested) echo '  close' ;;
  @privileged) echo '  mount' ;;
  @resources) echo '  setpriority' ;;
  @obsolete) echo '  old_call' ;;
  *) exit 88 ;;
esac
''')
        self.env["REPRO_SYSTEMD_ANALYZE"] = str(self.analyzer)

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def run_profiler(self, *args):
        return subprocess.run(["bash", str(self.script), *args, str(self.workload)],
                              env=self.env, text=True, capture_output=True)

    def assert_refused(self, result, group, diagnostic):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(group, result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertFalse((self.root / "workload-ran").exists())
        self.assertFalse((self.root / "host-ran").exists())

    def test_profile_requires_explicit_pinned_analyzer(self):
        self.env.pop("REPRO_SYSTEMD_ANALYZE")
        self.assert_refused(self.run_profiler(), "REPRO_SYSTEMD_ANALYZE", "dev shell")

    def test_invalid_analyzer_paths_are_refused_without_path_lookup(self):
        nonexecutable = self.root / "not-executable"
        nonexecutable.write_text("not executable")
        # Even a matching local filename must not permit PATH command lookup.
        (self.root / "systemd-analyze").write_text("local decoy")
        (self.root / "systemd-analyze").chmod(0o755)
        for path in ("", "systemd-analyze", str(self.bin), str(nonexecutable), str(self.root / "missing")):
            with self.subTest(path=path):
                self.env["REPRO_SYSTEMD_ANALYZE"] = path
                self.assert_refused(self.run_profiler(), "REPRO_SYSTEMD_ANALYZE", "dev shell")

    def test_failed_root_or_nested_group_preserves_stderr_and_output(self):
        for partial in ("", "1"):
            for group in ("@system-service", "@nested", "@privileged", "@resources", "@obsolete"):
                with self.subTest(group=group, partial=partial):
                    self.env.update(FAIL_GROUP=group, FAIL_PARTIAL=partial)
                    self.assert_refused(self.run_profiler(), group, "GLIBC_ABI_DT_X86_64_PLT")

    def test_empty_root_or_nested_group_preserves_stderr_and_output(self):
        for group in ("@system-service", "@nested", "@privileged", "@resources", "@obsolete"):
            with self.subTest(group=group):
                self.env["EMPTY_GROUP"] = group
                self.assert_refused(self.run_profiler(), group, "empty-group diagnostic")

    def test_success_subtracts_nested_base_and_reallows_removed_calls(self):
        result = self.run_profiler()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "workload-ran").exists())
        names = [line for line in self.output.read_text().splitlines() if not line.startswith("#")]
        self.assertEqual(names, ["mount", "special_call"])
        self.assertIn("@nested", (self.root / "analyzed").read_text().splitlines())
        self.assertFalse((self.root / "host-ran").exists())

    def test_verify_needs_no_expansion_and_keeps_profile(self):
        self.env.pop("REPRO_SYSTEMD_ANALYZE")
        result = self.run_profiler("--verify")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "workload-ran").exists())
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertFalse((self.root / "host-ran").exists())
        self.assertFalse((self.root / "analyzed").exists())


if __name__ == "__main__":
    unittest.main()
