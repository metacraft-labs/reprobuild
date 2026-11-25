"""The release verifier works where gpg-agent cannot start.

WHY THIS FILE EXISTS

scripts/release-signing/repro-verify-release.sh imports the trust anchor into
a fresh GNUPGHOME and checks the release's signatures. It needs only public
keys, but gpg starts gpg-agent for every --import unless told not to. The
agent binds its sockets in the per-user runtime directory (/run/user/<uid>)
when there is one and in GNUPGHOME otherwise, which is the case for Git for
Windows' MSYS2 gpg and for an account without a login session. A socket path
longer than sun_path's 107 characters makes the agent exit 2, and gpg then
fails the import although it imported the key. On a real Windows host every
archive install leg of the Windows completion check was refused that way:

    gpg: error running '/usr/bin/gpg-agent': exit status 2
    gpg: failed to start gpg-agent '/usr/bin/gpg-agent': General error
    gpg: can't connect to the gpg-agent: General error
    REJECTED: no OpenPGP keys imported from metacraft-labs-archive-keyring.asc

with GNUPGHOME under a TMPDIR of the form %TEMP%\\<dir>\\tmp.

The verifier now runs gpg with --no-autostart and reads whether a key was
imported from gpg's IMPORT_OK status line. The cases:

  1. With an agent that can never start, the verifier still accepts a
     correctly signed release, and the agent is never run.
  2. The same verifier still REJECTS when the keyring holds no key, so the
     status-line check is not a blanket pass.
  3. With a GNUPGHOME whose agent sockets do not fit sun_path and no runtime
     directory (Linux, under bubblewrap with /run/user hidden), the verifier
     accepts the release: the failure as it happens on Windows, with nothing
     stubbed.

WHAT IS STUBBED, AND WHY

Cases 1 and 2 run gpg through a wrapper (REPRO_GPG_BIN, the verifier's own
override) that adds `--agent-program <a script that records its run and
exits 2>`. That makes "the agent cannot start" happen on any host, where the
real cause (a socket path that does not fit and no runtime directory) cannot
be produced without a mount namespace. gpg itself, the keys, the signatures
and the verifier are real. Case 3 needs no stub, and is skipped, which counts
as not passed, where bubblewrap or user namespaces are unavailable.

It needs gpg and sha256sum (the dev shell has both):
  python3 -m unittest -v tests.unit.test_verify_release_needs_no_agent
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SIGN_DIR = REPO_ROOT / "scripts" / "release-signing"
VERIFY = SIGN_DIR / "repro-verify-release.sh"
ARTIFACT = "reprobuild-9.8.7-windows-x86_64.zip"

# An agent that cannot start: it records that gpg ran it, then exits 2,
# as gpg-agent does when its socket name is too long.
FAILING_AGENT = """#!/bin/sh
echo "started $*" >> "$(dirname "$0")/agent-runs.txt"
echo "gpg-agent stand-in: socket name is too long" >&2
exit 2
"""

GPG_WRAPPER = """#!/bin/sh
exec "{gpg}" --agent-program "{agent}" "$@"
"""


def _write_exec(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _run(args, env, cwd=None):
    return subprocess.run(args, env=env, cwd=cwd, capture_output=True, text=True, timeout=300)


class VerifierNeedsNoAgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gpg = shutil.which("gpg")
        if not cls.gpg or not shutil.which("sha256sum"):
            raise unittest.SkipTest("gpg and sha256sum are required (the dev shell has both)")
        cls.tmp = Path(tempfile.mkdtemp(prefix="rv-noagent-"))
        cls.env = dict(os.environ)
        cls.env["TMPDIR"] = str(cls.tmp)
        cls.env.pop("GNUPGHOME", None)
        # A signed release directory, made by the repository's own scripts
        # with a throwaway test key, as the Windows check makes its own.
        cls.signhome = cls.tmp / "s"
        r = _run(["sh", str(SIGN_DIR / "make-test-key.sh"), "--home", str(cls.signhome)], cls.env)
        if r.returncode != 0:
            raise AssertionError(f"make-test-key.sh failed: {r.stdout}{r.stderr}")
        cls.fpr = r.stdout.strip().splitlines()[-1]
        cls.release = cls.tmp / "release"
        cls.release.mkdir()
        (cls.release / ARTIFACT).write_bytes(b"placeholder archive bytes\n")
        senv = dict(cls.env, GNUPGHOME=str(cls.signhome), REPRO_SIGNING_ALLOW_TEST_KEY="1")
        r = _run(["sh", str(SIGN_DIR / "repro-sign-release.sh"), "--dir", str(cls.release), "--key", cls.fpr], senv)
        if r.returncode != 0:
            raise AssertionError(f"repro-sign-release.sh failed: {r.stdout}{r.stderr}")
        cls.keyring = cls.tmp / "keyring.asc"
        r = _run([cls.gpg, "--homedir", str(cls.signhome), "--armor", "--export", cls.fpr], cls.env)
        cls.keyring.write_text(r.stdout)
        _run(["gpgconf", "--homedir", str(cls.signhome), "--kill", "all"], cls.env)
        # The failing agent and the gpg that uses it.
        cls.agentdir = cls.tmp / "agent"
        cls.agentdir.mkdir()
        _write_exec(cls.agentdir / "gpg-agent", FAILING_AGENT)
        _write_exec(cls.agentdir / "gpg", GPG_WRAPPER.format(gpg=cls.gpg, agent=cls.agentdir / "gpg-agent"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _verify(self, keyring: Path, env=None):
        env = dict(env or self.env)
        env["REPRO_GPG_BIN"] = str(self.agentdir / "gpg")
        return _run(["sh", str(VERIFY), "--keyring", str(keyring), "--dir", str(self.release),
                     "--artifact", ARTIFACT, "--allow-test-key"], env)

    def test_accepts_a_signed_release_when_no_agent_can_start(self):
        runs = self.agentdir / "agent-runs.txt"
        if runs.exists():
            runs.unlink()
        r = self._verify(self.keyring)
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 0, out)
        self.assertIn(f"ACCEPTED 1 artifact(s), signer {self.fpr}", out)
        self.assertIn("trust anchor: 1 key(s)", out)
        self.assertFalse(runs.exists(), "gpg started the agent: " + (runs.read_text() if runs.exists() else ""))

    def test_still_rejects_a_keyring_with_no_key(self):
        empty = self.tmp / "empty.asc"
        empty.write_text("not an OpenPGP key\n")
        r = self._verify(empty)
        out = r.stdout + r.stderr
        self.assertNotEqual(r.returncode, 0, out)
        self.assertIn("REJECTED: no OpenPGP keys imported", out)

    def test_accepts_when_the_agent_socket_would_not_fit_and_there_is_no_runtime_dir(self):
        bwrap = shutil.which("bwrap")
        if not bwrap:
            self.skipTest("bubblewrap is not installed (nix shell nixpkgs#bubblewrap)")
        probe = _run([bwrap, "--dev-bind", "/", "/", "--tmpfs", "/run/user", "--", "true"], self.env)
        if probe.returncode != 0:
            self.skipTest(f"bubblewrap cannot make a mount namespace here: {probe.stderr.strip()}")
        # A TMPDIR deep enough that GNUPGHOME/S.gpg-agent.browser exceeds 107
        # characters, as %TEMP%\<dir>\tmp did on Windows.
        deep = self.tmp / ("d" * 40) / ("m8c-install-completion-" + "0" * 8) / "tmp"
        deep.mkdir(parents=True)
        home_len = len(str(deep)) + len("/repro-verify-gnupg-XXXXXX/S.gpg-agent.browser")
        self.assertGreater(home_len, 107, "the TMPDIR is not deep enough to test anything")
        env = dict(self.env, TMPDIR=str(deep))
        # Control: plain gpg in such a home cannot import without an agent.
        ctl = _run([bwrap, "--dev-bind", "/", "/", "--tmpfs", "/run/user", "--", "sh", "-c",
                    'h="$(mktemp -d "$TMPDIR/repro-verify-gnupg-XXXXXX")"; chmod 700 "$h"; '
                    f'"{self.gpg}" --batch --homedir "$h" --import "{self.keyring}"; rc=$?; rm -rf "$h"; exit $rc'], env)
        self.assertNotEqual(ctl.returncode, 0, "control: gpg imported without an agent; the case tests nothing")
        self.assertIn("gpg-agent", ctl.stderr)
        r = _run([bwrap, "--dev-bind", "/", "/", "--tmpfs", "/run/user", "--", "sh", str(VERIFY),
                  "--keyring", str(self.keyring), "--dir", str(self.release), "--artifact", ARTIFACT,
                  "--allow-test-key"], env)
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 0, out)
        self.assertIn(f"ACCEPTED 1 artifact(s), signer {self.fpr}", out)


if __name__ == "__main__":
    unittest.main()
