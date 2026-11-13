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
import contextlib
import importlib.util
import io
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
        pinned = self.pinned_fake(**answer)
        return self.check.check_conf4(UNIT.read_text(encoding="utf-8")), pinned

    EXPOSURE = ("\u2192 Overall exposure level for repro-daemon-worker.service:"
                " %s OK \U0001f642\n")

    def test_conf4_analyses_the_unit_by_name_under_a_private_root(self):
        # reprobuild-pm issue 2026-11-05-conf-4s-virtualized-class-holds-hosts-
        # that-measure-2-6: without `--root` the offline analysis loads the
        # host's unit directories, so the host's drop-ins were scored as part
        # of the unit. The unit has to be named, not given as a path: a path
        # outside the root is not found under it.
        _, pinned = self.conf4(stdout=self.EXPOSURE % "2.6", code=0)
        argv = pinned.read_text(encoding="utf-8").split()
        roots = [a for a in argv if a.startswith("--root=")]
        self.assertEqual(1, len(roots), argv)
        self.assertIn("--offline=true", argv)
        self.assertEqual("repro-daemon-worker.service", argv[-1])

    def test_conf4_still_refuses_one_tenth_over_the_ceiling(self):
        # 3.1 is what the LXC runners reported while their drop-in was scored
        # with the unit; it was once accepted as a host class's ceiling and is
        # now a regression on every host.
        with self.assertRaises(self.check.Failure) as caught:
            self.conf4(stdout=self.EXPOSURE % "2.7", code=0)
        self.assertIn("committed threshold 2.6", str(caught.exception))

    def test_conf4_records_one_ceiling_not_one_per_host_class(self):
        self.assertEqual("26", self.check.committed_threshold())

    def test_conf4_refuses_a_threshold_file_keyed_by_host_class(self):
        # The old per-class format must not be read as some ceiling: a file
        # that still says `virtualized = 31` would otherwise re-admit the 0.5.
        path = self.root / "confinement-threshold"
        path.write_text("none = 26\nvirtualized = 31\n", encoding="utf-8")
        saved = self.check.THRESHOLD
        self.check.THRESHOLD = str(path)
        self.addCleanup(setattr, self.check, "THRESHOLD", saved)
        with self.assertRaises(self.check.Failure) as caught:
            self.check.committed_threshold()
        self.assertIn("exactly one ceiling", str(caught.exception))

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
        ceiling, _ = self.conf4(
            stdout="→ Overall exposure level for repro-daemon-worker.service:"
                   " 2.6 OK 🙂\n", code=0)
        # Parsed here, not through the check's own reader, so the check
        # cannot agree with itself about a number neither took from the file.
        self.assertEqual(
            ceiling,
            next(line.strip() for line in
                 (ROOT / "recipes/repro-daemon-worker/confinement-threshold")
                 .read_text(encoding="utf-8").splitlines()
                 if line.strip() and not line.strip().startswith("#")))


# The drop-in LXC's systemd generator writes into every unprivileged container
# running systemd >= 256, verbatim
# (https://github.com/lxc/distrobuilder/blob/main/distrobuilder/lxc.generator,
# fix_systemd_override_unit). It is what the GARM runners carry.
LXC_SERVICE_DROPIN = (
    "[Service]\n"
    "ProcSubset=all\n"
    "ProtectProc=default\n"
    "ProtectControlGroups=no\n"
    "ProtectKernelTunables=no\n"
    "NoNewPrivileges=no\n"
    "LoadCredential=\n"
    "PrivateNetwork=no\n"
    "ImportCredential=\n")


@unittest.skipIf(os.name == "nt" or not sys.platform.startswith("linux"),
                 "CONF-4 runs systemd-analyze, which exists on Linux only")
class HostDropInTests(unittest.TestCase):
    """CONF-4 measures the unit, not the host it runs on.

    reprobuild-pm issue 2026-11-05-conf-4s-virtualized-class-holds-hosts-that-
    measure-2-6. The real pinned analyzer and the real unit; the host's unit
    search path is given LXC's drop-in through `$SYSTEMD_UNIT_PATH`, which
    systemd reads exactly as it reads /run/systemd/system, so the case needs
    neither root nor a container. No mock: the variable is the documented
    systemd input, and the positive control below proves the analyzer applies
    it."""

    def setUp(self):
        self.pinned = os.environ.get("REPRO_SYSTEMD_ANALYZE")
        if not self.pinned:
            self.skipTest("needs the dev shell's REPRO_SYSTEMD_ANALYZE (flake.nix devShell)")
        temporary = tempfile.TemporaryDirectory(prefix="repro-conf4-dropin-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        dropins = self.root / "host-units" / "service.d"
        dropins.mkdir(parents=True)
        (dropins / "zzz-lxc-service.conf").write_text(LXC_SERVICE_DROPIN, encoding="utf-8")
        saved = os.environ.get("SYSTEMD_UNIT_PATH")
        # The trailing colon keeps systemd's default directories after it.
        os.environ["SYSTEMD_UNIT_PATH"] = str(self.root / "host-units") + ":"
        self.addCleanup(lambda: os.environ.pop("SYSTEMD_UNIT_PATH", None)
                        if saved is None else os.environ.__setitem__("SYSTEMD_UNIT_PATH", saved))
        self.check = load("check_daemon_worker_unit_confinement")

    def exposure(self, output):
        verdict = self.check.EXPOSURE_LINE.search(output)
        self.assertIsNotNone(verdict, output)
        return verdict.group(1) + "." + verdict.group(2)

    def test_the_hosts_dropin_does_not_enter_the_score(self):
        text = UNIT.read_text(encoding="utf-8")
        # Positive control: the analyzer, run the way CONF-4 used to run it,
        # does apply the host's drop-in -- this is the 3.1 the GARM runners
        # reported. Without it the case below would prove nothing.
        unit = self.root / "repro-daemon-worker.service"
        unit.write_text(self.check.render(text), encoding="utf-8")
        out = subprocess.run([self.pinned, "security", "--offline=true", str(unit)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertEqual("3.1", self.exposure(out.stdout))
        # CONF-4 itself scores the unit alone and passes against the single
        # committed ceiling.
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.check.check_conf4(text)
        self.assertEqual("2.6", self.exposure(printed.getvalue()))

    def test_a_unit_path_that_replaces_the_defaults_does_not_hide_the_unit(self):
        # Without the trailing `:` the variable REPLACES systemd's default
        # directories, the private root's etc/systemd/system among them, so
        # the analyzer would answer "Unit ... not found" and CONF-4 would fail
        # on what the host's environment says rather than on the unit.
        os.environ["SYSTEMD_UNIT_PATH"] = str(self.root / "host-units")
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.check.check_conf4(UNIT.read_text(encoding="utf-8"))
        self.assertEqual("2.6", self.exposure(printed.getvalue()))


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
