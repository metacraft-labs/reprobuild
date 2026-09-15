#!/usr/bin/env python3
"""HX-W-6 real Windows debugger, patch-DLL, and PDB gate.

``allowed_mocks: none``. This gate builds real MSVC x64 images and full linker
PDBs, drives the real Windows debugger engine through its automatable CDB
front end, and exercises the production debugger-aware delivery selector.
The negative arm substitutes a real but mismatched linker PDB.

The filename intentionally lacks a ``test_`` prefix. Required Windows CI runs
it directly, while non-Windows hosts must not report this gate as skipped.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-6 debugger/PDB gate must run on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    required_tool,
    run_checked,
    tool_banner,
    visual_studio_environment,
)


def find_cdb(env: dict[str, str]) -> str:
    found = shutil.which("cdb.exe", path=env.get("PATH"))
    if found:
        return found
    roots = []
    if env.get("ProgramFiles(x86)"):
        roots.append(Path(env["ProgramFiles(x86)"]) / "Windows Kits" / "10")
    roots.append(Path(r"C:\Program Files (x86)\Windows Kits\10"))
    for root in roots:
        candidate = root / "Debuggers" / "x64" / "cdb.exe"
        if candidate.is_file():
            return str(candidate)
    raise AssertionError("x64 cdb.exe from Debugging Tools for Windows is required")


class HxW6WindowsDebugger(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = Path(__file__).resolve().parents[2]
        cls.fixture = cls.repo / "tests" / "fixtures" / "hcr" / "windows-debugger"
        cls.work = cls.repo / "build" / "hcr-w6-windows-debugger"
        cls.positive = cls.work / "positive"
        cls.mismatch = cls.work / "mismatched-pdb"
        cls.logs = cls.repo / "test-logs"
        for directory in (cls.work, cls.positive, cls.mismatch, cls.logs):
            directory.mkdir(parents=True, exist_ok=True)

        cls.env = visual_studio_environment()
        cls.cl = required_tool("cl.exe", cls.env)
        cls.link = required_tool("link.exe", cls.env)
        cls.dumpbin = required_tool("dumpbin.exe", cls.env)
        cls.nim = required_tool("nim.exe", cls.env)
        cls.cdb = find_cdb(cls.env)

        cls.target = cls.positive / "hcr_w6_target.exe"
        cls.patch = cls.positive / "hcr_w6_patch.dll"
        cls.patch_pdb = cls.positive / "hcr_w6_patch.pdb"
        cls._build_target()
        cls._build_patch(cls.positive, mismatch=False)
        wrong_dir = cls.work / "wrong-build"
        wrong_dir.mkdir(parents=True, exist_ok=True)
        cls._build_patch(wrong_dir, mismatch=True)

        shutil.copy2(cls.patch, cls.mismatch / cls.patch.name)
        shutil.copy2(wrong_dir / "hcr_w6_patch.pdb", cls.mismatch / cls.patch_pdb.name)

        headers = run_checked(
            [cls.dumpbin, "/nologo", "/headers", str(cls.patch)],
            cls.repo,
            cls.env,
        )
        for required in ("Debug Directories", "Exception Directory", "Format: RSDS"):
            if required not in headers:
                raise AssertionError(f"patch DLL lacks {required}\n{headers}")

        cls.selector = cls.work / "hx_w6_windows_debugger_selection.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                f"--nimcache:{cls.work / 'nimcache'}",
                f"--out:{cls.selector}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_agent' / 'src'}",
                str(cls.repo / "tests" / "windows" / "hx_w6_windows_debugger_selection.nim"),
            ],
            cls.repo,
            cls.env,
        )

    @classmethod
    def _compile(cls, source: Path, output: Path, pdb: Path,
                 definitions: list[str] | None = None) -> None:
        args = [
            cls.cl,
            "/nologo",
            "/c",
            "/Od",
            "/Zi",
            "/Zo",
            "/W4",
            "/WX",
            "/GS",
            *(definitions or []),
            f"/Fo{output}",
            f"/Fd{pdb}",
            str(source),
        ]
        run_checked(args, cls.repo, cls.env)

    @classmethod
    def _build_target(cls) -> None:
        obj = cls.positive / "hcr_w6_target.obj"
        cls._compile(
            cls.fixture / "hcr_w6_target.c",
            obj,
            cls.positive / "hcr_w6_target_compile.pdb",
        )
        run_checked(
            [
                cls.link,
                "/nologo",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOREF",
                "/OPT:NOICF",
                "/SUBSYSTEM:CONSOLE",
                f"/OUT:{cls.target}",
                f"/PDB:{cls.positive / 'hcr_w6_target.pdb'}",
                "/PDBALTPATH:%_PDB%",
                obj,
            ],
            cls.repo,
            cls.env,
        )

    @classmethod
    def _build_patch(cls, directory: Path, mismatch: bool) -> None:
        obj = directory / "hcr_w6_patch.obj"
        cls._compile(
            cls.fixture / "hcr_w6_patch.c",
            obj,
            directory / "hcr_w6_patch_compile.pdb",
            ["/DHX_W6_MISMATCH_BUILD=1"] if mismatch else None,
        )
        run_checked(
            [
                cls.link,
                "/nologo",
                "/DLL",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOREF",
                "/OPT:NOICF",
                f"/OUT:{directory / 'hcr_w6_patch.dll'}",
                f"/PDB:{directory / 'hcr_w6_patch.pdb'}",
                "/PDBALTPATH:%_PDB%",
                obj,
            ],
            cls.repo,
            cls.env,
        )

    def run_debugger(self, arguments: list[str], symbol_path: Path,
                     module: str) -> str:
        commands = "; ".join(
            [
                "g",
                f".reload /f {module}",
                ".echo HXW6_MODULE",
                f"lmvm {module.removesuffix('.dll').removesuffix('.exe')}",
                ".echo HXW6_RIP",
                "r rip",
                ".echo HXW6_NEAREST",
                "ln @rip",
                ".echo HXW6_SOURCE",
                "lsa @rip",
                ".echo HXW6_STACK",
                "kv",
                "q",
            ]
        )
        process = subprocess.run(
            [
                self.cdb,
                "-o",
                "-lines",
                "-y",
                str(symbol_path),
                "-srcpath",
                str(self.fixture),
                "-c",
                commands,
                str(self.target),
                *arguments,
            ],
            cwd=self.repo,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
            check=False,
        )
        if process.returncode != 0:
            raise AssertionError(
                f"CDB exited {process.returncode}\n{process.stdout}"
            )
        return process.stdout

    def test_delivery_selection_and_real_debugger_detection(self) -> None:
        matrix_output = run_checked([self.selector], self.repo, self.env)
        matrix = json.loads(matrix_output.splitlines()[-1])
        self.assertEqual(matrix["refusal"], "windows-direct-debugger-unsupported")
        rows = matrix["matrix"]
        automatic = {row["debugger"]: row for row in rows[:4]}
        self.assertEqual(automatic["none"]["delivery"], "direct")
        for debugger in ("windbg", "visual-studio", "unknown-native"):
            self.assertEqual(automatic[debugger]["delivery"], "shared-library")
        for refused in rows[4:]:
            self.assertFalse(refused["accepted"])
            self.assertEqual(
                refused["refusal_reason"],
                "windows-direct-debugger-unsupported",
            )

        outside = json.loads(
            run_checked([self.selector, "--detect"], self.repo, self.env).splitlines()[-1]
        )
        self.assertEqual(outside["debugger"], "none")
        self.assertEqual(outside["delivery"], "direct")

        attached = subprocess.run(
            [self.cdb, "-g", "-G", "-o", str(self.selector), "--detect"],
            cwd=self.repo,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
            check=False,
        )
        self.assertEqual(attached.returncode, 0, attached.stdout)
        detected_lines = [line for line in attached.stdout.splitlines()
                          if line.startswith("{") and line.endswith("}")]
        self.assertTrue(detected_lines, attached.stdout)
        detected = json.loads(detected_lines[-1])
        self.assertEqual(detected["debugger"], "unknown-native")
        self.assertEqual(detected["delivery"], "shared-library")

    def test_matching_pdb_resolves_patch_line_and_multiframe_stack(self) -> None:
        output = self.run_debugger([str(self.patch)], self.positive, "hcr_w6_patch.dll")
        self.assertIn("HXW6_MODULE", output)
        self.assertRegex(output.lower(), r"\(private pdb symbols\).*hcr_w6_patch\.pdb")
        self.assertIn("HX_W6_PATCH_SOURCE_LINE", output)
        self.assertRegex(output, r"hcr_w6_patch!hx_w6_patch_leaf")
        for caller in (
            "hcr_w6_patch!hx_w6_patch_middle",
            "hcr_w6_patch!hx_w6_patch_entry",
            "hcr_w6_target!hx_w6_target_caller_two",
            "hcr_w6_target!hx_w6_target_caller_one",
            "hcr_w6_target!wmain",
        ):
            self.assertIn(caller, output)

        module_match = re.search(
            r"(?im)^\s*([0-9a-f`]+)\s+([0-9a-f`]+)\s+hcr_w6_patch\s+",
            output,
        )
        rip_match = re.search(r"(?im)^rip=([0-9a-f`]+)", output)
        self.assertIsNotNone(module_match, output)
        self.assertIsNotNone(rip_match, output)
        start = int(module_match.group(1).replace("`", ""), 16)
        end = int(module_match.group(2).replace("`", ""), 16)
        rip = int(rip_match.group(1).replace("`", ""), 16)
        self.assertLessEqual(start, rip)
        self.assertLess(rip, end)

        (self.logs / "hx_w6_windbg_patch.log").write_text(output, encoding="utf-8")

    def test_mismatched_pdb_falsifier_has_no_patch_source_line(self) -> None:
        mismatched_dll = self.mismatch / "hcr_w6_patch.dll"
        output = self.run_debugger(
            [str(mismatched_dll)], self.mismatch, "hcr_w6_patch.dll"
        )
        lowered = output.lower()
        self.assertIn("Symbol Loading Error Summary", output)
        self.assertIn("hcr_w6_patch", lowered)
        self.assertIn("(export symbols)", lowered)
        self.assertNotIn("HX_W6_PATCH_SOURCE_LINE", output)
        self.assertNotRegex(lowered, r"\(private pdb symbols\).*hcr_w6_patch\.pdb")
        (self.logs / "hx_w6_windbg_mismatched_pdb.log").write_text(
            output, encoding="utf-8"
        )

    def test_unpatched_control_resolves_from_executable_pdb(self) -> None:
        output = self.run_debugger(["--control"], self.positive, "hcr_w6_target.exe")
        self.assertRegex(output.lower(), r"\(private pdb symbols\).*hcr_w6_target\.pdb")
        self.assertIn("HX_W6_CONTROL_SOURCE_LINE", output)
        self.assertIn("hcr_w6_target!hx_w6_unpatched_control", output)
        self.assertNotIn("hcr_w6_patch!", output)
        (self.logs / "hx_w6_windbg_control.log").write_text(output, encoding="utf-8")


if __name__ == "__main__":
    print(json.dumps({
        "gate": "hx_w6_windbg_resolves_source_lines_inside_a_patched_windows_function",
        "cdb": find_cdb(visual_studio_environment()),
        "cdb_banner": tool_banner(
            [find_cdb(visual_studio_environment()), "-version"],
            Path.cwd(),
            visual_studio_environment(),
        ),
    }, sort_keys=True))
    unittest.main(verbosity=2)
