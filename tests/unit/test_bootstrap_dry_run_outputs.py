"""A build script must not report success while deliberately omitting its outputs.

Run the real bootstrap entry points. The cache adapter is stubbed to return the
existing dry-run sentinel so this exercises the script exit contract without a
cache server or toolchain build. Placeholder prerequisites satisfy preflight only;
no compiler is executed, and real source extraction uses an empty local archive.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest


class BootstrapDryRunOutputs(unittest.TestCase):
    def test_dry_runs_cannot_succeed_as_build_actions(self):
        scripts = Path(__file__).resolve().parents[2] / "recipes/bootstrap/tcc-chain/scripts"
        with tempfile.TemporaryDirectory(prefix="repro-bootstrap-dry-run-") as scratch:
            root = Path(scratch)
            for name in ("hex0", "M2", "M1", "hex2", "blood-elf-0", "kaem-unwrapped"):
                path = root / name
                path.touch()
                path.chmod(0o755)
            for name in ("M1", "M2", "M2-Planet", "M2-Mesoplanet", "blood-elf", "hex2",
                         "replace", "mkdir", "cp", "chmod", "get_machine", "mes", "mes-m2", "mescc.scm"):
                path = root / "bin" / name
                path.parent.mkdir(exist_ok=True)
                path.touch()
                path.chmod(0o755)
            for name in ("libc-mini.a", "libmescc.a", "libc.a", "libc+tcc.a", "crt1.o"):
                path = root / "lib/x86_64-mes" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            for name in ("include", "lib"):
                (root / "share/mes-0.27.1" / name).mkdir(parents=True)
            for name in ("mes-0.27.1.tar.gz", "nyacc-1.09.1.tar.gz", "tinycc-bootstrappable.tar.gz"):
                (root / name).touch()
            with tarfile.open(root / "minimal-bootstrap-sources.tar.gz", "w:gz"):
                pass
            startup = root / "startup.sh"
            startup.write_text("""source() {
  builtin source "$@"
  cache_repro_binary_cache_client_bin() { return 0; }
  cache_phase_prepare() { CACHE_HIT=2; CACHE_KEY_HEX=deadbeef; }
}
""")
            for name in ("hex0", "stage0-posix", "mescc-tools", "mes", "tcc"):
                with self.subTest(name=name):
                    result = subprocess.run(
                        ["bash", str(scripts / f"build-{name}.sh"), scratch, scratch, scratch, scratch],
                        env={**os.environ, "REPRO_CACHE_DRY_RUN": "1", "BASH_ENV": str(startup)},
                        capture_output=True, text=True,
                    )
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("cannot produce declared outputs", result.stderr)

    def test_common_cache_prelude_cannot_report_lookup_only_success(self):
        helper = Path(__file__).resolve().parents[2] / "recipes/cache/scripts/cache-helper.sh"
        command = 'source "$1"\ncache_default_host_identity_flags() { CACHE_HOST_IDENTITY_FLAGS=(); }\ncache_default_platform_flags() { CACHE_PLATFORM_FLAGS=(); }\ncache_derive_key() { echo deadbeef; }\ncache_lookup() { echo miss; return 1; }\ncache_phase_prepare script output --package-name=example\n'
        result = subprocess.run(["bash", "-c", command, "test", str(helper)],
            env={**os.environ, "REPRO_CACHE_DRY_RUN": "1"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("cannot produce declared outputs", result.stderr)


if __name__ == "__main__":
    unittest.main()
