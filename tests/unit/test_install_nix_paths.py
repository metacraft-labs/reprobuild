"""`repro-install.sh` on NixOS prints the fork snippet; `--method nix` uses a profile.

WHY THIS FILE EXISTS

For Nix users the package repository is the `metacraft-labs/nixpkgs` fork,
whose standing branches are named after the upstream channel each one tracks
(metacraft-specs `infrastructure/package-distribution.md` §6.4, §13). On
NixOS the installer must not install anything: it detects the system's
channel, picks the fork branch of the same name, and PRINTS the configuration
change. It never edits `/etc/nixos`, and it never registers an apt/dnf
repository just because such a tool happens to be on PATH. Elsewhere,
`--method nix` installs into the user's Nix profile from the fork.

Every case drives the REAL installer script and asserts on its exit status,
its stdout (the snippet a user copies) and on which external commands it ran.

WHAT IS STUBBED, AND WHY

* `/etc/os-release`, `/etc/NIXOS` and `/etc/nixos` are redirected to files in
  a temporary directory through the installer's documented
  `REPRO_OS_RELEASE`, `REPRO_NIXOS_MARKER` and `REPRO_NIXOS_CONFIG_DIR`
  knobs. The subject is how the installer reads a NixOS system, and this test
  host is not one.
* Which branches the fork has comes from `REPRO_NIX_BRANCHES` instead of a
  request to github.com, so the cases are deterministic and run offline.
* `nix`, `apt-get`, `dnf`, `pacman` and `sudo` on PATH are recording stubs.
  For `nix` the subject is the command line handed to it: a real
  `nix profile install` of the fork would build reprobuild from source and
  modify the profile of whoever runs the suite. The other four are
  tripwires: the NixOS path must run none of them, and a stub that records
  is the only way to observe that it did not.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "scripts" / "install" / "repro-install.sh"
FORK = "github:metacraft-labs/nixpkgs"

RECORDER = """#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
if [ "$(basename "$0")" = nix ] && [ -n "${STUB_NIX_PROFILE_LIST:-}" ]; then
  case " $* " in *" profile list "*) printf '%s\\n' "$STUB_NIX_PROFILE_LIST" ;; esac
fi
exit 0
"""


class InstallerNixPathsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for tool in ("nix", "apt-get", "dnf", "pacman", "sudo"):
            stub = self.bin / tool
            stub.write_text(RECORDER)
            stub.chmod(0o755)
        self.log = self.tmp / "calls.log"
        self.log.write_text("")
        self.os_release = self.tmp / "os-release"
        self.config_dir = self.tmp / "etc-nixos"
        self.config_dir.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def os(self, text):
        self.os_release.write_text(text)

    def flake(self, nixpkgs_url):
        (self.config_dir / "flake.nix").write_text(
            "{\n  inputs.nixpkgs.url = \"%s\";\n}\n" % nixpkgs_url
        )

    def run_installer(self, *args, branches="nixos-unstable nixpkgs-unstable "
                      "nixos-26.05 nixpkgs-26.05-darwin", marker=None, env=None):
        full_env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:{os.environ.get('PATH', '')}",
            "HOME": str(self.tmp),
            "STUB_LOG": str(self.log),
            "REPRO_OS_RELEASE": str(self.os_release),
            "REPRO_NIXOS_MARKER": str(marker or (self.tmp / "no-such-marker")),
            "REPRO_NIXOS_CONFIG_DIR": str(self.config_dir),
            "REPRO_NIX_BRANCHES": branches,
        }
        full_env.update(env or {})
        return subprocess.run(
            ["sh", str(INSTALLER), *args],
            env=full_env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def calls(self):
        return self.log.read_text().splitlines()

    # -- NixOS ------------------------------------------------------------

    def test_nixos_flake_config_gets_the_branch_its_nixpkgs_follows(self):
        self.os('ID=nixos\nVERSION_ID="26.05"\n')
        self.flake("github:NixOS/nixpkgs/nixos-26.05")
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f'inputs.metacraft.url = "{FORK}/nixos-26.05";', proc.stdout)
        self.assertIn(".legacyPackages.${pkgs.stdenv.hostPlatform.system}.reprobuild",
                      proc.stdout)
        self.assertIn("sudo nixos-rebuild switch", proc.stdout)
        self.assertIn("method=nixos", proc.stderr)
        self.assertEqual(self.calls(), [])

    def test_the_flake_input_wins_over_the_os_release_version(self):
        # A 26.05 system whose flake already follows nixos-unstable.
        self.os('ID=nixos\nVERSION_ID="26.05"\n')
        self.flake("github:NixOS/nixpkgs/nixos-unstable")
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f'"{FORK}/nixos-unstable"', proc.stdout)
        self.assertNotIn("nixos-26.05", proc.stdout)

    def test_channel_config_gets_a_nix_channel_snippet_for_its_release(self):
        self.os('ID=nixos\nVERSION_ID="26.05"\n')
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(
            "sudo nix-channel --add https://github.com/metacraft-labs/nixpkgs/"
            "archive/nixos-26.05.tar.gz metacraft",
            proc.stdout,
        )
        self.assertIn("(import <metacraft> { }).reprobuild", proc.stdout)
        self.assertNotIn("inputs.metacraft", proc.stdout)
        self.assertEqual(self.calls(), [])

    def test_a_release_the_fork_does_not_carry_falls_back_to_unstable_and_says_so(self):
        self.os('ID=nixos\nVERSION_ID="25.11"\n')
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("archive/nixos-unstable.tar.gz", proc.stdout)
        self.assertIn("has no branch nixos-25.11", proc.stderr)

    def test_the_nixos_marker_alone_is_enough(self):
        # ID=nixos is missing (a customised os-release); /etc/NIXOS is not.
        self.os('ID=linux\nVERSION_ID="26.05"\n')
        marker = self.tmp / "NIXOS"
        marker.write_text("")
        proc = self.run_installer(marker=marker)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("method=nixos", proc.stderr)
        self.assertIn("archive/nixos-26.05.tar.gz", proc.stdout)

    def test_nixos_never_registers_a_system_repository(self):
        # apt-get and dnf are on PATH (as in a dev shell); ID_LIKE even says
        # debian. The NixOS answer is still the snippet, not a repository.
        self.os('ID=nixos\nID_LIKE=debian\nVERSION_ID="26.05"\n')
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("archive/nixos-26.05.tar.gz", proc.stdout)
        self.assertEqual(self.calls(), [])
        self.assertFalse(any(p.name.endswith(".sources") for p in self.tmp.rglob("*")))

    def test_nixos_uninstall_explains_instead_of_removing(self):
        self.os('ID=nixos\nVERSION_ID="26.05"\n')
        proc = self.run_installer("--uninstall")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("To remove Reprobuild", proc.stdout)
        self.assertIn("sudo nixos-rebuild switch", proc.stdout)
        self.assertEqual(self.calls(), [])

    def test_an_explicit_branch_overrides_detection(self):
        self.os('ID=nixos\nVERSION_ID="26.05"\n')
        self.flake("github:NixOS/nixpkgs/nixos-26.05")
        proc = self.run_installer(env={"REPRO_NIX_BRANCH": "nixos-unstable"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f'"{FORK}/nixos-unstable"', proc.stdout)

    # -- Nix elsewhere ----------------------------------------------------

    def test_method_nix_installs_from_the_forks_nixpkgs_unstable(self):
        self.os('ID=debian\nVERSION_ID="12"\n')
        proc = self.run_installer("--method", "nix")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        installs = [c for c in self.calls() if " profile install " in f" {c} "]
        self.assertEqual(len(installs), 1, self.calls())
        self.assertTrue(installs[0].endswith(f"{FORK}/nixpkgs-unstable#reprobuild"),
                        installs[0])
        self.assertFalse(any(c.startswith(("apt-get", "dnf", "sudo")) for c in self.calls()))

    def test_method_nix_upgrades_an_existing_fork_install(self):
        self.os('ID=debian\nVERSION_ID="12"\n')
        proc = self.run_installer(
            "--method", "nix",
            env={"STUB_NIX_PROFILE_LIST":
                 f"Name: reprobuild\nOriginal flake URL: {FORK}/nixpkgs-unstable"},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(c.endswith("profile upgrade reprobuild") for c in self.calls()),
                        self.calls())
        self.assertFalse(any(" profile install " in f" {c} " for c in self.calls()))

    def test_method_nix_uninstall_removes_the_profile_entry(self):
        self.os('ID=debian\nVERSION_ID="12"\n')
        proc = self.run_installer("--method", "nix", "--uninstall")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(c.endswith("profile remove reprobuild") for c in self.calls()),
                        self.calls())


if __name__ == "__main__":
    unittest.main()
