#!/usr/bin/env python3
"""HX-W-5 real Windows DLL injection and named-pipe handshake gate.

Design: ``reprobuild-specs/HCR/HCR-Overview.md`` sections 5.1-5.2.
Milestone: ``HCR-Per-Platform-Handoff.milestones.org`` HX-W-5.

``allowed_mocks: none``. The gate builds the canonical production DLL and
launcher with MSVC, launches a real target suspended, performs both remote
threads, connects through the production Nim named-pipe transport, and drives
the production coordinator/session state machine. The target reads its own
Tool Help module list. The control is a real target without injection; the
falsifier is a real DLL compiled with the macOS profile.

The filename intentionally does not start with ``test_``. Required Windows CI
invokes this Windows-only gate directly instead of treating another host as a
skip-as-pass.
"""

from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-5 injection and transport gate must run on Windows")


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "libs" / "repro_hcr_agent"))
from build_windows_agent import (  # noqa: E402
    build_artifacts,
    run_checked,
    visual_studio_environment,
)


WINDOWS_PROFILE = "windows-x86_64-msvc-pe-direct-hcr-v1"
MACOS_PROFILE = "macos-arm64-direct-hcr-in-codetracer-v1"
LIFECYCLE_EXPORTS = {
    "repro_hcr_agent_start_from_env",
    "repro_hcr_agent_start_polling_from_env",
    "repro_hcr_agent_poll",
    "repro_hcr_agent_poll_nonblocking",
    "repro_hcr_agent_poll_session_open",
    "repro_hcr_agent_poll_messages_handled",
    "repro_hcr_agent_set_source_reload_handler",
    "repro_hcr_agent_advertises_source_reload",
    "repro_hcr_agent_sha256_hex",
    "repro_hcr_agent_default_support_profile",
    "repro_hcr_agent_host_supports_direct_patch",
    "repro_hcr_agent_host_membarrier_sync_core",
    "repro_hcr_agent_host_quiescence_signal",
    "repro_hcr_agent_last_publication_tier",
    "repro_hcr_agent_last_on_stack_threads",
}


def parse_last_json(output: str) -> dict[str, object]:
    lines = [line for line in output.splitlines() if line.strip()]
    if not lines:
        raise AssertionError("process produced no JSON evidence")
    return json.loads(lines[-1])


def wait_for_json(path: Path, timeout: float = 10.0) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file() and path.stat().st_size:
            return json.loads(path.read_text(encoding="utf-8"))
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for target report {path}")


def stop_process(pid: int, stop_file: Path) -> None:
    stop_file.touch()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    synchronize = 0x00100000
    terminate = 0x0001
    handle = kernel32.OpenProcess(synchronize | terminate, False, pid)
    if not handle:
        return
    try:
        if kernel32.WaitForSingleObject(handle, 5_000) != 0:
            kernel32.TerminateProcess(handle, 9)
            kernel32.WaitForSingleObject(handle, 5_000)
    finally:
        kernel32.CloseHandle(handle)


class HxW5WindowsAgentGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo = REPO
        cls.work = cls.repo / "build" / "hx-w5-gate"
        cls.work.mkdir(parents=True, exist_ok=True)
        cls.env = visual_studio_environment()
        cls.cl = shutil.which("cl.exe", path=cls.env.get("PATH"))
        cls.dumpbin = shutil.which("dumpbin.exe", path=cls.env.get("PATH"))
        cls.nim = shutil.which("nim.exe", path=cls.env.get("PATH"))
        for name, value in (
            ("cl.exe", cls.cl),
            ("dumpbin.exe", cls.dumpbin),
            ("nim.exe", cls.nim),
        ):
            if value is None:
                raise AssertionError(f"required HX-W-5 tool is unavailable: {name}")

        cls.good = build_artifacts(cls.work / "good")
        cls.bad = build_artifacts(cls.work / "wrong-profile", MACOS_PROFILE)

        cls.target = cls.work / "hcr_w5_target.exe"
        run_checked(
            [
                cls.cl,
                "/nologo",
                "/std:c11",
                "/W4",
                "/WX",
                "/O2",
                "/MD",
                str(
                    cls.repo
                    / "tests"
                    / "fixtures"
                    / "hcr"
                    / "windows-agent-transport"
                    / "hcr_w5_target.c"
                ),
                f"/Fo:{cls.work / 'hcr_w5_target.obj'}",
                f"/Fe:{cls.target}",
                "/link",
                f"/PDB:{cls.work / 'hcr_w5_target.pdb'}",
            ],
            cls.repo,
            cls.env,
        )

        cls.coordinator = cls.work / "hx_w5_windows_coordinator.exe"
        run_checked(
            [
                cls.nim,
                "c",
                "--cc:vcc",
                "--hints:off",
                "--warnings:off",
                f"--nimcache:{cls.work / 'nimcache'}",
                f"-o:{cls.coordinator}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_agent' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_linker' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_hcr_linkgraph' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_core' / 'src'}",
                f"-p:{cls.repo / 'libs' / 'repro_hash' / 'src'}",
                str(cls.repo / "tests" / "windows" / "hx_w5_windows_coordinator.nim"),
            ],
            cls.repo,
            cls.env,
        )

    def launch(self, artifacts: dict[str, Path], label: str) -> tuple[int, dict[str, object], Path]:
        report = self.work / f"{label}-target.json"
        stop = self.work / f"{label}.stop"
        for path in (report, stop):
            if path.exists():
                path.unlink()
        launcher_log = self.work / f"{label}-launcher.txt"
        with launcher_log.open("w+", encoding="utf-8") as output:
            launched = subprocess.run(
                [
                    str(artifacts["launcher"]),
                    "--agent",
                    str(artifacts["agent"]),
                    "--",
                    str(self.target),
                    str(report),
                    str(stop),
                ],
                cwd=self.repo,
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
        launcher_evidence = parse_last_json(launcher_output)
        pid = int(launcher_evidence["pid"])
        target_evidence = wait_for_json(report)
        self.assertEqual(int(target_evidence["pid"]), pid)
        return pid, target_evidence, stop

    def test_canonical_artifact_exports_the_lifecycle_abi(self) -> None:
        agent = self.good["agent"]
        self.assertEqual(agent.name, "repro_hcr_agent.dll")
        self.assertGreater(agent.stat().st_size, 0)
        exports = run_checked(
            [self.dumpbin, "/nologo", "/exports", str(agent)],
            self.repo,
            self.env,
        )
        for symbol in LIFECYCLE_EXPORTS | {"ReproHcrWindowsBootstrap"}:
            self.assertIn(symbol, exports)

    def test_target_hosts_agent_and_real_coordinator_completes_handshake(self) -> None:
        pid, target, stop = self.launch(self.good, "positive")
        try:
            self.assertTrue(target["moduleEnumerationOk"])
            self.assertTrue(target["canonicalAgentLoaded"])
            coordinated = subprocess.run(
                [str(self.coordinator), str(pid)],
                cwd=self.repo,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
            self.assertEqual(coordinated.returncode, 0, coordinated.stdout)
            evidence = parse_last_json(coordinated.stdout)
            self.assertTrue(evidence["handshake_completed"])
            self.assertEqual(evidence["support_profile"], WINDOWS_PROFILE)
            self.assertIn("hcr-agent-protocol", evidence["capabilities"])
            self.assertIn("windows-named-pipe-transport", evidence["capabilities"])
            self.assertTrue(evidence["direct_patch_advertised"])
            self.assertEqual(evidence["patch_failure_stage"], "applyDirectPatchRequest")
            self.assertTrue(
                str(evidence["patch_failure"]).startswith(
                    "windows-patch-bundle-invalid"
                )
            )
            self.assertGreaterEqual(int(evidence["transcript_frames"]), 5)
        finally:
            stop_process(pid, stop)

    def test_control_target_without_agent_has_no_pipe(self) -> None:
        report = self.work / "control-target.json"
        stop = self.work / "control.stop"
        for path in (report, stop):
            if path.exists():
                path.unlink()
        target = subprocess.Popen(
            [str(self.target), str(report), str(stop)],
            cwd=self.repo,
            env=self.env,
        )
        try:
            evidence = wait_for_json(report)
            self.assertFalse(evidence["canonicalAgentLoaded"])
            coordinator = subprocess.run(
                [str(self.coordinator), str(target.pid)],
                cwd=self.repo,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
            self.assertNotEqual(coordinator.returncode, 0, coordinator.stdout)
            self.assertIn("timed out waiting for HCR agent pipe", coordinator.stdout)
        finally:
            stop.touch()
            target.wait(timeout=10)

    def test_wrong_profile_falsifier_is_refused_during_handshake(self) -> None:
        pid, target, stop = self.launch(self.bad, "wrong-profile")
        try:
            self.assertTrue(target["canonicalAgentLoaded"])
            coordinator = subprocess.run(
                [str(self.coordinator), str(pid)],
                cwd=self.repo,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=15,
                check=False,
            )
            self.assertNotEqual(coordinator.returncode, 0, coordinator.stdout)
            self.assertIn("agent support profile mismatch", coordinator.stdout)
            self.assertIn(WINDOWS_PROFILE, coordinator.stdout)
            self.assertIn(MACOS_PROFILE, coordinator.stdout)
        finally:
            stop_process(pid, stop)


if __name__ == "__main__":
    unittest.main(verbosity=2)
