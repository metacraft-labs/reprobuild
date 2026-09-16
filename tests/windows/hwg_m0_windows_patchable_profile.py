#!/usr/bin/env python3
"""HWG-M0 production Windows patchable-profile integration gate.

Design: ``reprobuild-specs/HCR/Windows-Godot-Demo.md`` section 3.

``allowed_mocks: none``. The gate compiles and runs the production Nim profile
emitter, passes its exact argv tokens to real MSVC/LINK, inspects the linked PE
and matching full PDB, and resolves two real private functions through the
production DbgHelp-backed reader. The negative arm rebuilds without only
``/FUNCTIONPADMIN:6`` and must lose the declared entry geometry.

Required Windows CI invokes this file directly. Selecting it elsewhere is a
hard failure rather than a skip counted as coverage.
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HWG-M0 Windows profile gate must run on Windows")


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "windows"))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    PeImage,
    first_instruction,
    padding_run_before,
    pdb_identity,
)
sys.path.insert(0, str(REPO / "libs" / "repro_hcr_agent"))
from build_windows_agent import run_checked, visual_studio_environment  # noqa: E402


class WindowsPatchableProfileGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.work = REPO / "build" / "hwg-m0-windows-profile"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.nim = shutil.which("nim.exe", path=cls.env.get("PATH"))
        cls.cl = shutil.which("cl.exe", path=cls.env.get("PATH"))
        cls.link = shutil.which("link.exe", path=cls.env.get("PATH"))
        for name, path in (("nim.exe", cls.nim), ("cl.exe", cls.cl),
                           ("link.exe", cls.link)):
            if path is None:
                raise AssertionError(f"required HWG-M0 tool is missing: {name}")

        cls.emitter = cls.work / "hcr_patchable_profile.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache-emitter'}",
                f"--out:{cls.emitter}",
                str(REPO / "scripts" / "hcr_patchable_profile.nim"),
            ],
            REPO,
            cls.env,
        )
        emitted = run_checked(
            [str(cls.emitter), "--format=json"], REPO, cls.env
        )
        cls.profile = json.loads(emitted)

        cls.target = REPO / "tests" / "fixtures" / "hcr" / \
            "windows-profile" / "hwg_m0_target.c"
        cls.image, cls.pdb = cls.build("positive", cls.profile["linkFlags"])

        cls.probe = cls.work / "hwg_m0_windows_profile_probe.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache-probe'}",
                f"--out:{cls.probe}",
                f"-p:{REPO / 'libs' / 'repro_hcr_linkgraph' / 'src'}",
                f"-p:{REPO / 'libs' / 'repro_core' / 'src'}",
                str(REPO / "tests" / "windows" /
                    "hwg_m0_windows_profile_probe.nim"),
            ],
            REPO,
            cls.env,
        )

    @classmethod
    def build(cls, tag: str, link_flags: list[str]) -> tuple[Path, Path]:
        obj = cls.work / f"{tag}.obj"
        image = cls.work / f"{tag}.exe"
        pdb = cls.work / f"{tag}.pdb"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/c",
                "/O2",
                "/GS-",
                "/Gy-",
                *cls.profile["compileFlags"],
                str(cls.target),
                f"/Fo:{obj}",
                f"/Fd:{cls.work / (tag + '-compile.pdb')}",
            ],
            REPO,
            cls.env,
        )
        run_checked(
            [
                cls.link,
                "/NOLOGO",
                "/NODEFAULTLIB",
                "/ENTRY:main",
                "/SUBSYSTEM:CONSOLE",
                "/OPT:NOREF",
                "/EXPORT:victim",
                *link_flags,
                f"/OUT:{image}",
                f"/PDB:{pdb}",
                str(obj),
            ],
            REPO,
            cls.env,
        )
        if not image.is_file() or image.stat().st_size == 0:
            raise AssertionError(f"{tag} produced no non-empty PE")
        if not pdb.is_file() or pdb.stat().st_size == 0:
            raise AssertionError(f"{tag} produced no non-empty full PDB")
        return image, pdb

    def test_profile_tokens_are_the_adopted_windows_v1_set(self) -> None:
        self.assertEqual(
            self.profile["supportProfile"],
            "windows-x86_64-msvc-pe-direct-hcr-v1",
        )
        self.assertEqual(self.profile["compileFlags"], ["/Zi", "/GL-"])
        self.assertEqual(
            self.profile["linkFlags"],
            ["/DEBUG:FULL", "/FUNCTIONPADMIN:6", "/INCREMENTAL:NO", "/OPT:NOICF"],
        )

    def test_emitted_profile_builds_declared_pe_pdb_shape(self) -> None:
        image = PeImage(self.image)
        entry_rva = image.exported_rva("victim")
        padding, kind = padding_run_before(image, entry_rva)
        offset = image.rva_offset(entry_rva)
        instruction_length, _ = first_instruction(image.data[offset:offset + 32])
        pe_guid, pe_age, _ = image.codeview_identity()
        pdb_guid, pdb_age = pdb_identity(self.pdb)
        self.assertGreaterEqual(padding, 6)
        self.assertEqual(kind, "0xcc")
        self.assertGreaterEqual(instruction_length, 2)
        self.assertEqual((pe_guid, pe_age), (pdb_guid, pdb_age))
        resolved = json.loads(run_checked(
            [str(self.probe), str(self.image), str(self.pdb)], REPO, self.env
        ))
        self.assertTrue(resolved["ok"])
        self.assertEqual(resolved["privateFunctionCount"], 2)
        self.assertNotEqual(resolved["victimRva"], resolved["secondPrivateRva"])

    def test_without_function_padding_the_linked_image_falsifies_profile(self) -> None:
        flags = [
            flag for flag in self.profile["linkFlags"]
            if flag.upper() != "/FUNCTIONPADMIN:6"
        ]
        self.assertEqual(len(flags) + 1, len(self.profile["linkFlags"]))
        image_path, _ = self.build("no-function-padding", flags)
        image = PeImage(image_path)
        entry_rva = image.exported_rva("victim")
        padding, _ = padding_run_before(image, entry_rva)
        self.assertLess(padding, 6)


if __name__ == "__main__":
    unittest.main(verbosity=2)
