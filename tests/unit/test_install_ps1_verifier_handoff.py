"""The PowerShell installer hands the signature verifier names it can read.

WHY THIS FILE EXISTS

scripts/install/repro-install.ps1's archive method verifies the downloaded
release before extracting it, by running scripts/release-signing/
repro-verify-release.sh under a POSIX shell. On Windows that shell, and the
gpg it finds, are ports (Git for Windows' MSYS2 programs, or another one),
and they do not all read a Windows path the same way: MSYS2 converts some
arguments and leaves others, and gpg resolves a path it does not recognise as
absolute against its working directory
(https://www.msys2.org/docs/filesystem-paths/). An install whose verifier
cannot read the keyring it was handed refuses with "no OpenPGP keys
imported", which is what every archive install leg of the Windows completion
check printed on a real Windows host.

So the installer runs the verifier IN its work directory and names the
keyring and the download directory relative to it: `--keyring <file name>`
and `--dir .`. A relative name with no drive and no separator means the same
file to every shell and every gpg. The first case pins that contract: the
names, and that they reach the downloaded files from the verifier's working
directory. The second pins that a verifier override (REPRO_VERIFY_SCRIPT)
given relative to the caller's directory still runs from there.

WHAT IS STUBBED, AND WHY

The verifier is a stand-in (REPRO_VERIFY_SCRIPT, the installer's own
override): it records the arguments and the files it can reach, then refuses,
so nothing is extracted or installed. What is under test is the installer's
hand-off, which the stand-in observes exactly as the real verifier would
receive it; the real verifier's handling of a keyring is covered by the
signing harness (tools/multi-distro-harness/tests/m2_signing_*.sh) and, end to
end, by m8c_install_completion_windows.ps1, which runs the real verifier. The
release host is a local HTTP server over a directory of placeholder files: the
installer only downloads them and checks the keyring's digest before handing
over. The installer itself is the real script under the real pwsh.

It needs pwsh and sh, and is skipped, which counts as not passed, without
them:
  nix shell nixpkgs#powershell nixpkgs#python3 -c \
    python3 -m unittest tests.unit.test_install_ps1_verifier_handoff
"""

import hashlib
import http.server
import os
import platform
import shutil
import subprocess
import tempfile
import threading
import unittest
from functools import partial
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "scripts" / "install" / "repro-install.ps1"
VERSION = "9.8.7"
KEYRING = "metacraft-labs-archive-keyring.asc"

# Records what the installer handed over and whether the names reach the
# files from the working directory it was started in, then refuses.
STANDIN_VERIFIER = r"""#!/bin/sh
log="$HANDOFF_LOG"
keyring=""; dir=""; artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keyring) keyring="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --artifact) artifact="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'keyring=%s\n' "$keyring"
  printf 'dir=%s\n' "$dir"
  printf 'artifact=%s\n' "$artifact"
  if [ -f "$keyring" ] && grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$keyring"; then
    echo keyring-readable=yes
  else
    echo keyring-readable=no
  fi
  if [ -f "$dir/SHA256SUMS" ] && [ -f "$dir/SHA256SUMS.asc" ] && [ -f "$dir/$artifact" ]; then
    echo dir-readable=yes
  else
    echo dir-readable=no
  fi
} > "$log"
echo 'stand-in verifier: refusing' >&2
exit 1
"""


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # the server's access log is noise here
        pass


@unittest.skipUnless(shutil.which("pwsh") and shutil.which("sh"),
                     "needs pwsh (PowerShell 7) and sh")
class InstallerVerifierHandoffTests(unittest.TestCase):

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="repro-install-handoff-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        arch = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64",
                "arm64": "aarch64"}.get(platform.machine().lower())
        if arch is None:
            self.skipTest(f"no release asset for machine {platform.machine()}")
        self.asset = f"reprobuild-{VERSION}-windows-{arch}.zip"
        www = self.work / "www"
        dl = www / "downloads" / f"v{VERSION}"
        dl.mkdir(parents=True)
        for name in (self.asset, "SHA256SUMS", "SHA256SUMS.asc", self.asset + ".asc"):
            (dl / name).write_text(f"placeholder {name}\n", encoding="utf-8")
        (www / "keys").mkdir()
        keyring = www / "keys" / KEYRING
        keyring.write_text("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nplaceholder\n"
                           "-----END PGP PUBLIC KEY BLOCK-----\n", encoding="utf-8")
        self.keyring_sha = hashlib.sha256(keyring.read_bytes()).hexdigest()
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), partial(_QuietHandler, directory=str(www)))
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.base_url = f"http://127.0.0.1:{server.server_address[1]}"
        self.verifier = self.work / "verifier-standin.sh"
        self.verifier.write_text(STANDIN_VERIFIER, encoding="utf-8")
        self.verifier.chmod(0o755)
        self.log = self.work / "handoff.txt"
        for d in ("home", "tmp", "prefix-parent"):
            (self.work / d).mkdir()
        self.prefix = self.work / "prefix-parent" / "prefix"

    def run_installer(self, installer=INSTALLER, verifier=None):
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(self.work / "home"),
            "TMPDIR": str(self.work / "tmp"),
            "TEMP": str(self.work / "tmp"),
            "TMP": str(self.work / "tmp"),
            "REPRO_BASE_URL": self.base_url,
            "REPRO_KEYRING_SHA256": self.keyring_sha,
            "REPRO_VERIFY_SCRIPT": verifier or str(self.verifier),
            "REPRO_ALLOW_TEST_KEY": "1",
            "HANDOFF_LOG": str(self.log),
            "POWERSHELL_TELEMETRY_OPTOUT": "1",
            "POWERSHELL_UPDATECHECK": "Off",
        }
        return subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(installer),
             "-Method", "tarball", "-Version", VERSION, "-Prefix", str(self.prefix)],
            capture_output=True, text=True, check=False, env=env,
            cwd=str(self.work), timeout=300)

    def handoff(self):
        self.assertTrue(self.log.exists(), "the verifier was never started")
        result = {}
        for line in self.log.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            result[key] = value
        return result

    def assert_relative_handoff(self, run):
        output = run.stdout + run.stderr
        # The stand-in's refusal stops the install, and nothing is extracted.
        self.assertNotEqual(0, run.returncode, output)
        self.assertIn("signature verification failed", output)
        self.assertFalse((self.prefix / "bin").exists(), output)
        got = self.handoff()
        self.assertEqual(KEYRING, got.get("keyring"), output)
        self.assertEqual(".", got.get("dir"), output)
        self.assertEqual(self.asset, got.get("artifact"), output)
        self.assertEqual("yes", got.get("keyring-readable"), output)
        self.assertEqual("yes", got.get("dir-readable"), output)

    def test_the_verifier_gets_names_relative_to_its_working_directory(self):
        self.assert_relative_handoff(self.run_installer())

    def test_a_relative_verifier_override_still_runs(self):
        # REPRO_VERIFY_SCRIPT names a file relative to the caller's
        # directory (the installer is started in self.work); the verifier
        # is started from the installer's work directory, so the installer
        # must resolve the name before it changes directory.
        self.assert_relative_handoff(self.run_installer(verifier=self.verifier.name))


if __name__ == "__main__":
    unittest.main()
