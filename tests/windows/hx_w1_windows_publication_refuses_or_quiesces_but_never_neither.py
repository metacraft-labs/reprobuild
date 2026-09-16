#!/usr/bin/env python3
"""HX-W-1 real Windows provider-publication serialization gate.

``allowed_mocks: none``. Both arms use the production Windows publisher and
W2 quiescence component against a real MSVC ``/FUNCTIONPADMIN:6`` image with
eight hot worker threads. The falsifier input reports quiescence unavailable;
the provider must refuse before changing any live byte. The control enables
that one capability and must publish under observed quiescence and flush.

Required Windows CI invokes this file directly. It intentionally has no
``test_*.py`` prefix, so another platform cannot skip it and report success.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-1 publication gate must run on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    PeImage,
    first_instruction,
    padding_run_before,
    required_tool,
    run_checked,
    tool_banner,
    visual_studio_environment,
)


class HxW1WindowsPublication(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = Path(__file__).resolve().parents[2]
        cls.fixture = (
            cls.repo
            / "tests"
            / "fixtures"
            / "hcr"
            / "windows-publication"
            / "hcr_w1_target.c"
        )
        cls.work = cls.repo / "build" / "hcr-w1-windows-publication"
        cls.logs = cls.repo / "test-logs"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.logs.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = required_tool("cl.exe", cls.env)
        cls.target = cls.work / "hcr_w1_target.exe"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/W4",
                "/WX",
                "/O2",
                "/GS-",
                "/Gy-",
                "/GL-",
                "/Zi",
                f"/Fo{cls.work / 'hcr_w1_target.obj'}",
                f"/Fd{cls.work / 'hcr_w1_compile.pdb'}",
                f"/I{cls.repo / 'libs' / 'repro_hcr_agent' / 'c'}",
                str(cls.fixture),
                f"/Fe{cls.target}",
                "/link",
                "/DEBUG:FULL",
                f"/PDB:{cls.work / 'hcr_w1_target.pdb'}",
                "/INCREMENTAL:NO",
                "/OPT:NOICF",
                "/FUNCTIONPADMIN:6",
                "/SECTION:.hcrv,ER",
            ],
            cls.repo,
            cls.env,
        )
        image = PeImage(cls.target)
        cls.entry_rva = image.exported_rva("hx_w1_victim")
        entry_offset = image.rva_offset(cls.entry_rva)
        cls.instruction_length, cls.instruction = first_instruction(
            image.data[entry_offset : entry_offset + 16]
        )
        padding_count, padding_kind = padding_run_before(image, cls.entry_rva)
        if padding_count < 6 or padding_kind != "0xcc":
            raise AssertionError(
                f"linked fixture lacks adopted padding: {padding_count} {padding_kind}"
            )
        cls.padding_hex = image.data[entry_offset - 6 : entry_offset].hex()
        cls.instruction_hex = image.data[
            entry_offset : entry_offset + cls.instruction_length
        ].hex()

    def run_arm(self, mode: str) -> dict[str, object]:
        output = run_checked(
            [
                self.target,
                mode,
                str(self.instruction_length),
                self.padding_hex,
                self.instruction_hex,
            ],
            self.repo,
            self.env,
        )
        lines = [line for line in output.splitlines() if line.startswith("{")]
        self.assertTrue(lines, output)
        return json.loads(lines[-1])

    def test_publication_refuses_or_quiesces_but_never_neither(self) -> None:
        refused = self.run_arm("no-quiescence")
        self.assertEqual(refused["statusName"], "quiescence-required")
        self.assertFalse(refused["quiescenceAvailable"])
        self.assertFalse(refused["quiescenceHeldAtStore"])
        self.assertFalse(refused["published"])
        self.assertFalse(refused["bytesChanged"])
        self.assertEqual(refused["workers"], 8)
        self.assertGreater(int(refused["callsBefore"]), 1000)
        self.assertGreater(int(refused["originalValues"]), 1000)
        self.assertEqual(int(refused["patchedValues"]), 0)

        accepted = self.run_arm("positive")
        self.assertEqual(accepted["statusName"], "ok")
        self.assertTrue(accepted["quiescenceAvailable"])
        self.assertTrue(accepted["quiescenceHeldAtStore"])
        self.assertTrue(accepted["cacheFlushSucceeded"])
        self.assertTrue(accepted["published"])
        self.assertTrue(accepted["bytesChanged"])
        self.assertGreaterEqual(int(accepted["suspendedThreads"]), 8)
        self.assertGreaterEqual(int(accepted["capturedContexts"]), 8)
        self.assertGreater(int(accepted["callsBefore"]), 1000)
        self.assertGreater(int(accepted["patchedValues"]), 1000)

        evidence = {
            "schemaId": "reprobuild.hcr.hx-w1.windows-publication.v1",
            "profile": "windows-x86_64-msvc-pe-direct-hcr-v1",
            "tool": tool_banner([self.cl], self.repo, self.env),
            "linkedGeometry": {
                "entryRva": f"0x{self.entry_rva:x}",
                "firstInstruction": self.instruction,
                "firstInstructionLength": self.instruction_length,
                "paddingHex": self.padding_hex,
            },
            "refusal": refused,
            "control": accepted,
        }
        (self.logs / "hx_w1_windows_publication.json").write_text(
            json.dumps(evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
