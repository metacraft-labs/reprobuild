"""The CONF-3 / CONF-4 lint checks run the dev shell's pinned systemd-analyze.

reprobuild-pm issue 2026-10-22-lint-confinement-check-runs-the-hosts-systemd-analyze:
`scripts/derive_lease_floor_syscalls.py` (CONF-3) and
`scripts/check_daemon_worker_unit_confinement.py` (CONF-4) ran whichever
`systemd-analyze` the host put on PATH. That made the derived lease floor a
function of the host's systemd version (257 expands `@system-service` to
fewer syscalls than the 260.1 the committed header came from), and under the
dev shell's `LD_LIBRARY_PATH` a host binary on a different glibc died before
`main` -- which CONF-4 then reported as an exposure over the threshold.

WHY FAKE `systemd-analyze` EXECUTABLES. The defect is about WHICH binary the
checks choose and how they classify that binary's failure, and neither can be
exercised with a real systemd deterministically: the host's version and its
glibc are whatever the machine running the test happens to have. The fakes
are tiny executables with fixed output, one placed first on PATH (standing in
for the host's) and one named by `REPRO_SYSTEMD_ANALYZE` (standing in for the
pinned one); each records that it ran. The checks themselves, the unit file,
the threshold and the committed header are the real ones. The last case runs
the real pinned binary against the real committed header whenever the dev
shell provides it.
"""

from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
UNIT = ROOT / "recipes/repro-daemon-worker/systemd-units/repro-daemon-worker.service"
DERIVER = SCRIPTS / "derive_lease_floor_syscalls.py"

LOADER_CRASH = (
    "systemd-analyze: /nix/store/i3ibgfskl99qd8rslafbpaa1dmxdzh1z-glibc-2.40-66/lib/libc.so.6: "
    "version `GLIBC_ABI_DT_X86_64_PLT' not found (required by "
    "/nix/store/fjkx1l5cnskzrqacf08z7i8z17256w0j-glibc-2.42-61/lib/libdl.so.2)")


def load(name):
    spec = importlib.util.spec_from_file_location(name + "_under_test", SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipIf(os.name == "nt" or not sys.platform.startswith("linux"),
                 "CONF-3 / CONF-4 run systemd-analyze, which exists on Linux only")
class PinnedSystemdAnalyzeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="repro-conf-systemd-analyze-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.host_bin = self.root / "host-bin"
        self.host_bin.mkdir()
        saved = {k: os.environ.get(k) for k in ("PATH", "REPRO_SYSTEMD_ANALYZE")}

        def restore():
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.addCleanup(restore)
        self.derive = load("derive_lease_floor_syscalls")
        self.check = load("check_daemon_worker_unit_confinement")

    def fake(self, path, marker, stdout="", stderr="", code=0, groups=None):
        """An executable that records it ran, then answers like systemd-analyze.

        ``groups`` maps a `syscall-filter` group to its members; any other
        invocation prints ``stdout`` / ``stderr`` and exits ``code``."""
        path.write_text(
            "#!%s\n"
            "import sys\n"
            "open(%r, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
            "groups = %r\n"
            "if sys.argv[1:2] == ['syscall-filter'] and groups is not None:\n"
            "    print(sys.argv[-1])\n"
            "    for name in groups.get(sys.argv[-1], []):\n"
            "        print('    ' + name)\n"
            "    sys.exit(0)\n"
            "sys.stdout.write(%r)\n"
            "sys.stderr.write(%r)\n"
            "sys.exit(%d)\n"
            % (sys.executable, str(marker), groups, stdout, stderr, code),
            encoding="utf-8")
        path.chmod(0o755)
        return path

    def host_fake(self, **answer):
        marker = self.root / "host-ran"
        self.fake(self.host_bin / "systemd-analyze", marker, **answer)
        os.environ["PATH"] = str(self.host_bin) + os.pathsep + os.environ.get("PATH", "")
        return marker

    def pinned_fake(self, **answer):
        marker = self.root / "pinned-ran"
        path = self.fake(self.root / "pinned-systemd-analyze", marker, **answer)
        os.environ["REPRO_SYSTEMD_ANALYZE"] = str(path)
        return marker

    def test_expansion_uses_the_pinned_binary_not_the_hosts(self):
        host = self.host_fake(groups={"@system-service": ["host_only"]})
        pinned = self.pinned_fake(groups={"@system-service": ["read", "@basic-io"],
                                          "@basic-io": ["write"]})
        self.assertEqual(self.derive.expand("@system-service"), {"read", "write"})
        self.assertTrue(pinned.exists(), "the REPRO_SYSTEMD_ANALYZE binary never ran")
        self.assertFalse(host.exists(), "the host's systemd-analyze on PATH was run")

    def test_without_the_pin_the_hosts_binary_is_refused_not_used(self):
        host = self.host_fake(groups={"@system-service": ["read"]})
        os.environ.pop("REPRO_SYSTEMD_ANALYZE", None)
        with self.assertRaises(Exception) as caught:
            self.derive.expand("@system-service")
        self.assertIn("REPRO_SYSTEMD_ANALYZE", str(caught.exception))
        self.assertFalse(host.exists(), "the host's systemd-analyze on PATH was run")

    def test_pin_naming_no_executable_is_refused(self):
        os.environ["REPRO_SYSTEMD_ANALYZE"] = str(self.root / "absent")
        with self.assertRaises(Exception) as caught:
            self.derive.expand("@system-service")
        self.assertIn("REPRO_SYSTEMD_ANALYZE", str(caught.exception))

    def conf4(self, **answer):
        # The same answer from the "host" and the pinned binary, so the case
        # is about how a failure is CLASSIFIED whichever binary the check runs.
        self.host_fake(**answer)
        self.pinned_fake(**answer)
        return self.check.check_conf4(UNIT.read_text(encoding="utf-8"))

    def test_conf4_reports_a_binary_that_cannot_start_as_that(self):
        with self.assertRaises(self.check.Failure) as caught:
            self.conf4(stderr=LOADER_CRASH + "\n", code=127)
        message = str(caught.exception)
        self.assertNotIn("exceeds", message)
        self.assertIn("failed", message)
        self.assertIn("127", message)
        self.assertIn("GLIBC_ABI_DT_X86_64_PLT", message)

    def test_conf4_reports_a_run_with_no_verdict_as_a_failure_to_analyse(self):
        with self.assertRaises(self.check.Failure) as caught:
            self.conf4(stdout="", code=0)
        self.assertNotIn("exceeds", str(caught.exception))

    def test_conf4_still_refuses_an_exposure_over_the_threshold(self):
        with self.assertRaises(self.check.Failure) as caught:
            self.conf4(stdout="NAME DESCRIPTION EXPOSURE\n"
                              "→ Overall exposure level for repro-daemon-worker.service:"
                              " 9.6 UNSAFE 😨\n", code=1)
        message = str(caught.exception)
        self.assertIn("exceeds the committed threshold", message)
        self.assertIn("9.6", message)
        # Both numbers are rendered in the same units. The file stores tenths
        # (`26`), so printing it raw beside a decoded exposure read as "9.6
        # exceeds 26" -- which is false as written and sent a reader looking
        # for an inverted comparison instead of a confinement shortfall.
        self.assertIn("committed threshold 2.6", message)
        self.assertNotIn("threshold 26", message)

    def test_conf4_passes_an_exposure_within_the_threshold(self):
        self.assertEqual(
            self.conf4(stdout="→ Overall exposure level for repro-daemon-worker.service:"
                              " 2.6 OK 🙂\n", code=0),
            (ROOT / "recipes/repro-daemon-worker/confinement-threshold")
            .read_text(encoding="utf-8").strip())


@unittest.skipIf(os.name == "nt" or not sys.platform.startswith("linux"),
                 "CONF-3 runs systemd-analyze, which exists on Linux only")
class CommittedHeaderTests(unittest.TestCase):
    def test_committed_header_is_what_the_pinned_systemd_derives(self):
        pinned = os.environ.get("REPRO_SYSTEMD_ANALYZE")
        if not pinned or not os.environ.get("REPRO_LINUX_UAPI_INCLUDE"):
            self.skipTest("needs the dev shell's REPRO_SYSTEMD_ANALYZE and "
                          "REPRO_LINUX_UAPI_INCLUDE (flake.nix devShell)")
        out = subprocess.run([sys.executable, str(DERIVER), "--check"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(out.returncode, 0, out.stderr + out.stdout)


if __name__ == "__main__":
    unittest.main()
