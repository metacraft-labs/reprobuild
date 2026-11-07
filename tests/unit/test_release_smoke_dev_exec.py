"""Tests for scripts/release/smoke_release_dev_exec.sh under various shells.

Verifies that release smoke verification runs successfully under stock macOS
shells (/bin/bash 3.2) even when optional host utilities like GNU timeout are
not installed on PATH.

The package CLI and Windows helper are stubs because these cases test shell
routing and refusal propagation, not installed SDK or Windows API behavior.
Real archive compilation and Windows process ownership remain release gates.
The PowerShell cases execute the production parameter block and pure argv
reader/quoting functions, extracted by its parser. They never replace Windows
APIs with successful fakes or claim native Windows argv/lifecycle coverage.
The workflow-exit case uses real Just with an owned temporary Justfile whose
recipe starts the real PowerShell child with exit 0 or 23. It runs the exact
workflow fragment and its predecessor; no compiler or native Windows build
is simulated or accepted as passing.
"""

from pathlib import Path
import os
import base64
import json
import shutil
import subprocess
import tempfile
import sys
import textwrap
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
            # The fixture collapses distinct host tool directories into one.
            # Keep foreign coordinators out: production correctly drops any
            # daemon-containing PATH directory, which would drop every utility
            # in this synthetic directory along with the coordinator.
            if entry in ("timeout", "gtimeout", "runquotad", "runquotad.exe"):
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
        "  echo 'runquota daemon unreachable and bypass is disabled. Underlying error: No such file or directory' >&2\n"
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

    def test_occupied_windows_endpoint_cannot_qualify_the_archive(self):
        """A foreign endpoint refusal must not become a skipped control/PASS."""
        for name, body in (
            ("runquotad.exe", "#!/bin/sh\nexit 0\n"),
            ("runquota.exe", "#!/bin/sh\nexit 0\n"),
            ("powershell", "#!/bin/sh\necho 'default RunQuota endpoint is already occupied' >&2\nexit 23\n"),
        ):
            file = self.pkg / "bin" / name
            file.write_text(body, encoding="utf-8")
            file.chmod(0o755)
        res = self._run_smoke(shutil.which("bash") or "/bin/bash",
                              self._env_with(self.pkg / "bin"))
        self.assertNotEqual(0, res.returncode, res.stdout)
        self.assertIn("endpoint is already occupied", res.stderr + res.stdout)
        self.assertNotIn("repro build smoke test PASSED", res.stdout)

    def test_initial_windows_exec_isolates_foreign_daemon_environment(self):
        """Isolation must precede the first archive exec, which can auto-start."""
        foreign = self.work / "foreign-daemon"
        foreign.mkdir()
        daemon = foreign / "runquotad"
        daemon.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        daemon.chmod(0o755)
        (self.pkg / "bin/runquotad.exe").write_text("fixture", encoding="utf-8")
        powershell = self.pkg / "bin/powershell"
        powershell.write_text("#!" + shutil.which("bash") + r"""
set -eu
# Caller argv only: this stand-in never asserts Windows policy/lifecycle success.
if [[ $# -lt 6 || "$1" != -NoProfile || "$2" != -NonInteractive ||
      "$3" != -ExecutionPolicy || "$4" != Bypass || "$5" != -File ]]; then
  echo "missing process-local PowerShell script policy" >&2
  exit 76
fi
for name in RUNQUOTAD_BIN RUNQUOTA_BIN RUNQUOTA_SOCKET REPROBUILD_NO_RUNQUOTA; do
  if declare -p "$name" >/dev/null 2>&1; then echo "foreign daemon environment reached initial exec" >&2; exit 71; fi
done
case ":$PATH:" in *":$FOREIGN_DAEMON_DIR:"*) echo "foreign daemon PATH reached initial exec" >&2; exit 72;; esac
case "${PATH%%:*}" in "$TMPDIR"/repro-release-smoke-*/mock-package/bin) ;; *) exit 73;; esac
argument_file=""
while (( $# )); do
  if [[ "$1" == -ArgumentFile ]]; then argument_file=$2; break; fi
  shift
done
[[ -n "$argument_file" ]] || exit 74
{ IFS= read -r -d '' command; IFS= read -r -d '' verb; } < "$argument_file"
[[ "$verb" == exec ]] || exit 75
echo "initial archive exec isolation verified" >&2
# Refusal propagation only; this stand-in never grants a fake Windows success.
exit 23
""", encoding="utf-8")
        powershell.chmod(0o755)
        env = self._env_with(self.pkg / "bin", foreign)
        env.update(RUNQUOTAD_BIN=str(daemon), RUNQUOTA_BIN="foreign-cli",
                   RUNQUOTA_SOCKET="foreign-endpoint", REPROBUILD_NO_RUNQUOTA="1",
                   FOREIGN_DAEMON_DIR=str(foreign))
        result = self._run_smoke(shutil.which("bash") or "/bin/bash", env)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("initial archive exec isolation verified", result.stdout + result.stderr)
        self.assertNotIn("repro build smoke test PASSED", result.stdout)

    def test_deep_runner_root_keeps_only_the_private_socket_short(self):
        """Real filesystem/kernel probe of test data; not a RunQuota handshake."""
        deep = self.work / ("runner-" + "a" * 100) / ("work-" + "b" * 100)
        deep.mkdir(parents=True)
        audit = self.work / "socket-audit.jsonl"
        probe = self.work / "probe_socket.py"
        probe.write_text("""import json, os, socket, stat
path = os.environ['RUNQUOTA_SOCKET']
parent = os.path.dirname(path)
metadata = os.stat(parent)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as endpoint:
    endpoint.bind(path)
os.unlink(path)
print(json.dumps({'path': path, 'uid': metadata.st_uid,
                  'mode': stat.S_IMODE(metadata.st_mode), 'cwd': os.getcwd()}))
""", encoding="utf-8")
        binary = self.pkg / "bin/repro"
        prefix = ('  "$REPRO_TEST_PYTHON" "$REPRO_TEST_SOCKET_PROBE" '
                  '>> "$REPRO_TEST_SOCKET_AUDIT"\n')
        binary.write_text(binary.read_text().replace(self.BUILD_BODY,
                          prefix + self.BUILD_BODY), encoding="utf-8")
        env = self._env_with()
        env.update(RUNNER_TEMP=str(deep), REPRO_TEST_PYTHON=sys.executable,
                   REPRO_TEST_SOCKET_PROBE=str(probe), REPRO_TEST_SOCKET_AUDIT=str(audit))
        result = self._run_smoke(shutil.which("bash") or "/bin/bash", env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        records = [json.loads(row) for row in audit.read_text().splitlines()]
        self.assertEqual(2, len(records), "both hidden and restored arms probed")
        self.assertEqual(records[0]['path'], records[1]['path'])
        for record in records:
            self.assertLessEqual(len(os.fsencode(record['path'])), 91)
            self.assertEqual(os.getuid(), record['uid'])
            self.assertEqual(0o700, record['mode'])
            self.assertTrue(record['cwd'].startswith(str(deep)))
            self.assertFalse(Path(record['path']).parent.exists(), "owned socket root cleaned")

    def test_wrong_cause_cannot_satisfy_the_hidden_daemon_control(self):
        for cause in ("socket path too long", "Permission denied", "handshake failed"):
            with self.subTest(cause=cause):
                binary = self.pkg / "bin/repro"
                original = binary.read_text(encoding="utf-8")
                wrong = ("  command -v runquotad >/dev/null 2>&1 && exit 0\n"
                         "  echo 'runquota daemon unreachable and bypass is disabled. "
                         f"Underlying error: {cause}' >&2\n  exit 1\n")
                binary.write_text(original.replace(self.BUILD_BODY, wrong), encoding="utf-8")
                try:
                    result = self._run_smoke(shutil.which("bash") or "/bin/bash", self._env_with())
                    self.assertNotEqual(0, result.returncode, result.stdout)
                    self.assertIn("valid endpoint", result.stderr)
                    self.assertNotIn("repro build smoke test PASSED", result.stdout)
                finally:
                    binary.write_text(original, encoding="utf-8")

    def test_a_build_that_is_never_refused_fails_the_control(self):
        """If the hidden-daemon build still succeeds, something else served it."""
        repro_bin = self.pkg / "bin" / "repro"
        repro_bin.write_text(
            repro_bin.read_text(encoding="utf-8").replace(self.BUILD_BODY, "  exit 0\n"),
            encoding="utf-8")
        res = self._run_smoke(shutil.which("bash") or "/bin/bash", self._env_with())
        self.assertNotEqual(0, res.returncode, res.stdout)
        self.assertIn("was not refused", res.stderr)


PWSH = os.environ.get("REPRO_TEST_PWSH") or shutil.which("pwsh") or shutil.which("powershell")


@unittest.skipUnless(PWSH, "PowerShell is required for actual argument binding")
class ReleaseSmokeWindowsArguments(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release-smoke-argv-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        source = ROOT / "scripts/release/with_windows_archive_runquota.ps1"
        self.probe = self.root / "probe.ps1"
        extractor = self.root / "extract.ps1"
        extractor.write_text(r"""param($Source, $Probe)
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$null)
$reader = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-CommandArguments'}, $true)
$quote = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Quote-NativeArgument'}, $true)
if (-not $reader -or -not $quote) { throw 'Production argument functions not found.' }
$emit = @'
$invocation = Read-CommandArguments $ArgumentFile
$data = @{command=$invocation.Command; arguments=@($invocation.Arguments); quoted=@($invocation.Arguments | ForEach-Object { Quote-NativeArgument $_ })} | ConvertTo-Json -Compress
[Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data)))
'@
[IO.File]::WriteAllText($Probe, $ast.ParamBlock.Extent.Text + "`n" + $reader.Extent.Text + "`n" + $quote.Extent.Text + "`n" + $emit)
""", encoding="utf-8")
        subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(extractor),
                        str(source), str(self.probe)], check=True, capture_output=True, timeout=30)

    def run_probe(self, data):
        carrier = self.root / "command.argv"
        carrier.write_bytes(data)
        return subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(self.probe),
                               "-ArchiveDaemon", r"C:\private archive\runquotad.exe",
                               "-ArgumentFile", str(carrier)],
                              capture_output=True, text=True, timeout=30)

    def test_original_commands_and_argument_boundaries_are_preserved(self):
        command = r"C:\private archive\repro.exe"
        vectors = [
            (["exec", "--", "bash", "-c", 'echo "$1"', "_", "marker"],
             ['"exec"', '"--"', '"bash"', '"-c"', r'"echo \"$1\""', '"_"', '"marker"']),
            (["build", "--daemon=off", "--tool-provisioning=tarball"],
             ['"build"', '"--daemon=off"', '"--tool-provisioning=tarball"']),
            (["exec", "--", "bash", "-c", "", "a b", 'a"b', "ends\\", "λ"],
             ['"exec"', '"--"', '"bash"', '"-c"', '""', '"a b"', r'"a\"b"', r'"ends\\"', '"λ"']),
        ]
        for args, quoted in vectors:
            with self.subTest(args=args):
                # This is the real Bash printf framing, including the final
                # delimiter. No shell evaluates the argument values.
                carrier = subprocess.check_output(["bash", "-c", "printf '%s\\0' \"$@\"", "_", command, *args])
                result = self.run_probe(carrier)
                self.assertEqual(0, result.returncode, result.stderr)
                actual = json.loads(base64.b64decode(result.stdout.strip()))
                self.assertEqual(command, actual["command"])
                self.assertEqual(args, actual["arguments"])
                self.assertEqual(quoted, actual["quoted"])

    def test_malformed_argument_carriers_are_refused(self):
        for carrier in (b"command\0unterminated", b"command\0\xff\0", b"\0argument\0"):
            with self.subTest(carrier=carrier):
                self.assertNotEqual(0, self.run_probe(carrier).returncode)


    def test_failed_bootstrap_refuses_before_later_release_work(self):
        just = shutil.which("just")
        self.assertIsNotNone(just, "the declared Just executable is required")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        lines = workflow.splitlines()
        starts = [index for index, line in enumerate(lines) if line == "          just bootstrap"]
        self.assertEqual(1, len(starts), "one owning Windows bootstrap invocation is required")
        start = starts[0]
        end = start + 1
        while end < len(lines) and lines[end].strip():
            end += 1
        fragment = textwrap.dedent("\n".join(lines[start:end]))
        runtime = str(Path(PWSH).resolve())
        shell = json.dumps([runtime, "-NoProfile", "-NonInteractive", "-Command"], ensure_ascii=False)
        (self.root / "Justfile").write_text(
            "set shell := " + shell + "\nset windows-shell := " + shell +
            "\nbootstrap:\n    exit $env:REPRO_TEST_BOOTSTRAP_EXIT\n", encoding="utf-8",
        )
        script = self.root / "workflow.ps1"

        def run(body, status):
            script.write_text(
                "$ErrorActionPreference = 'Stop'\n" +
                "$PSNativeCommandUseErrorActionPreference = $false\n" + body +
                "\nWrite-Output 'after-bootstrap'\n", encoding="utf-8",
            )
            environment = dict(os.environ, REPRO_TEST_BOOTSTRAP_EXIT=str(status))
            return subprocess.run(
                [PWSH, "-NoProfile", "-NonInteractive", "-File", str(script)],
                cwd=self.root, env=environment, capture_output=True, text=True, timeout=30,
            )

        # Observe Just's own nonzero exit (which need not preserve the
        # recipe child's numeric code) rather than assuming it is 23.
        direct = subprocess.run(
            [just, "bootstrap"], cwd=self.root,
            env=dict(os.environ, REPRO_TEST_BOOTSTRAP_EXIT="23"),
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(0, direct.returncode, direct.stdout + direct.stderr)
        self.assertIn("exit code 23", direct.stderr)
        failed = run(fragment, 23)
        self.assertNotEqual(0, failed.returncode, failed.stdout + failed.stderr)
        self.assertNotIn("after-bootstrap", failed.stdout)
        self.assertIn(f"reprobuild bootstrap failed (exit code {direct.returncode})", failed.stderr)
        passed = run(fragment, 0)
        self.assertEqual(0, passed.returncode, passed.stderr)
        self.assertIn("after-bootstrap", passed.stdout)
        # The exact predecessor call continues after the same failed native
        # Just command. Removing the guard falsifies the refusal above.
        predecessor = run("just bootstrap", 23)
        self.assertEqual(0, predecessor.returncode, predecessor.stderr)
        self.assertIn("after-bootstrap", predecessor.stdout)


class ReleaseInventoryTests(unittest.TestCase):
    """Execute the real verifier's membership block, without runtime probes.

    Empty regular files model only names/types in this durable unit fixture;
    they are never run as SDK binaries. Real archive execution stays in the
    unchanged verifier and installed smoke. The retained qualification also
    repeats these membership controls with authenticated package images.
    """

    APPS = {
        "repro", "reprobuild", "repro-peer-cache-tier2", "repro-peer-cache-admin",
        "repro-peer-cache-mint-cert", "repro-cmake-dyndep-fragment",
        "repro-cmake-trycompile-provider", "repro-standard-provider",
        "repro-install-mirror-publish", "repro-agent-conformance", "repro-binary-cache",
        "repro-binary-cache-crosshost", "repro-harvest-apt", "attestation-agent",
    }
    REQUIRED = APPS | {"runquotad", "runquota"}

    @staticmethod
    def inventory_block():
        script = (ROOT / "scripts/verify_release.sh").read_text(encoding="utf-8")
        start = script.index('exe_suffix=""\n')
        end = script.index('if [[ "$archive_name" != *.zip ]]; then', start)
        return script[start:end]

    def check_inventory(self, root, archive, block=None):
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "declared Bash is required")
        return subprocess.run(
            [bash, "-euo", "pipefail", "-c",
             'pkg_dir="$1"; archive_name="$2"\n' +
             (self.inventory_block() if block is None else block),
             "release-inventory", str(root), archive],
            capture_output=True, text=True, check=False, timeout=30,
        )

    def make_inventory(self, root, suffix):
        (root / "bin").mkdir()
        for name in self.REQUIRED:
            (root / "bin" / (name + suffix)).write_bytes(b"")

    def test_complete_release_inventory(self):
        for suffix, archive in (("", "release.tar.gz"), (".exe", "release.zip")):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                self.make_inventory(root, suffix)
                ran = self.check_inventory(root, archive)
                self.assertEqual(0, ran.returncode, ran.stderr)

    def test_every_required_member_is_independently_required(self):
        for suffix, archive in (("", "release.tar.gz"), (".exe", "release.zip")):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                self.make_inventory(root, suffix)
                for name in sorted(self.REQUIRED):
                    with self.subTest(member=name):
                        path = root / "bin" / (name + suffix)
                        path.unlink()
                        ran = self.check_inventory(root, archive)
                        self.assertNotEqual(0, ran.returncode, ran.stdout)
                        self.assertIn("MISSING bin/" + name + suffix, ran.stdout)
                        path.write_bytes(b"")

    def test_predecessor_accepts_missing_standard_provider(self):
        import re
        predecessor, count = re.subn(
            r"required_bins=\([^)]*\)", "required_bins=(runquotad runquota)",
            self.inventory_block(), count=1,
        )
        self.assertEqual(1, count)
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.make_inventory(root, "")
            (root / "bin/repro-standard-provider").unlink()
            self.assertEqual(0, self.check_inventory(
                root, "release.tar.gz", predecessor).returncode)
            self.assertNotEqual(0, self.check_inventory(root, "release.tar.gz").returncode)

    def test_inventory_matches_existing_release_graph(self):
        import re
        recipe = (ROOT / "repro.nim").read_text(encoding="utf-8")
        native_edges = re.findall(
            r"reprobuildAppsActions\.add\(nim\.c\((.*?)\)\)", recipe, re.S)
        apps = [re.search(r'binary\s*=\s*"build/bin/([^"/]+)"', edge).group(1)
                for edge in native_edges]
        self.assertEqual(len(apps), len(set(apps)), "duplicate release app output")
        self.assertEqual(self.APPS, set(apps))
        block = self.inventory_block()
        inventory = re.search(r"required_bins=\(([^)]*)\)", block).group(1).split()
        self.assertEqual(len(inventory), len(set(inventory)))
        self.assertEqual(self.REQUIRED, set(inventory))


if __name__ == "__main__":
    unittest.main()
