#!/usr/bin/env python3
"""HX-W-4 real Windows x64 unwind and CFG registration gate.

``allowed_mocks: none``. MASM emits the patch object's real ``.pdata`` and
``.xdata``. The production coordinator layout code relocates those records,
and the production in-process registration header drives the OS function-table,
mitigation-policy, and CFG target APIs. Separate child processes make missing
unwind registration, missing CFG admission, an unsorted table, and missing
unregistration observable without sacrificing the positive process.

This direct Windows CI gate intentionally lacks a ``test_*.py`` prefix.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-4 unwind/CFG gate must run on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    required_tool,
    run_checked,
    visual_studio_environment,
)


class HxW4UnwindAndCfg(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = Path(__file__).resolve().parents[2]
        cls.fixture = cls.repo / "tests" / "fixtures" / "hcr" / "windows-unwind-cfg"
        cls.work = cls.repo / "build" / "hcr-w4-windows-unwind-cfg"
        cls.logs = cls.repo / "test-logs"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.logs.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = required_tool("cl.exe", cls.env)
        cls.link = required_tool("link.exe", cls.env)
        cls.ml64 = required_tool("ml64.exe", cls.env)
        cls.dumpbin = required_tool("dumpbin.exe", cls.env)
        cls.nim = required_tool("nim.exe", cls.env)

        cls.patch_object = cls.work / "hcr_w4_patch.obj"
        run_checked(
            [
                cls.ml64,
                "/nologo",
                "/c",
                f"/Fo{cls.patch_object}",
                str(cls.fixture / "hcr_w4_patch.asm"),
            ],
            cls.repo,
            cls.env,
        )
        object_dump = run_checked(
            [cls.dumpbin, "/nologo", "/headers", "/relocations", str(cls.patch_object)],
            cls.repo,
            cls.env,
        )
        for required in (".pdata", ".xdata", "ADDR32NB"):
            if required not in object_dump:
                raise AssertionError(f"real patch object lacks {required}\n{object_dump}")

        cls.target = cls.work / "hcr_w4_target.exe"
        target_object = cls.work / "hcr_w4_target.obj"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/c",
                "/O2",
                "/Zi",
                "/guard:cf",
                "/W4",
                "/WX",
                f"/Fo{target_object}",
                f"/Fd{cls.work / 'hcr_w4_target_compile.pdb'}",
                str(cls.fixture / "hcr_w4_target.c"),
            ],
            cls.repo,
            cls.env,
        )
        run_checked(
            [
                cls.link,
                "/nologo",
                f"/OUT:{cls.target}",
                f"/PDB:{cls.work / 'hcr_w4_target.pdb'}",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/GUARD:CF",
                str(target_object),
                "mincore.lib",
            ],
            cls.repo,
            cls.env,
        )
        load_config = run_checked(
            [cls.dumpbin, "/nologo", "/headers", "/loadconfig", str(cls.target)],
            cls.repo,
            cls.env,
        )
        for required in ("Guard", "CF Instrumented", "FID table present"):
            if required.casefold() not in load_config.casefold():
                raise AssertionError(
                    f"target is not mechanically CFG-enabled ({required} absent)\n"
                    f"{load_config}"
                )

        cls.layout_helper = cls.work / "hx_w4_layout.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache'}",
                f"-o:{cls.layout_helper}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_linkgraph' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_core' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_hash' / 'src'}",
                str(cls.repo / "tests" / "windows" / "hx_w4_windows_unwind_layout.nim"),
            ],
            cls.repo,
            cls.env,
        )
        cls.layout = cls.work / "hcr_w4_layout.bin"
        layout_output = run_checked(
            [str(cls.layout_helper), str(cls.patch_object), str(cls.layout)],
            cls.repo,
            cls.env,
        )
        cls.layout_evidence = cls.parse_last_json(layout_output)
        if not cls.layout_evidence["ok"]:
            raise AssertionError(layout_output)
        if cls.layout.stat().st_size != cls.layout_evidence["region_bytes"]:
            raise AssertionError("layout evidence byte count differs from its artifact")

    @staticmethod
    def parse_last_json(output: str) -> dict[str, object]:
        lines = [line for line in output.splitlines() if line.strip()]
        if not lines:
            raise AssertionError("process produced no JSON evidence")
        return json.loads(lines[-1])

    def target_command(self, mode: str) -> list[str]:
        evidence = self.layout_evidence
        entries = evidence["function_entries"]
        assert isinstance(entries, list)
        return [
            str(self.target),
            mode,
            str(self.layout),
            str(evidence["function_table_offset"]),
            str(evidence["function_table_count"]),
            str(evidence["selected_entry"]),
            *(str(value) for value in entries),
        ]

    def run_target(self, mode: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.target_command(mode),
            cwd=self.repo,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )

    def test_hx_w4_windows_unwind_and_cfg_registration(self) -> None:
        self.assertGreaterEqual(self.layout_evidence["function_table_count"], 2)
        self.assertGreaterEqual(self.layout_evidence["coff_relocations"], 6)

        positive = self.run_target("positive")
        self.assertEqual(positive.returncode, 0, positive.stdout)
        success = self.parse_last_json(positive.stdout)
        self.assertTrue(success["ok"])
        self.assertTrue(success["cfg_enabled"])
        self.assertTrue(success["patched_handler_reached"])
        self.assertTrue(success["patched_frame_observed"])
        self.assertTrue(success["control_handler_reached"])
        self.assertTrue(success["lookup_removed"])

        unsorted = self.run_target("unsorted")
        self.assertEqual(unsorted.returncode, 0, unsorted.stdout)
        unsorted_evidence = self.parse_last_json(unsorted.stdout)
        self.assertTrue(unsorted_evidence["ok"])
        self.assertEqual(unsorted_evidence["status"], 3)

        no_unwind = self.run_target("no-unwind")
        self.assertNotEqual(no_unwind.returncode, 0)
        if no_unwind.stdout.strip():
            no_unwind_evidence = self.parse_last_json(no_unwind.stdout)
            self.assertFalse(no_unwind_evidence["ok"])
            self.assertEqual(no_unwind_evidence["stage"], "unwind-registration-suppressed")
            self.assertTrue(no_unwind_evidence["lookup_was_absent"])
        else:
            no_unwind_evidence = {"ok": False, "stage": "process-fail-stop"}

        no_cfg = self.run_target("no-cfg")
        self.assertNotEqual(no_cfg.returncode, 0, "CFG-invalid entry unexpectedly ran")
        cfg_status = no_cfg.returncode & 0xFFFFFFFF
        self.assertEqual(cfg_status, 0xC0000409, no_cfg.stdout)

        stale = self.run_target("keep-unwind")
        self.assertNotEqual(stale.returncode, 0)
        stale_evidence = self.parse_last_json(stale.stdout)
        self.assertFalse(stale_evidence["ok"])
        self.assertEqual(stale_evidence["stage"], "unwind-unregistration-suppressed")
        self.assertTrue(stale_evidence["stale_entry_observed"])

        report = {
            "layout": self.layout_evidence,
            "positive": success,
            "unsorted_refusal": unsorted_evidence,
            "no_unwind_falsifier": no_unwind_evidence,
            "no_cfg_exit_status": f"0x{cfg_status:08x}",
            "stale_unwind_falsifier": stale_evidence,
        }
        (self.logs / "hx-w4-windows-unwind-cfg.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
