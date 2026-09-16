#!/usr/bin/env python3
"""HAX-M2 Windows PE IAT dispatch-table gate.

allowed_mocks: none. The test builds a real DLL and an importing PE with MSVC,
then exercises the production dispatch table against the loaded image. The
observable is the imported function's return value before publication, after
publication, after rollback, and after commit.
"""

from pathlib import Path
import subprocess
import sys
import unittest


REPO = Path(__file__).resolve().parents[2]
AGENT = REPO / "libs" / "repro_hcr_agent"
FIXTURE = REPO / "tests" / "fixtures" / "hcr" / "windows-dispatch"

sys.path.insert(0, str(AGENT))
from build_windows_agent import run_checked, visual_studio_environment


@unittest.skipUnless(sys.platform == "win32", "requires Windows")
class WindowsDispatchTableGate(unittest.TestCase):
    def test_real_pe_iat_transaction_rolls_back_and_commits(self) -> None:
        env = visual_studio_environment()
        work = REPO / "build" / "hax-m2-windows-dispatch"
        work.mkdir(parents=True, exist_ok=True)
        dll = work / "hax_m2_dispatch_dll.dll"
        import_library = work / "hax_m2_dispatch_dll.lib"
        target = work / "hax_m2_dispatch_target.exe"
        run_checked(
            [
                "cl.exe",
                "/nologo",
                "/std:c11",
                "/W4",
                "/WX",
                "/O2",
                "/MD",
                "/LD",
                str(FIXTURE / "hax_m2_dispatch_dll.c"),
                f"/Fe:{dll}",
                "/link",
                f"/IMPLIB:{import_library}",
            ],
            REPO,
            env,
        )
        run_checked(
            [
                "cl.exe",
                "/nologo",
                "/std:c11",
                "/W4",
                "/WX",
                "/Od",
                "/MD",
                f"/I{AGENT / 'c'}",
                str(FIXTURE / "hax_m2_dispatch_target.c"),
                str(AGENT / "c" / "repro_hcr_dispatch_table.c"),
                str(import_library),
                f"/Fe:{target}",
            ],
            REPO,
            env,
        )
        completed = subprocess.run(
            [str(target)],
            cwd=work,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn(
            "PASS: real PE IAT publication, rollback, and commit",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
