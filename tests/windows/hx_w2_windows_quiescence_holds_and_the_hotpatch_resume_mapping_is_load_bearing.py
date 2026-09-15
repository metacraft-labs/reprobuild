#!/usr/bin/env python3
"""HX-W-2 real Windows quiescence and hotpatch resume-map gate.

``allowed_mocks: none``. The test builds and runs the real production
``repro_hcr_windows_quiesce.h`` component in a process with real hot workers.
It exercises Tool Help snapshots, Win32 thread suspension/context APIs, a real
``/FUNCTIONPADMIN`` entry, page-protection changes, instruction-cache flushes,
and rollback. A compile-time scheduling hook creates one real thread after the
first snapshot; it does not replace or fake any Windows API.

The file is invoked directly by required Windows CI. It intentionally lacks a
``test_*.py`` prefix so the cross-platform Python inventory cannot report a
non-Windows skip as a passing HX-W-2 gate.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-2 quiescence gate must run on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    required_tool,
    run_checked,
    tool_banner,
    visual_studio_environment,
)


class HxW2Quiescence(unittest.TestCase):
    control_processes = 4
    control_iterations = 4
    falsifier_processes = 8
    falsifier_iterations = 4

    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = Path(__file__).resolve().parents[2]
        cls.fixture = (
            cls.repo
            / "tests"
            / "fixtures"
            / "hcr"
            / "windows-quiescence"
            / "hcr_w2_target.c"
        )
        cls.work = cls.repo / "build" / "hcr-w2-windows-quiescence"
        cls.logs = cls.repo / "test-logs"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.logs.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = required_tool("cl.exe", cls.env)
        cls.target = cls.work / "hcr_w2_target.exe"
        cls.pdb = cls.work / "hcr_w2_target.pdb"
        output = run_checked(
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
                f"/Fo{cls.work / 'hcr_w2_target.obj'}",
                f"/Fd{cls.work / 'hcr_w2_compile.pdb'}",
                f"/I{cls.repo / 'libs' / 'repro_hcr_agent' / 'c'}",
                str(cls.fixture),
                f"/Fe{cls.target}",
                "/link",
                "/DEBUG:FULL",
                f"/PDB:{cls.pdb}",
                "/INCREMENTAL:NO",
                "/OPT:NOICF",
                "/FUNCTIONPADMIN:6",
                "/SECTION:.hcrv,ER",
            ],
            cls.repo,
            cls.env,
        )
        if not cls.target.is_file() or not cls.pdb.is_file():
            raise AssertionError(
                f"HX-W-2 target did not link\n{output}"
            )

    def run_target(
        self, mode: str, iterations: int, index: int, timeout: int = 90
    ) -> tuple[subprocess.CompletedProcess[str], Path, dict[str, object] | None]:
        fault_path = self.work / f"fault-{mode}-{index}.json"
        if fault_path.exists():
            fault_path.unlink()
        process = subprocess.run(
            [str(self.target), mode, str(iterations), str(fault_path)],
            cwd=self.repo,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        parsed = None
        lines = [line for line in process.stdout.splitlines() if line.strip()]
        if lines and lines[-1].lstrip().startswith("{"):
            parsed = json.loads(lines[-1])
        return process, fault_path, parsed

    def test_hx_w2_windows_quiescence_holds_and_the_hotpatch_resume_mapping_is_load_bearing(
        self,
    ) -> None:
        # The stability falsifier: one snapshot misses the real thread created
        # by the gate hook immediately after snapshot one.
        single_process, _, single = self.run_target("single-snapshot", 1, 0)
        self.assertEqual(single_process.returncode, 0, single_process.stdout)
        self.assertIsNotNone(single)
        assert single is not None
        self.assertEqual(single["schemaId"], "reprobuild.hcr.hx-w2.target.v1")
        self.assertEqual(single["mode"], "single-snapshot")
        self.assertGreater(int(single["lateTid"]), 0)
        self.assertFalse(bool(single["lateThreadHeld"]))
        self.assertEqual(int(single["enumerationRounds"]), 1)
        self.assertGreaterEqual(int(single["knownWorkers"]), 9)
        self.assertLess(int(single["contexts"]), int(single["knownWorkers"]))

        controls: list[dict[str, object]] = []
        for index in range(self.control_processes):
            process, fault_path, result = self.run_target(
                "control", self.control_iterations, index
            )
            self.assertEqual(process.returncode, 0, process.stdout)
            self.assertFalse(fault_path.exists(), f"control faulted: {fault_path}")
            self.assertIsNotNone(result, process.stdout)
            assert result is not None
            self.assertEqual(result["status"], 0)
            self.assertEqual(result["publications"], self.control_iterations)
            self.assertEqual(result["rollbacks"], self.control_iterations)
            self.assertEqual(
                result["protectionRoundTrips"], self.control_iterations * 2
            )
            self.assertEqual(result["cacheFlushes"], self.control_iterations * 2)
            self.assertTrue(result["pageIsolated"])
            self.assertTrue(result["lateThreadHeld"])
            self.assertGreaterEqual(int(result["knownWorkers"]), 9)
            self.assertEqual(result["startedWorkers"], result["knownWorkers"])
            self.assertGreater(int(result["calls"]), self.control_iterations)
            self.assertEqual(int(result["badValues"]), 0)
            self.assertGreaterEqual(
                int(result["enumerationRounds"]), self.control_iterations * 4
            )
            self.assertGreaterEqual(
                int(result["contexts"]),
                int(result["knownWorkers"]) * self.control_iterations * 2,
            )
            self.assertEqual(
                result["adjustments"], result["adjustmentOpportunities"]
            )
            controls.append(result)

        total_control_opportunities = sum(
            int(result["adjustmentOpportunities"]) for result in controls
        )
        self.assertGreater(
            total_control_opportunities,
            0,
            "control never suspended a worker at entry-5; resume map was vacuous",
        )

        # Remove only SetThreadContext at the observed entry-5 mapping. The
        # next rollback restores CC padding and at least one worker resumes
        # there. The vectored handler records the real exception address.
        falsifier_faults: list[dict[str, object]] = []
        falsifier_completed: list[dict[str, object]] = []
        for index in range(self.falsifier_processes):
            process, fault_path, result = self.run_target(
                "no-adjust", self.falsifier_iterations, index
            )
            if fault_path.exists():
                fault = json.loads(fault_path.read_text(encoding="utf-8"))
                address = int(str(fault["faultAddress"]), 16)
                padding = int(str(fault["paddingStart"]), 16)
                entry = int(str(fault["entry"]), 16)
                self.assertGreaterEqual(address, padding)
                self.assertLess(address, entry)
                self.assertNotEqual(process.returncode, 0)
                falsifier_faults.append(fault)
            else:
                self.assertEqual(process.returncode, 0, process.stdout)
                self.assertIsNotNone(result, process.stdout)
                assert result is not None
                self.assertEqual(result["adjustments"], 0)
                falsifier_completed.append(result)

        self.assertEqual(len(controls), self.control_processes)
        self.assertGreaterEqual(len(falsifier_faults), 1)
        self.assertLessEqual(len(falsifier_faults), self.falsifier_processes)
        self.assertGreater(len(falsifier_faults), 0)  # control fault count is zero

        evidence = {
            "schemaId": "reprobuild.hcr.hx-w2.windows-quiescence.v1",
            "tool": tool_banner([self.cl], self.repo, self.env),
            "matrix": {
                "controlProcesses": self.control_processes,
                "publicationsAndRollbacksPerControl": self.control_iterations,
                "controlFaults": 0,
                "controlAdjustmentOpportunities": total_control_opportunities,
                "falsifierProcesses": self.falsifier_processes,
                "publicationsAndRollbacksPerFalsifier": self.falsifier_iterations,
                "falsifierFaultRange": [1, self.falsifier_processes],
                "falsifierFaultsObserved": len(falsifier_faults),
                "falsifierCompleted": len(falsifier_completed),
            },
            "singleSnapshotFalsifier": single,
            "controls": controls,
            "falsifierFaults": falsifier_faults,
            "falsifierCompletedRuns": falsifier_completed,
        }
        evidence_path = (
            self.logs
            / "hx_w2_windows_quiescence_holds_and_the_hotpatch_resume_mapping_is_load_bearing.json"
        )
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main(verbosity=2)
