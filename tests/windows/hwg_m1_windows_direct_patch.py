#!/usr/bin/env python3
"""HWG-M1 canonical Windows in-process direct-patch gate.

Design: ``reprobuild-specs/HCR/Windows-Godot-Demo.md`` sections 4-5.

``allowed_mocks: none``. The gate builds a real patchable MSVC PE/full PDB, a
real relocation-free COFF patch body with compiler-owned unwind metadata, the
canonical injected DLL/launcher, and the production Windows coordinator. It
requires both the protocol's ``patchApplied`` verdict and return values emitted
by the running target before and after publication. The control removes only
``/FUNCTIONPADMIN:6`` and must be refused by bundle construction.

Required Windows CI invokes this file directly; selection on another host is a
hard failure, not a skip counted as coverage.
"""

from __future__ import annotations

import ctypes
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest


if sys.platform != "win32":
    raise SystemExit("HWG-M1 Windows direct-patch gate must run on Windows")


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "windows"))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    PeImage,
    first_instruction,
    padding_run_before,
)
sys.path.insert(0, str(REPO / "libs" / "repro_hcr_agent"))
from build_windows_agent import (  # noqa: E402
    build_artifacts,
    run_checked,
    visual_studio_environment,
)


def stop_process(pid: int, stop_file: Path) -> None:
    stop_file.touch()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = kernel32.OpenProcess(0x00100001, False, pid)
    if not handle:
        return
    try:
        if kernel32.WaitForSingleObject(handle, 5_000) != 0:
            kernel32.TerminateProcess(handle, 9)
            kernel32.WaitForSingleObject(handle, 5_000)
    finally:
        kernel32.CloseHandle(handle)


def observations(path: Path) -> list[int]:
    if not path.is_file():
        return []
    result: list[int] = []
    for line in path.read_text(encoding="ascii").splitlines():
        fields = line.split(",")
        if len(fields) == 2:
            result.append(int(fields[1]))
    return result


def wait_for_value(path: Path, value: int, timeout: float = 10.0) -> list[int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        seen = observations(path)
        if value in seen:
            return seen
        time.sleep(0.025)
    raise AssertionError(
        f"timed out waiting for target value {value}; saw {observations(path)}"
    )


def wait_for_count(path: Path, count: int, timeout: float = 10.0) -> list[int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        seen = observations(path)
        if len(seen) >= count:
            return seen
        time.sleep(0.025)
    raise AssertionError(
        f"timed out waiting for {count} observations; saw {observations(path)}"
    )


class WindowsDirectPatchGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.work = REPO / "build" / "hwg-m1-windows-direct"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = shutil.which("cl.exe", path=cls.env.get("PATH"))
        cls.nim = shutil.which("nim.exe", path=cls.env.get("PATH"))
        if cls.cl is None or cls.nim is None:
            raise AssertionError("HWG-M1 requires cl.exe and nim.exe")

        cls.artifacts = build_artifacts(cls.work / "agent")
        cls.target, cls.pdb = cls.build_target("positive", patchable=True)
        cls.no_padding, cls.no_padding_pdb = cls.build_target(
            "no-padding", patchable=False
        )
        cls.patch = cls.build_patch("changed", 70)
        cls.noop_patch = cls.build_patch("noop", 11)
        cls.driver = cls.work / "hcr_patch_driver_windows.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache-driver'}",
                f"--out:{cls.driver}",
                f"-p:{REPO / 'libs' / 'repro_hcr_agent' / 'src'}",
                f"-p:{REPO / 'libs' / 'repro_hcr_linker' / 'src'}",
                f"-p:{REPO / 'libs' / 'repro_hcr_linkgraph' / 'src'}",
                f"-p:{REPO / 'libs' / 'repro_core' / 'src'}",
                f"-p:{REPO / 'libs' / 'repro_hash' / 'src'}",
                str(REPO / "scripts" / "hcr_patch_driver_windows.nim"),
            ],
            REPO,
            cls.env,
        )
        image = PeImage(cls.target)
        cls.target_rva = image.exported_rva("hwg_m1_victim")
        cls.padding, cls.padding_kind = padding_run_before(
            image, cls.target_rva
        )
        offset = image.rva_offset(cls.target_rva)
        cls.instruction_length, _ = first_instruction(
            image.data[offset : offset + 32]
        )

    @classmethod
    def build_target(cls, tag: str, patchable: bool) -> tuple[Path, Path]:
        image = cls.work / f"{tag}.exe"
        pdb = cls.work / f"{tag}.pdb"
        link_flags = [
            "/DEBUG:FULL",
            "/INCREMENTAL:NO",
            "/OPT:NOICF",
            "/OPT:NOREF",
            "/EXPORT:hwg_m1_victim",
        ]
        if patchable:
            link_flags.insert(1, "/FUNCTIONPADMIN:6")
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/O2",
                "/GS-",
                "/Gy-",
                "/Zi",
                "/GL-",
                str(
                    REPO
                    / "tests"
                    / "fixtures"
                    / "hcr"
                    / "windows-direct"
                    / "hwg_m1_target.c"
                ),
                f"/Fe:{image}",
                "/link",
                *link_flags,
                f"/PDB:{pdb}",
            ],
            REPO,
            cls.env,
        )
        return image, pdb

    @classmethod
    def build_patch(cls, tag: str, bias: int) -> Path:
        patch = cls.work / f"hwg_m1_patch_{tag}.obj"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/c",
                "/O2",
                "/GS-",
                "/Gy-",
                "/Zi",
                "/GL-",
                f"/DHWG_M1_BIAS={bias}",
                str(
                    REPO
                    / "tests"
                    / "fixtures"
                    / "hcr"
                    / "windows-direct"
                    / "hwg_m1_patch.c"
                ),
                f"/Fo:{patch}",
                f"/Fd:{cls.work / ('hwg_m1_patch_' + tag + '.pdb')}",
            ],
            REPO,
            cls.env,
        )
        return patch

    def driver_command(
        self,
        pid: int,
        image: Path,
        pdb: Path,
        report: Path,
        patch: Path | None = None,
    ) -> list[str]:
        return [
            str(self.driver),
            "--pid",
            str(pid),
            "--target-image",
            str(image),
            "--target-pdb",
            str(pdb),
            "--target-symbol",
            "hwg_m1_victim",
            "--patch-object",
            str(self.patch if patch is None else patch),
            "--patch-symbol",
            "hwg_m1_replacement",
            "--first-instruction-length",
            str(self.instruction_length),
            "--json-out",
            str(report),
        ]

    def test_real_target_changes_only_after_canonical_agent_applies(self) -> None:
        observed = self.work / "positive-observations.csv"
        stop = self.work / "positive.stop"
        report = self.work / "positive-driver.json"
        for path in (observed, stop, report):
            path.unlink(missing_ok=True)
        launcher_log = self.work / "positive-launcher.txt"
        with launcher_log.open("w+", encoding="utf-8") as output:
            launched = subprocess.run(
                [
                    str(self.artifacts["launcher"]),
                    "--agent",
                    str(self.artifacts["agent"]),
                    "--",
                    str(self.target),
                    str(observed),
                    str(stop),
                ],
                cwd=REPO,
                env=self.env,
                text=True,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=20,
                check=False,
            )
            output.seek(0)
            launcher_output = output.read()
        self.assertEqual(launched.returncode, 0, launcher_output)
        launcher_evidence = json.loads(launcher_output.splitlines()[-1])
        pid = int(launcher_evidence["pid"])
        try:
            before = wait_for_value(observed, 18)
            self.assertGreaterEqual(before.count(18), 1)
            applied = subprocess.run(
                self.driver_command(pid, self.target, self.pdb, report),
                cwd=REPO,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
            self.assertEqual(applied.returncode, 0, applied.stdout)
            after = wait_for_value(observed, 77)
            evidence = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(evidence["outcome"], "applied")
            self.assertIn("direct-patch-injection", evidence["agentCapabilities"])
            self.assertEqual(
                evidence["lifecycleEvents"],
                ["hcr/patchApplying", "hcr/patchApplied"],
            )
            self.assertGreaterEqual(after.count(18), 1)
            self.assertGreaterEqual(after.count(77), 1)
            first_new = after.index(77)
            self.assertNotIn(18, after[first_new:])
            self.assertEqual(self.padding_kind, "0xcc")
            self.assertGreaterEqual(self.padding, 6)
            self.assertGreaterEqual(self.instruction_length, 2)
            self.assertEqual(
                evidence["windowsEvidence"]["publicationTier"], 2
            )
            self.assertGreaterEqual(
                evidence["windowsEvidence"]["suspendedThreads"], 1
            )
            self.assertGreaterEqual(
                evidence["windowsEvidence"]["capturedContexts"], 1
            )
            self.assertTrue(
                evidence["windowsEvidence"]["quiescenceHeldAtStore"]
            )
            self.assertTrue(
                evidence["windowsEvidence"]["cacheFlushSucceeded"]
            )
            self.assertEqual(
                evidence["windowsEvidence"]["firstInstructionLength"],
                self.instruction_length,
            )
            self.assertNotEqual(
                evidence["patchApplied"]["entryAddress"],
                evidence["patchApplied"]["dispatchAddress"],
            )
        finally:
            stop_process(pid, stop)

    def test_noop_control_applies_but_does_not_fake_behavior_change(self) -> None:
        observed = self.work / "noop-observations.csv"
        stop = self.work / "noop.stop"
        report = self.work / "noop-driver.json"
        for path in (observed, stop, report):
            path.unlink(missing_ok=True)
        launcher_log = self.work / "noop-launcher.txt"
        with launcher_log.open("w+", encoding="utf-8") as output:
            launched = subprocess.run(
                [
                    str(self.artifacts["launcher"]),
                    "--agent",
                    str(self.artifacts["agent"]),
                    "--",
                    str(self.target),
                    str(observed),
                    str(stop),
                ],
                cwd=REPO,
                env=self.env,
                text=True,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=20,
                check=False,
            )
            output.seek(0)
            launcher_output = output.read()
        self.assertEqual(launched.returncode, 0, launcher_output)
        pid = int(json.loads(launcher_output.splitlines()[-1])["pid"])
        try:
            before = wait_for_count(observed, 3)
            self.assertEqual(set(before), {18})
            applied = subprocess.run(
                self.driver_command(
                    pid, self.target, self.pdb, report, self.noop_patch
                ),
                cwd=REPO,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
            self.assertEqual(applied.returncode, 0, applied.stdout)
            after = wait_for_count(observed, len(before) + 10)
            evidence = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(evidence["outcome"], "applied")
            self.assertEqual(set(after), {18})
            self.assertNotIn(77, after)
        finally:
            stop_process(pid, stop)

    def test_missing_function_padding_is_a_named_prepublication_refusal(self) -> None:
        report = self.work / "no-padding-driver.json"
        report.unlink(missing_ok=True)
        refused = subprocess.run(
            self.driver_command(1, self.no_padding, self.no_padding_pdb, report),
            cwd=REPO,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        self.assertEqual(refused.returncode, 1, refused.stdout)
        self.assertIn("no-patchable-entry", refused.stdout)
        self.assertFalse(report.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
