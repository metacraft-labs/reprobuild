#!/usr/bin/env python3
"""HX-W-3 real COFF, PE/PDB, and loaded-module symbol-resolution gate.

``allowed_mocks: none``. The gate builds two real MSVC COFF object revisions,
a real PE executable, a real DLL, and two full PDBs. It drives the production
Nim LinkGraph/PE/PDB implementation and the production C runtime module
resolver. The duplicate-name, absent-name, mismatched-identity, mutated loaded
identity, and out-of-range-RVA arms are real refusal paths, not substitutes for
DbgHelp, ToolHelp, the loader, or the compiler.

This file intentionally lacks the ``test_*.py`` prefix. Required Windows CI
invokes it directly; a cross-platform suite must not skip it and report green.
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-3 symbol-resolution gate must run on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    required_tool,
    run_checked,
    visual_studio_environment,
)


class HxW3SymbolResolution(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = Path(__file__).resolve().parents[2]
        cls.fixture = (
            cls.repo / "tests" / "fixtures" / "hcr" / "windows-symbol-resolution"
        )
        cls.work = cls.repo / "build" / "hcr-w3-windows-symbol-resolution"
        cls.logs = cls.repo / "test-logs"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.logs.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = required_tool("cl.exe", cls.env)
        cls.link = required_tool("link.exe", cls.env)
        cls.nim = required_tool("nim.exe", cls.env)

        cls.dll = cls.work / "hcr_w3_fixture.dll"
        cls.dll_pdb = cls.work / "hcr_w3_fixture.pdb"
        dll_obj = cls.work / "hcr_w3_dll.obj"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/c",
                "/Od",
                "/Zi",
                "/Gy-",
                "/W4",
                "/WX",
                f"/Fo{dll_obj}",
                f"/Fd{cls.work / 'hcr_w3_dll_compile.pdb'}",
                str(cls.fixture / "hcr_w3_dll.c"),
            ],
            cls.repo,
            cls.env,
        )
        run_checked(
            [
                cls.link,
                "/nologo",
                "/DLL",
                f"/OUT:{cls.dll}",
                f"/PDB:{cls.dll_pdb}",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOREF",
                "/FUNCTIONPADMIN:6",
                str(dll_obj),
            ],
            cls.repo,
            cls.env,
        )

        cls.target = cls.work / "hcr_w3_target.exe"
        cls.target_pdb = cls.work / "hcr_w3_target.pdb"
        target_objects: list[Path] = []
        for stem in ("hcr_w3_target", "hcr_w3_ambiguous_a", "hcr_w3_ambiguous_b"):
            object_path = cls.work / f"{stem}.obj"
            target_objects.append(object_path)
            run_checked(
                [
                    cls.cl,
                    "/nologo",
                    "/c",
                    "/Od",
                    "/Zi",
                    "/Gy-",
                    "/W4",
                    "/WX",
                    f"/Fo{object_path}",
                    f"/Fd{cls.work / f'{stem}_compile.pdb'}",
                    str(cls.fixture / f"{stem}.c"),
                ],
                cls.repo,
                cls.env,
            )
        run_checked(
            [
                cls.link,
                "/nologo",
                f"/OUT:{cls.target}",
                f"/PDB:{cls.target_pdb}",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOREF",
                "/FUNCTIONPADMIN:6",
                *(str(path) for path in target_objects),
            ],
            cls.repo,
            cls.env,
        )

        cls.no_codeview = cls.work / "hcr_w3_no_codeview.exe"
        no_codeview_obj = cls.work / "hcr_w3_no_codeview.obj"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/c",
                "/O2",
                "/W4",
                "/WX",
                f"/Fo{no_codeview_obj}",
                str(cls.fixture / "hcr_w3_no_codeview.c"),
            ],
            cls.repo,
            cls.env,
        )
        run_checked(
            [
                cls.link,
                "/nologo",
                f"/OUT:{cls.no_codeview}",
                "/INCREMENTAL:NO",
                str(no_codeview_obj),
            ],
            cls.repo,
            cls.env,
        )

        coff_source = cls.fixture / "hcr_w3_coff.c"
        cls.old_object = cls.work / "hcr_w3_coff_old.obj"
        cls.new_object = cls.work / "hcr_w3_coff_new.obj"
        for delta, object_path in ((0, cls.old_object), (1, cls.new_object)):
            run_checked(
                [
                    cls.cl,
                    "/nologo",
                    "/c",
                    "/O2",
                    "/Zi",
                    "/Gy-",
                    "/W4",
                    "/WX",
                    f"/DHX_W3_DELTA={delta}",
                    f"/Fo{object_path}",
                    f"/Fd{cls.work / f'hcr_w3_coff_{delta}_compile.pdb'}",
                    str(coff_source),
                ],
                cls.repo,
                cls.env,
            )

        cls.gate = cls.work / "hx_w3_gate.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache'}",
                f"-o:{cls.gate}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_linkgraph' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_core' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_hash' / 'src'}",
                str(
                    cls.repo
                    / "tests"
                    / "windows"
                    / "hx_w3_windows_coff_pe_pdb_symbol_resolution.nim"
                ),
            ],
            cls.repo,
            cls.env,
        )
        for artifact in (
            cls.dll,
            cls.dll_pdb,
            cls.target,
            cls.target_pdb,
            cls.old_object,
            cls.new_object,
            cls.gate,
            cls.no_codeview,
        ):
            if not artifact.is_file():
                raise AssertionError(f"HX-W-3 artifact was not produced: {artifact}")

    @staticmethod
    def parse_last_json(output: str) -> dict[str, object]:
        lines = [line for line in output.splitlines() if line.strip()]
        if not lines:
            raise AssertionError("process produced no JSON evidence")
        return json.loads(lines[-1])

    def run_target(self, evidence: dict[str, object], mutate: int) -> subprocess.CompletedProcess[str]:
        exe_identity = evidence["exe_identity"]
        dll_identity = evidence["dll_identity"]
        assert isinstance(exe_identity, dict) and isinstance(dll_identity, dict)
        return subprocess.run(
            [
                str(self.target),
                str(exe_identity["guid"]),
                str(exe_identity["age"]),
                str(evidence["exe_rva"]),
                str(dll_identity["guid"]),
                str(dll_identity["age"]),
                str(evidence["dll_rva"]),
                str(mutate),
            ],
            cwd=self.work,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )

    def test_hx_w3_windows_symbol_resolution_and_coff_relocations(self) -> None:
        gate_output = run_checked(
            [
                str(self.gate),
                str(self.target),
                str(self.target_pdb),
                str(self.dll),
                str(self.dll_pdb),
                str(self.old_object),
                str(self.new_object),
                str(self.no_codeview),
            ],
            self.repo,
            self.env,
        )
        evidence = self.parse_last_json(gate_output)
        self.assertTrue(evidence["ok"])
        coff = evidence["coff"]
        self.assertIsInstance(coff, dict)
        assert isinstance(coff, dict)
        self.assertGreaterEqual(coff["relocations"], 4)
        self.assertEqual(coff["relocations"], coff["implicit_addends"])
        self.assertGreaterEqual(coff["rel32_variants"], 1)
        self.assertIn("hx_w3_rel32_4", coff["changed_functions"])

        positive = self.run_target(evidence, mutate=0)
        self.assertEqual(positive.returncode, 0, positive.stdout)
        live = self.parse_last_json(positive.stdout)
        self.assertTrue(live["ok"])
        self.assertNotEqual(live["exe_base"], live["dll_base"])
        self.assertNotEqual(live["exe_address"], live["dll_address"])

        mutated = self.run_target(evidence, mutate=1)
        self.assertEqual(mutated.returncode, 0, mutated.stdout)
        refusal = self.parse_last_json(mutated.stdout)
        self.assertFalse(refusal["ok"])
        self.assertEqual(refusal["stage"], "retain-dll")
        self.assertEqual(refusal["status"], 7)  # module identity absent

        duplicate_dll = self.work / "hcr_w3_fixture_copy.dll"
        shutil.copyfile(self.dll, duplicate_dll)
        duplicate = self.run_target(evidence, mutate=2)
        self.assertEqual(duplicate.returncode, 0, duplicate.stdout)
        duplicate_refusal = self.parse_last_json(duplicate.stdout)
        self.assertFalse(duplicate_refusal["ok"])
        self.assertEqual(duplicate_refusal["stage"], "retain-dll")
        self.assertEqual(duplicate_refusal["status"], 8)  # identity ambiguous

        exe_identity = evidence["exe_identity"]
        dll_identity = evidence["dll_identity"]
        assert isinstance(exe_identity, dict) and isinstance(dll_identity, dict)
        out_of_range = subprocess.run(
            [
                str(self.target),
                str(exe_identity["guid"]),
                str(exe_identity["age"]),
                "ffffffffffffffff",
                str(dll_identity["guid"]),
                str(dll_identity["age"]),
                str(evidence["dll_rva"]),
                "0",
            ],
            cwd=self.work,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        self.assertNotEqual(out_of_range.returncode, 0)
        range_refusal = self.parse_last_json(out_of_range.stdout)
        self.assertEqual(range_refusal["stage"], "resolve-exe")
        self.assertEqual(range_refusal["status"], 11)

        report = {
            "gate": evidence,
            "live": live,
            "mutated_identity_refusal": refusal,
            "duplicate_identity_refusal": duplicate_refusal,
            "out_of_range_refusal": range_refusal,
        }
        (self.logs / "hx-w3-windows-symbol-resolution.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
