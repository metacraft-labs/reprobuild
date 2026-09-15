#!/usr/bin/env python3
"""HX-W-0 real linked-image publication-window measurement gate.

Design: ``reprobuild-specs/HCR/Trampoline-Mechanics.md`` section 1.4.
Milestone: ``HCR-Per-Platform-Handoff.milestones.org`` HX-W-0.

``allowed_mocks: none``.  This gate invokes real MSVC, LINK, Clang/clang-cl,
and MinGW GCC; parses the export, section table, debug directory, and bytes
from each real linked PE; and independently matches the adopted images' PDB
GUID and age to their CodeView records.  The compiler sweep is the subject of
the test, so producing the six binaries at execution time is intentional.

This file deliberately does not use the ``test_*.py`` prefix.  The ordinary
suite runs on Linux and must not turn a Windows-only integration gate into a
skip-as-pass.  Required Windows CI invokes it directly; a non-Windows host is
a hard failure.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import unittest


if sys.platform != "win32":
    raise SystemExit("HX-W-0 linked-image measurement must run on Windows")


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def run_checked(args: list[str], cwd: Path, env: dict[str, str]) -> str:
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
        rendered = subprocess.list2cmdline(args)
        raise AssertionError(
            f"command failed with exit {process.returncode}: {rendered}\n"
            f"{process.stdout}"
        )
    return process.stdout


def tool_banner(args: list[str], cwd: Path, env: dict[str, str]) -> str:
    """Read a tool's banner even when its no-input usage exit is non-zero."""

    process = subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    lines = [line.strip() for line in process.stdout.splitlines() if line.strip()]
    if not lines:
        raise AssertionError(
            f"tool emitted no version or usage banner: {subprocess.list2cmdline(args)}"
        )
    return lines[0]


def visual_studio_environment() -> dict[str, str]:
    """Return an amd64 VC environment, initializing it through vcvars if needed."""

    env = dict(os.environ)
    cl = shutil.which("cl.exe", path=env.get("PATH"))
    linker = shutil.which("link.exe", path=env.get("PATH"))
    if cl and linker and env.get("INCLUDE") and env.get("LIB"):
        return env

    vcvars = None
    # A constrained launcher may preserve PATH while omitting ProgramFiles(x86),
    # INCLUDE, and LIB. Recover vcvars from the cl.exe installation itself.
    if cl:
        for parent in Path(cl).parents:
            if parent.name.casefold() == "vc":
                candidate = parent / "Auxiliary" / "Build" / "vcvars64.bat"
                if candidate.is_file():
                    vcvars = candidate
                    break
    if vcvars is None:
        program_files_x86 = env.get("ProgramFiles(x86)")
        if not program_files_x86:
            raise AssertionError(
                "neither cl.exe nor ProgramFiles(x86) can locate Visual Studio"
            )
        vswhere = (
            Path(program_files_x86)
            / "Microsoft Visual Studio"
            / "Installer"
            / "vswhere.exe"
        )
        if not vswhere.is_file():
            raise AssertionError(f"vswhere.exe not found at {vswhere}")
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
            raise AssertionError("Visual Studio x64 C++ build tools are not installed")
        vcvars = Path(install) / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    if not vcvars.is_file():
        raise AssertionError(f"vcvars64.bat not found at {vcvars}")
    command = f'cmd.exe /d /s /c ""{vcvars}" >nul && set"'
    process = subprocess.run(
        command,
        cwd=Path.cwd(),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if process.returncode != 0:
        raise AssertionError(
            f"vcvars64 failed with exit {process.returncode}:\n{process.stdout}"
        )
    for line in process.stdout.splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            env[name] = value
    if not shutil.which("cl.exe", path=env.get("PATH")):
        raise AssertionError("vcvars64 completed but cl.exe is still unavailable")
    if not shutil.which("link.exe", path=env.get("PATH")):
        raise AssertionError("vcvars64 completed but link.exe is still unavailable")
    return env


def required_tool(name: str, env: dict[str, str]) -> str:
    found = shutil.which(name, path=env.get("PATH"))
    if not found:
        raise AssertionError(f"required HX-W-0 tool is not on PATH: {name}")
    return found


class PeImage:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if len(self.data) < 0x40 or self.data[:2] != b"MZ":
            raise AssertionError(f"{path} is not a DOS/PE image")
        self.pe_offset = u32(self.data, 0x3C)
        if self.data[self.pe_offset : self.pe_offset + 4] != b"PE\0\0":
            raise AssertionError(f"{path} has no PE signature")
        coff = self.pe_offset + 4
        self.number_of_sections = u16(self.data, coff + 2)
        self.symbol_table_offset = u32(self.data, coff + 8)
        self.number_of_symbols = u32(self.data, coff + 12)
        optional_size = u16(self.data, coff + 16)
        optional = coff + 20
        if u16(self.data, optional) != 0x20B:
            raise AssertionError(f"{path} is not PE32+ (x86_64)")
        self.data_directories = optional + 112
        section_table = optional + optional_size
        self.sections: list[dict[str, int | str]] = []
        for index in range(self.number_of_sections):
            header = section_table + index * 40
            raw_name = self.data[header : header + 8].split(b"\0", 1)[0]
            name = self._section_name(raw_name)
            self.sections.append(
                {
                    "name": name,
                    "virtual_size": u32(self.data, header + 8),
                    "virtual_address": u32(self.data, header + 12),
                    "raw_size": u32(self.data, header + 16),
                    "raw_offset": u32(self.data, header + 20),
                }
            )

    def _section_name(self, raw_name: bytes) -> str:
        text = raw_name.decode("ascii", errors="strict")
        if not text.startswith("/"):
            return text
        if not self.symbol_table_offset:
            raise AssertionError(
                f"{self.path} uses COFF long section name {text} without a symbol table"
            )
        string_offset = int(text[1:])
        string_table = self.symbol_table_offset + self.number_of_symbols * 18
        start = string_table + string_offset
        end = self.data.find(b"\0", start)
        if end < 0:
            raise AssertionError(f"unterminated COFF long section name {text}")
        return self.data[start:end].decode("ascii", errors="strict")

    def directory(self, index: int) -> tuple[int, int]:
        offset = self.data_directories + index * 8
        return u32(self.data, offset), u32(self.data, offset + 4)

    def rva_offset(self, rva: int) -> int:
        for section in self.sections:
            start = int(section["virtual_address"])
            span = max(int(section["virtual_size"]), int(section["raw_size"]))
            if start <= rva < start + span:
                delta = rva - start
                if delta >= int(section["raw_size"]):
                    raise AssertionError(
                        f"RVA 0x{rva:x} is in virtual-only bytes of {self.path}"
                    )
                return int(section["raw_offset"]) + delta
        raise AssertionError(f"RVA 0x{rva:x} is not mapped by {self.path}")

    def exported_rva(self, wanted: str) -> int:
        export_rva, export_size = self.directory(0)
        if not export_rva or not export_size:
            raise AssertionError(f"{self.path} has no export directory")
        export = self.rva_offset(export_rva)
        function_count = u32(self.data, export + 20)
        name_count = u32(self.data, export + 24)
        functions = self.rva_offset(u32(self.data, export + 28))
        names = self.rva_offset(u32(self.data, export + 32))
        ordinals = self.rva_offset(u32(self.data, export + 36))
        for index in range(name_count):
            name_offset = self.rva_offset(u32(self.data, names + index * 4))
            end = self.data.find(b"\0", name_offset)
            name = self.data[name_offset:end].decode("ascii", errors="strict")
            if name != wanted:
                continue
            ordinal = u16(self.data, ordinals + index * 2)
            if ordinal >= function_count:
                raise AssertionError(f"export {wanted} has invalid ordinal {ordinal}")
            rva = u32(self.data, functions + ordinal * 4)
            if export_rva <= rva < export_rva + export_size:
                raise AssertionError(f"export {wanted} is a forwarder, not code")
            return rva
        raise AssertionError(f"{self.path} does not export {wanted}")

    def codeview_identity(self) -> tuple[bytes, int, str]:
        debug_rva, debug_size = self.directory(6)
        if not debug_rva or debug_size < 28:
            raise AssertionError(f"{self.path} has no PE debug directory")
        debug = self.rva_offset(debug_rva)
        for offset in range(debug, debug + debug_size, 28):
            if u32(self.data, offset + 12) != 2:  # IMAGE_DEBUG_TYPE_CODEVIEW
                continue
            size = u32(self.data, offset + 16)
            raw = u32(self.data, offset + 24)
            record = self.data[raw : raw + size]
            if record[:4] != b"RSDS" or len(record) < 25:
                continue
            guid = record[4:20]
            age = u32(record, 20)
            path_end = record.find(b"\0", 24)
            pdb_path = record[24:path_end].decode("utf-8", errors="replace")
            return guid, age, pdb_path
        raise AssertionError(f"{self.path} has no RSDS CodeView record")


def pdb_identity(path: Path) -> tuple[bytes, int]:
    """Read stream 1 from an MSF 7.0 PDB and return its raw GUID and age."""

    data = path.read_bytes()
    signature = b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0"
    if not data.startswith(signature) or len(data) < 56:
        raise AssertionError(f"{path} is not an MSF 7.0 PDB")
    block_size = u32(data, 32)
    block_count = u32(data, 40)
    directory_size = u32(data, 44)
    block_map = u32(data, 52)
    if block_size < 512 or block_size & (block_size - 1):
        raise AssertionError(f"{path} has invalid PDB block size {block_size}")
    if block_count * block_size > len(data):
        raise AssertionError(f"{path} PDB block count exceeds file length")
    directory_block_count = math.ceil(directory_size / block_size)
    map_offset = block_map * block_size
    directory_blocks = [
        u32(data, map_offset + index * 4)
        for index in range(directory_block_count)
    ]
    directory = b"".join(
        data[block * block_size : (block + 1) * block_size]
        for block in directory_blocks
    )[:directory_size]
    stream_count = u32(directory, 0)
    if stream_count < 2:
        raise AssertionError(f"{path} PDB has only {stream_count} streams")
    cursor = 4
    sizes = [u32(directory, cursor + index * 4) for index in range(stream_count)]
    cursor += stream_count * 4
    stream_blocks: list[list[int]] = []
    for size in sizes:
        count = 0 if size == 0xFFFFFFFF else math.ceil(size / block_size)
        blocks = [u32(directory, cursor + index * 4) for index in range(count)]
        cursor += count * 4
        stream_blocks.append(blocks)
    info_size = sizes[1]
    if info_size == 0xFFFFFFFF or info_size < 28:
        raise AssertionError(f"{path} PDB info stream is absent or truncated")
    info = b"".join(
        data[block * block_size : (block + 1) * block_size]
        for block in stream_blocks[1]
    )[:info_size]
    return info[12:28], u32(info, 8)


def first_instruction(code: bytes) -> tuple[int, str]:
    """Decode the fixture-entry instructions which define this measured matrix."""

    if code.startswith(b"\x8d\x41\x0b"):
        return 3, "lea eax,[rcx+0xb]"
    maximal_nop = bytes.fromhex("66666666662e660f1f840000020000")
    if code.startswith(maximal_nop):
        return 15, "15-byte nop"
    if code.startswith(b"\x90"):
        return 1, "nop"
    raise AssertionError(
        "victim's first linked instruction is outside the HX-W-0 measured "
        f"decoder corpus: {code[:16].hex()}"
    )


def padding_run_before(image: PeImage, entry_rva: int) -> tuple[int, str]:
    entry = image.rva_offset(entry_rva)
    cursor = entry - 1
    if cursor < 0 or image.data[cursor] not in (0x90, 0xCC):
        return 0, "none"
    byte = image.data[cursor]
    while cursor >= 0 and image.data[cursor] == byte:
        cursor -= 1
    return entry - cursor - 1, f"0x{byte:02x}"


class HxW0Measurement(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.repo = Path(__file__).resolve().parents[2]
        self.fixture = (
            self.repo
            / "tests"
            / "fixtures"
            / "hcr"
            / "windows-entry-geometry"
            / "hcr_w0_probe.c"
        )
        self.work = self.repo / "build" / "hcr-w0-windows-entry-geometry"
        self.logs = self.repo / "test-logs"
        self.work.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)
        self.env = visual_studio_environment()
        self.cl = required_tool("cl.exe", self.env)
        self.link = required_tool("link.exe", self.env)
        self.clang_cl = required_tool("clang-cl.exe", self.env)
        self.clang = required_tool("clang.exe", self.env)
        self.gcc = required_tool("gcc.exe", self.env)

    def build_msvc_like(
        self,
        tag: str,
        compiler: str,
        compiler_args: list[str],
        linker_args: list[str],
    ) -> tuple[Path, Path, str]:
        obj = self.work / f"{tag}.obj"
        image = self.work / f"{tag}.exe"
        pdb = self.work / f"{tag}.pdb"
        compile_output = run_checked(
            [compiler, *compiler_args, str(self.fixture), f"/Fo{obj}"],
            self.repo,
            self.env,
        )
        self.assertTrue(obj.is_file(), f"{tag} did not produce its object")
        link_output = run_checked(
            [
                self.link,
                "/NOLOGO",
                "/NODEFAULTLIB",
                "/ENTRY:main",
                "/SUBSYSTEM:CONSOLE",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOICF",
                "/OPT:NOREF",
                "/EXPORT:victim",
                f"/OUT:{image}",
                f"/PDB:{pdb}",
                *linker_args,
                str(obj),
            ],
            self.repo,
            self.env,
        )
        self.assertTrue(image.is_file(), f"{tag} did not produce a linked PE")
        self.assertTrue(pdb.is_file(), f"{tag} did not produce a full PDB")
        return image, pdb, compile_output + link_output

    def measure(
        self,
        tag: str,
        image_path: Path,
        pdb_path: Path | None,
        declaration: str,
        expected_result: str,
    ) -> dict[str, object]:
        image = PeImage(image_path)
        entry_rva = image.exported_rva("victim")
        entry_offset = image.rva_offset(entry_rva)
        entry_bytes = image.data[entry_offset : entry_offset + 32]
        instruction_length, instruction = first_instruction(entry_bytes)
        padding_bytes, padding_kind = padding_run_before(image, entry_rva)
        pdb_match: bool | None = None
        codeview_path: str | None = None
        if pdb_path is not None:
            pe_guid, pe_age, codeview_path = image.codeview_identity()
            pdb_guid, pdb_age = pdb_identity(pdb_path)
            pdb_match = pe_guid == pdb_guid and pe_age == pdb_age
        return {
            "tag": tag,
            "image": str(image_path.relative_to(self.repo)),
            "linkedImageBytes": image_path.stat().st_size,
            "entryRva": f"0x{entry_rva:x}",
            "entryBytesHex": entry_bytes.hex(),
            "firstInstruction": instruction,
            "firstInstructionLength": instruction_length,
            "paddingBytesImmediatelyBeforeEntry": padding_bytes,
            "paddingKind": padding_kind,
            "sections": [section["name"] for section in image.sections],
            "declaration": declaration,
            "pdbIdentityMatchesCodeView": pdb_match,
            "codeViewPdbPath": codeview_path,
            "result": expected_result,
        }

    def test_hx_w0_the_windows_publication_decision_is_recorded_and_measured(self) -> None:
        cells: list[dict[str, object]] = []

        common_msvc = ["/nologo", "/c", "/O2", "/GS-", "/Gy-", "/GL-", "/Zi"]
        for tag, function_padding, expected in [
            ("msvc-default", None, "refuse-no-declared-window"),
            ("msvc-functionpadmin-6", "/FUNCTIONPADMIN:6", "adopt-v1"),
            ("msvc-functionpadmin-16", "/FUNCTIONPADMIN:16", "capable-extra-padding"),
        ]:
            image_path, pdb_path, _ = self.build_msvc_like(
                tag,
                self.cl,
                [*common_msvc, f"/Fd{self.work / (tag + '-compile.pdb')}"],
                [] if function_padding is None else [function_padding],
            )
            cell = self.measure(
                tag,
                image_path,
                pdb_path,
                "none" if function_padding is None else function_padding,
                expected,
            )
            self.assertEqual(cell["firstInstructionLength"], 3)
            self.assertTrue(cell["pdbIdentityMatchesCodeView"])
            if function_padding == "/FUNCTIONPADMIN:6":
                self.assertGreaterEqual(cell["paddingBytesImmediatelyBeforeEntry"], 6)
                self.assertEqual(cell["paddingKind"], "0xcc")
            if function_padding == "/FUNCTIONPADMIN:16":
                self.assertGreaterEqual(cell["paddingBytesImmediatelyBeforeEntry"], 16)
                self.assertEqual(cell["paddingKind"], "0xcc")
            cells.append(cell)

        clang_cl_image, clang_cl_pdb, _ = self.build_msvc_like(
            "clang-cl-default",
            self.clang_cl,
            ["/nologo", "/c", "/O2", "/GS-", "/Z7"],
            [],
        )
        clang_cl_cell = self.measure(
            "clang-cl-default",
            clang_cl_image,
            clang_cl_pdb,
            "none",
            "refuse-no-declared-window",
        )
        self.assertEqual(clang_cl_cell["firstInstructionLength"], 3)
        self.assertNotIn(
            "__patchable_function_entries", clang_cl_cell["sections"]
        )
        cells.append(clang_cl_cell)

        clang_obj = self.work / "clang-msvc-target-patchable.obj"
        clang_image = self.work / "clang-msvc-target-patchable.exe"
        clang_pdb = self.work / "clang-msvc-target-patchable.pdb"
        run_checked(
            [
                self.clang,
                "--target=x86_64-pc-windows-msvc",
                "-c",
                "-O2",
                "-gcodeview",
                "-fno-stack-protector",
                "-fpatchable-function-entry=16,0",
                str(self.fixture),
                "-o",
                str(clang_obj),
            ],
            self.repo,
            self.env,
        )
        run_checked(
            [
                self.link,
                "/NOLOGO",
                "/NODEFAULTLIB",
                "/ENTRY:main",
                "/SUBSYSTEM:CONSOLE",
                "/DEBUG:FULL",
                "/INCREMENTAL:NO",
                "/OPT:NOICF",
                "/OPT:NOREF",
                "/EXPORT:victim",
                f"/OUT:{clang_image}",
                f"/PDB:{clang_pdb}",
                str(clang_obj),
            ],
            self.repo,
            self.env,
        )
        self.assertTrue(clang_image.is_file())
        clang_cell = self.measure(
            "clang-msvc-target-patchable",
            clang_image,
            clang_pdb,
            "-fpatchable-function-entry=16,0",
            "refuse-no-runtime-declaration",
        )
        self.assertEqual(clang_cell["firstInstructionLength"], 15)
        self.assertTrue(
            str(clang_cell["entryBytesHex"]).startswith(
                "66666666662e660f1f84000002000090"
            )
        )
        self.assertNotIn("__patchable_function_entries", clang_cell["sections"])
        cells.append(clang_cell)

        mingw_image = self.work / "mingw-gcc-patchable.exe"
        run_checked(
            [
                self.gcc,
                "-O2",
                "-g",
                "-fpatchable-function-entry=16,0",
                "-falign-functions=16",
                str(self.fixture),
                "-Wl,--export-all-symbols",
                "-o",
                str(mingw_image),
            ],
            self.repo,
            self.env,
        )
        self.assertTrue(mingw_image.is_file())
        mingw_cell = self.measure(
            "mingw-gcc-patchable",
            mingw_image,
            None,
            "__patchable_function_entries",
            "capable-outside-pdb-v1",
        )
        self.assertEqual(mingw_cell["firstInstructionLength"], 1)
        self.assertTrue(str(mingw_cell["entryBytesHex"]).startswith("90" * 16))
        self.assertIn("__patchable_function_entries", mingw_cell["sections"])
        cells.append(mingw_cell)

        # Anti-vacuity: every matrix cell linked, every entry decoded, and the
        # sweep includes both an adopted profile and several real refusals.
        self.assertGreaterEqual(len(cells), 6)
        self.assertTrue(all(int(cell["linkedImageBytes"]) > 0 for cell in cells))
        self.assertTrue(all(int(cell["firstInstructionLength"]) > 0 for cell in cells))
        self.assertEqual(sum(cell["result"] == "adopt-v1" for cell in cells), 1)
        self.assertGreaterEqual(
            sum(str(cell["result"]).startswith("refuse-") for cell in cells), 3
        )

        evidence = {
            "schemaId": "reprobuild.hcr.hx-w0.windows-entry-geometry.v1",
            "supportProfile": "windows-x86_64-msvc-pe-direct-hcr-v1",
            "publication": {
                "paddingStore": "entry-5: E9 rel32",
                "entryStore": "entry: EB F9",
                "minimumPaddingBytes": 6,
                "publicationRequiresQuiescence": True,
                "pdbIdentity": "PE CodeView RSDS GUID+age equals PDB stream 1 GUID+age",
            },
            "tools": {
                "cl": tool_banner([self.cl], self.repo, self.env),
                "link": tool_banner([self.link], self.repo, self.env),
                "clangCl": tool_banner(
                    [self.clang_cl, "--version"], self.repo, self.env
                ),
                "clang": tool_banner(
                    [self.clang, "--version"], self.repo, self.env
                ),
                "gcc": tool_banner(
                    [self.gcc, "--version"], self.repo, self.env
                ),
            },
            "cells": cells,
            "linuxControlArm": (
                "integration_hcr_linux_cf_protection_sled_layout independently "
                "re-derives the known GCC/Clang linked-image results"
            ),
        }
        evidence_path = (
            self.logs
            / "hx_w0_windows_publication_decision_is_recorded_and_measured.json"
        )
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main(verbosity=2)
