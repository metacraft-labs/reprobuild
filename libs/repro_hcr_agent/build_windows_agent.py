#!/usr/bin/env python3
"""Build the canonical HX-S-0/HX-W-5 Windows agent artifacts with MSVC."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run_checked(
    args: list[str], cwd: Path, env: dict[str, str]
) -> str:
    process = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(
            f"command failed with exit {process.returncode}: "
            f"{subprocess.list2cmdline(args)}\n{process.stdout}"
        )
    return process.stdout


def visual_studio_environment() -> dict[str, str]:
    """Return an amd64 VC environment, initializing vcvars when necessary."""

    env = dict(os.environ)
    cl = shutil.which("cl.exe", path=env.get("PATH"))
    linker = shutil.which("link.exe", path=env.get("PATH"))
    if cl and linker and env.get("INCLUDE") and env.get("LIB"):
        return env

    vcvars: Path | None = None
    if cl:
        for parent in Path(cl).parents:
            if parent.name.casefold() == "vc":
                candidate = parent / "Auxiliary" / "Build" / "vcvars64.bat"
                if candidate.is_file():
                    vcvars = candidate
                    break
    if vcvars is None:
        program_files_x86 = os.environ.get("ProgramFiles(x86)")
        if not program_files_x86:
            raise RuntimeError(
                "neither cl.exe nor ProgramFiles(x86) can locate Visual Studio"
            )
        vswhere = (
            Path(program_files_x86)
            / "Microsoft Visual Studio"
            / "Installer"
            / "vswhere.exe"
        )
        if not vswhere.is_file():
            raise RuntimeError(f"vswhere.exe not found at {vswhere}")
        install = run_checked(
            [
                str(vswhere),
                "-latest",
                "-products",
                "*",
                "-requires",
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "-property",
                "installationPath",
            ],
            Path.cwd(),
            env,
        ).strip()
        if not install:
            raise RuntimeError("Visual Studio x64 C++ build tools are not installed")
        vcvars = Path(install) / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    if not vcvars.is_file():
        raise RuntimeError(f"vcvars64.bat not found at {vcvars}")
    process = subprocess.run(
        f'cmd.exe /d /s /c ""{vcvars}" >nul && set"',
        cwd=Path.cwd(),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(
            f"vcvars64 failed with exit {process.returncode}:\n{process.stdout}"
        )
    for line in process.stdout.splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            env[name] = value
    return env


def build_artifacts(
    output_dir: Path, profile_override: str | None = None
) -> dict[str, Path]:
    if sys.platform != "win32":
        raise RuntimeError("the Windows HCR agent must be built on Windows")
    root = Path(__file__).resolve().parent
    source = root / "c"
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    env = visual_studio_environment()
    cl = shutil.which("cl.exe", path=env.get("PATH"))
    if cl is None:
        raise RuntimeError("cl.exe is unavailable after vcvars64")

    agent = output_dir / "repro_hcr_agent.dll"
    launcher = output_dir / "repro_hcr_windows_launcher.exe"
    agent_args = [
        cl,
        "/nologo",
        "/std:c11",
        "/W4",
        "/WX",
        "/O2",
        "/MD",
        "/LD",
        str(source / "repro_hcr_agent_windows.c"),
        f"/Fo:{output_dir / 'repro_hcr_agent.obj'}",
        f"/Fe:{agent}",
    ]
    if profile_override is not None:
        if profile_override != "macos-arm64-direct-hcr-in-codetracer-v1":
            raise RuntimeError(
                "the only supported test profile override is the HX-W-5 "
                "macOS falsifier"
            )
        agent_args.insert(7, "/DREPRO_HCR_WINDOWS_MACOS_PROFILE_FALSIFIER=1")
    agent_args.extend(
        [
            "/link",
            "advapi32.lib",
            f"/PDB:{output_dir / 'repro_hcr_agent.pdb'}",
            f"/IMPLIB:{output_dir / 'repro_hcr_agent.lib'}",
        ]
    )
    run_checked(agent_args, root, env)
    run_checked(
        [
            cl,
            "/nologo",
            "/std:c11",
            "/W4",
            "/WX",
            "/O2",
            "/MD",
            str(source / "repro_hcr_windows_launcher.c"),
            f"/Fo:{output_dir / 'repro_hcr_windows_launcher.obj'}",
            f"/Fe:{launcher}",
            "/link",
            f"/PDB:{output_dir / 'repro_hcr_windows_launcher.pdb'}",
        ],
        root,
        env,
    )
    if agent.stat().st_size == 0 or launcher.stat().st_size == 0:
        raise RuntimeError("MSVC produced an empty Windows HCR artifact")
    return {"agent": agent, "launcher": launcher}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--profile-override")
    args = parser.parse_args()
    artifacts = build_artifacts(args.out, args.profile_override)
    print(json.dumps({name: str(path) for name, path in artifacts.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
