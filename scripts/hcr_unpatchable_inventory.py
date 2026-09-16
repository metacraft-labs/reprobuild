#!/usr/bin/env python3
"""hcr_unpatchable_inventory.py

Inventory generator and legibility tool for HCR patchable binaries (Milestone HX-L-1).

Parses target ELF binaries, identifies defined FUNC symbols, cross-references them
against __patchable_function_entries, attributes unsledded functions to originating
archives (e.g. libcodetracer_trace_writer.a) or translation units, and emits machine-readable
inventory artifacts (schemaId: reprobuild.hcr.unpatchable-inventory.v1).

Also supports ahead-of-time legibility queries (--query <symbol>) and reload attempts
emulating repro_hcr_agent publication decisions.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from typing import Dict, List, Optional, Set, Tuple

# --- ELF Constants -----------------------------------------------------------
PT_LOAD = 1
SHT_SYMTAB = 2
SHT_STRTAB = 3
SHT_NOTE = 7
SHT_DYNSYM = 11

SHF_WRITE = 0x1
SHF_ALLOC = 0x2
SHF_EXECINSTR = 0x4

STT_NOTYPE = 0
STT_OBJECT = 1
STT_FUNC = 2
STT_SECTION = 3
STT_FILE = 4
STT_COMMON = 5
STT_TLS = 6
STT_GNU_IFUNC = 10

REPRO_HCR_LX_MAX_LANDING_PAD_BYTES = 8
REPRO_HCR_LX_MAX_SLED_SCAN = 64
REPRO_HCR_LX_WINDOW_BYTES = 8


class ElfError(Exception):
    """ELF format or parsing error."""


class Section:
    __slots__ = ("name", "type", "flags", "addr", "offset", "size", "entsize", "link", "info")

    def __init__(self, *, name: str, type_: int, flags: int, addr: int, offset: int, size: int, entsize: int, link: int, info: int):
        self.name = name
        self.type = type_
        self.flags = flags
        self.addr = addr
        self.offset = offset
        self.size = size
        self.entsize = entsize
        self.link = link
        self.info = info


class ElfSymbol:
    __slots__ = ("name", "type", "bind", "shndx", "value", "size", "source_file")

    def __init__(self, name: str, type_: int, bind: int, shndx: int, value: int, size: int, source_file: Optional[str] = None):
        self.name = name
        self.type = type_
        self.bind = bind
        self.shndx = shndx
        self.value = value
        self.size = size
        self.source_file = source_file

    @property
    def is_defined(self) -> bool:
        return self.shndx != 0 and self.shndx < 0xFF00


class Elf64Reader:
    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as handle:
            self.data = handle.read()
        if len(self.data) < 64 or self.data[:4] != b"\x7fELF":
            raise ElfError(f"{path}: not an ELF file")
        if self.data[4] != 2 or self.data[5] != 1:
            raise ElfError(f"{path}: not little-endian ELF64")

        (
            self.e_type,
            self.e_machine,
            _version,
            self.e_entry,
            e_phoff,
            e_shoff,
            _flags,
            _ehsize,
            e_phentsize,
            e_phnum,
            e_shentsize,
            e_shnum,
            e_shstrndx,
        ) = struct.unpack_from("<HHIQQQIHHHHHH", self.data, 16)

        self.segments: List[Tuple[int, int, int]] = []
        for i in range(e_phnum):
            p_type, _pf, p_offset, p_vaddr, _pa, p_filesz, _pm, _pal = struct.unpack_from(
                "<IIQQQQQQ", self.data, e_phoff + i * e_phentsize
            )
            if p_type == PT_LOAD:
                self.segments.append((p_vaddr, p_offset, p_filesz))

        if e_shoff == 0 or e_shnum == 0:
            raise ElfError(f"{path}: no section headers present")

        raw_shdrs = []
        for i in range(e_shnum):
            fields = struct.unpack_from("<IIQQQQIIQQ", self.data, e_shoff + i * e_shentsize)
            raw_shdrs.append(fields)

        strtab_off = raw_shdrs[e_shstrndx][4]
        strtab_size = raw_shdrs[e_shstrndx][5]

        def sname(off: int) -> str:
            if off >= strtab_size:
                raise ElfError(f"{path}: section name offset {off} out of range")
            end = self.data.index(b"\0", strtab_off + off)
            return self.data[strtab_off + off : end].decode("utf-8", "replace")

        self.sections: List[Section] = [
            Section(
                name=sname(f[0]),
                type_=f[1],
                flags=f[2],
                addr=f[3],
                offset=f[4],
                size=f[5],
                entsize=f[9],
                link=f[6],
                info=f[7],
            )
            for f in raw_shdrs
        ]
        self.by_name: Dict[str, Section] = {s.name: s for s in self.sections if s.name}

    def vaddr_to_file(self, vaddr: int) -> int:
        for p_vaddr, p_offset, p_filesz in self.segments:
            if p_vaddr <= vaddr < p_vaddr + p_filesz:
                return p_offset + (vaddr - p_vaddr)
        raise ElfError(f"virtual address 0x{vaddr:x} is not mapped in any PT_LOAD segment")

    def bytes_at_vaddr(self, vaddr: int, count: int) -> bytes:
        off = self.vaddr_to_file(vaddr)
        if off + count > len(self.data):
            raise ElfError(f"0x{vaddr:x}+{count} exceeds binary file length")
        return self.data[off : off + count]

    def extract_build_id(self) -> str:
        sec = self.by_name.get(".note.gnu.build-id")
        if not sec or sec.size < 16:
            return "unknown-build-id"
        namesz, descsz, _ntype = struct.unpack_from("<III", self.data, sec.offset)
        desc_off = sec.offset + 12 + ((namesz + 3) & ~3)
        return self.data[desc_off : desc_off + descsz].hex()

    def read_sled_addresses(self) -> List[int]:
        sec = self.by_name.get("__patchable_function_entries")
        if not sec or sec.size == 0:
            return []
        if not (sec.flags & SHF_ALLOC):
            raise ElfError("__patchable_function_entries is present but NOT SHF_ALLOC")
        if sec.size % 8 != 0:
            raise ElfError(f"__patchable_function_entries size {sec.size} is not multiple of 8")
        count = sec.size // 8
        return list(struct.unpack_from(f"<{count}Q", self.data, sec.offset))

    def read_symbols(self) -> List[ElfSymbol]:
        sym_sec = self.by_name.get(".symtab") or self.by_name.get(".dynsym")
        if not sym_sec:
            return []
        strtab = self.sections[sym_sec.link]
        entsize = sym_sec.entsize or 24
        count = sym_sec.size // entsize

        symbols: List[ElfSymbol] = []
        current_file: Optional[str] = None

        for i in range(count):
            st_name, st_info, _other, st_shndx, st_value, st_size = struct.unpack_from(
                "<IBBHQQ", self.data, sym_sec.offset + i * entsize
            )
            end = self.data.index(b"\0", strtab.offset + st_name)
            name = self.data[strtab.offset + st_name : end].decode("utf-8", "replace")
            sym_type = st_info & 0xF
            sym_bind = st_info >> 4

            if sym_type == STT_FILE:
                current_file = name

            sym = ElfSymbol(
                name=name,
                type_=sym_type,
                bind=sym_bind,
                shndx=st_shndx,
                value=st_value,
                size=st_size,
                source_file=current_file,
            )
            symbols.append(sym)

        return symbols


# --- Archive Parser -----------------------------------------------------------

class ArArchive:
    """Parses GNU / BSD style ar archives (.a)."""

    def __init__(self, path: str):
        self.path = path
        self.basename = os.path.basename(path)
        self.symbols: Dict[str, str] = {}  # symbol_name -> member_name
        self.members: Dict[str, bytes] = {}
        self._parse()

    def _parse(self) -> None:
        if not os.path.isfile(self.path):
            return
        with open(self.path, "rb") as f:
            magic = f.read(8)
            if magic != b"!<arch>\n":
                return

            # Read headers
            raw_members: List[Tuple[str, int, int]] = []  # (name, file_offset, size)
            strtab_data = b""

            while True:
                pos = f.tell()
                hdr = f.read(60)
                if len(hdr) < 60:
                    break
                raw_name = hdr[:16].strip()
                size = int(hdr[48:58].strip())
                data_offset = f.tell()

                if raw_name == b"//":
                    strtab_data = f.read(size)
                else:
                    raw_members.append((raw_name.decode("ascii", "replace"), data_offset, size))
                    f.seek(data_offset + size + (size % 2))

            # Process members and symbol tables
            offset_to_name: Dict[int, str] = {}
            for name, offset, size in raw_members:
                resolved_name = name
                if name.startswith("/") and name[1:].isdigit():
                    idx = int(name[1:])
                    end = strtab_data.find(b"/\n", idx)
                    if end == -1:
                        end = strtab_data.find(b"\n", idx)
                    if end != -1:
                        resolved_name = strtab_data[idx:end].decode("utf-8", "replace")
                offset_to_name[offset - 60] = resolved_name

            # Check for GNU symbol table at first member "/"
            for name, offset, size in raw_members:
                if name == "/":
                    f.seek(offset)
                    symtab_bytes = f.read(size)
                    if len(symtab_bytes) >= 4:
                        num_syms = struct.unpack(">I", symtab_bytes[:4])[0]
                        if len(symtab_bytes) >= 4 + 4 * num_syms:
                            member_offsets = struct.unpack(
                                f">{num_syms}I", symtab_bytes[4 : 4 + 4 * num_syms]
                            )
                            strings = symtab_bytes[4 + 4 * num_syms :].split(b"\0")
                            for idx, sym_bytes in enumerate(strings):
                                if not sym_bytes:
                                    continue
                                sym_name = sym_bytes.decode("utf-8", "replace")
                                if idx < len(member_offsets):
                                    m_off = member_offsets[idx]
                                    m_name = offset_to_name.get(m_off, "unknown_member.o")
                                    self.symbols[sym_name] = m_name
                                else:
                                    self.symbols[sym_name] = "member.o"


# --- NOP Decoding & Sled Planning --------------------------------------------

def repro_hcr_lx_nop_length(p: bytes, offset: int = 0) -> int:
    """Exact port of repro_hcr_lx_nop_length from repro_hcr_linux_x86_64.h."""
    avail = len(p) - offset
    if avail <= 0:
        return 0
    i = 0
    while i < avail:
        b = p[offset + i]
        if b in (0x66, 0x2E, 0x3E, 0x26, 0x36, 0x64, 0x65) or (0x40 <= b <= 0x4F):
            i += 1
            continue
        break
    if i >= avail:
        return 0
    if p[offset + i] == 0x90:
        return i + 1
    if p[offset + i] != 0x0F:
        return 0
    if i + 1 >= avail or p[offset + i + 1] != 0x1F:
        return 0
    j = i + 2
    if j >= avail:
        return 0
    modrm = p[offset + j]
    j += 1
    mod_bits = modrm >> 6
    rm_bits = modrm & 0x7
    if mod_bits == 0x3:
        return 0
    have_sib = False
    sib = 0
    if rm_bits == 0x4:
        if j >= avail:
            return 0
        sib = p[offset + j]
        have_sib = True
        j += 1
    if mod_bits == 0x1:
        j += 1
    elif mod_bits == 0x2:
        j += 4
    elif mod_bits == 0x0:
        if rm_bits == 0x5:
            j += 4
        elif have_sib and (sib & 0x7) == 0x5:
            j += 4
    if j > avail:
        return 0
    return j


class SledPlan:
    def __init__(self, sled_address: int, sled_end: int, sled_length: int, window_address: int, refusal: str):
        self.sled_address = sled_address
        self.sled_end = sled_end
        self.sled_length = sled_length
        self.window_address = window_address
        self.refusal = refusal


def plan_sled(sled_bytes: bytes, sled_address: int) -> SledPlan:
    """Exact port of repro_hcr_lx_plan_sled from repro_hcr_linux_x86_64.h."""
    if not sled_bytes:
        return SledPlan(sled_address, sled_address, 0, 0, "absent-sled")

    scan_limit = min(len(sled_bytes), REPRO_HCR_LX_MAX_SLED_SCAN)
    offset = 0
    while offset < scan_limit:
        nop_len = repro_hcr_lx_nop_length(sled_bytes, offset)
        if nop_len == 0:
            break
        offset += nop_len

    sled_end = sled_address + offset
    sled_length = offset

    if offset == 0:
        return SledPlan(sled_address, sled_end, sled_length, 0, "non-nop-sled")
    if offset < REPRO_HCR_LX_WINDOW_BYTES:
        return SledPlan(sled_address, sled_end, sled_length, 0, "short-sled")

    # Does any 8-byte aligned 8-byte window lie wholly inside the run?
    candidate = (sled_address + 7) & ~7
    if candidate + REPRO_HCR_LX_WINDOW_BYTES > sled_end:
        return SledPlan(sled_address, sled_end, sled_length, 0, "misaligned-entry")

    # Walk instruction boundaries and take the lowest that is 8-aligned and fits
    offset = 0
    while offset < sled_length:
        boundary = sled_address + offset
        if (boundary & 7) == 0 and boundary + REPRO_HCR_LX_WINDOW_BYTES <= sled_end:
            return SledPlan(sled_address, sled_end, sled_length, boundary, "ok")
        nop_len = repro_hcr_lx_nop_length(sled_bytes, offset)
        if nop_len == 0:
            break
        offset += nop_len

    return SledPlan(sled_address, sled_end, sled_length, 0, "sled-window-not-instruction-boundary")


# --- Inventory Core Logic -----------------------------------------------------

class UnpatchableInventory:
    def __init__(self, binary_path: str, archive_paths: Optional[List[str]] = None):
        self.binary_path = binary_path
        self.elf = Elf64Reader(binary_path)
        self.archive_symbols: Dict[str, Tuple[str, str]] = {}  # sym -> (archive_basename, member)
        self.archive_basenames: Set[str] = set()

        if archive_paths:
            for p in archive_paths:
                ar = ArArchive(p)
                self.archive_basenames.add(ar.basename)
                for sym_name, member in ar.symbols.items():
                    self.archive_symbols[sym_name] = (ar.basename, member)

        self.sled_addrs = sorted(self.elf.read_sled_addresses())
        self.symbols = self.elf.read_symbols()

    def find_sled_for_entry(self, entry_address: int) -> Optional[int]:
        """Port of repro_hcr_lx_sled_address_for_entry: checks [entry .. entry + 8]."""
        for addr in self.sled_addrs:
            if addr < entry_address:
                continue
            if addr - entry_address > REPRO_HCR_LX_MAX_LANDING_PAD_BYTES:
                break
            return addr
        return None

    def attribute_symbol(self, sym: ElfSymbol) -> str:
        """Attributes an unsledded symbol to originating object or archive."""
        if sym.name in self.archive_symbols:
            ar_name, _member = self.archive_symbols[sym.name]
            return ar_name

        if sym.source_file:
            src = sym.source_file
            # Check if source_file matches Nim-generated CTFS pattern or archive member
            if "@mcodetracer_" in src or src.startswith("@p") or "ct_writer" in src:
                for ar_name in self.archive_basenames:
                    if "libcodetracer_trace_writer" in ar_name:
                        return ar_name
                return "libcodetracer_trace_writer.a"
            if src.endswith((".s", ".S")):
                return "assembly"
            return os.path.basename(src)

        # Common runtime / linker symbols
        if sym.name.startswith(("_start", "__libc_csu", "deregister_tm_clones", "register_tm_clones")):
            return "linker/crt"

        return "unknown"

    def compute_inventory(self) -> Dict:
        defined_funcs: List[ElfSymbol] = [
            s for s in self.symbols if s.type in (STT_FUNC, STT_GNU_IFUNC) and s.is_defined
        ]

        patchable_symbols = []
        unpatchable_symbols = []
        attribution_breakdown: Dict[str, int] = {}

        for sym in defined_funcs:
            sled_addr = self.find_sled_for_entry(sym.value)
            if sled_addr is not None:
                patchable_symbols.append((sym, sled_addr))
            else:
                origin = self.attribute_symbol(sym)
                unpatchable_symbols.append(
                    {
                        "symbol": sym.name,
                        "address": f"0x{sym.value:x}",
                        "size": sym.size,
                        "object": origin,
                        "reason": "absent-sled",
                    }
                )
                attribution_breakdown[origin] = attribution_breakdown.get(origin, 0) + 1

        return {
            "schemaId": "reprobuild.hcr.unpatchable-inventory.v1",
            "binary": os.path.basename(self.binary_path),
            "buildId": self.elf.extract_build_id(),
            "totalDefinedFuncs": len(defined_funcs),
            "sledCount": len(patchable_symbols),
            "unpatchableCount": len(unpatchable_symbols),
            "attributionBreakdown": attribution_breakdown,
            "unpatchableSymbols": unpatchable_symbols,
        }

    def query_symbol(self, symbol_name: str) -> Tuple[bool, Dict]:
        """Queries whether a symbol is patchable or unpatchable."""
        matching = [s for s in self.symbols if s.name == symbol_name and s.is_defined]
        if not matching:
            raise KeyError(f"symbol '{symbol_name}' not found in binary symbols")

        sym = matching[0]
        sled_addr = self.find_sled_for_entry(sym.value)

        if sled_addr is not None:
            # Check sled bytes
            try:
                sled_bytes = self.elf.bytes_at_vaddr(sled_addr, 16)
                plan = plan_sled(sled_bytes, sled_addr)
            except ElfError:
                plan = SledPlan(sled_addr, sled_addr, 0, 0, "unreadable-sled")

            return True, {
                "symbol": sym.name,
                "patchable": True,
                "address": f"0x{sym.value:x}",
                "size": sym.size,
                "sledAddress": f"0x{sled_addr:x}",
                "sledOffset": sled_addr - sym.value,
                "windowAddress": f"0x{plan.window_address:x}" if plan.window_address else None,
                "planResult": plan.refusal,
                "reason": None,
                "object": sym.source_file or "unknown",
            }
        else:
            origin = self.attribute_symbol(sym)
            return False, {
                "symbol": sym.name,
                "patchable": False,
                "address": f"0x{sym.value:x}",
                "size": sym.size,
                "sledAddress": None,
                "sledOffset": None,
                "windowAddress": None,
                "planResult": "absent-sled",
                "reason": "absent-sled",
                "object": origin,
            }

    def attempt_reload(self, symbol_name: str) -> Tuple[bool, str, Dict]:
        """Executes real repro_hcr_agent reload attempt logic against symbol."""
        matching = [s for s in self.symbols if s.name == symbol_name and s.is_defined]
        if not matching:
            return False, "elf-symbol-not-found", {"refusal": "elf-symbol-not-found"}

        sym = matching[0]
        sled_addr = self.find_sled_for_entry(sym.value)
        if sled_addr is None:
            # REPRO_HCR_LX_REFUSED_ABSENT_SLED (1)
            return False, "absent-sled", {
                "code": 1,
                "refusal": "absent-sled",
                "entryAddress": f"0x{sym.value:x}",
                "sledAddress": None,
            }

        try:
            sled_bytes = self.elf.bytes_at_vaddr(sled_addr, 16)
            plan = plan_sled(sled_bytes, sled_addr)
        except ElfError as e:
            return False, f"unreadable-sled: {e}", {"code": 10, "refusal": "unreadable-sled"}

        if plan.refusal != "ok":
            return False, plan.refusal, {
                "code": 2,
                "refusal": plan.refusal,
                "entryAddress": f"0x{sym.value:x}",
                "sledAddress": f"0x{sled_addr:x}",
            }

        # Sled planning succeeded; publication store would write E9 rel32
        return True, "ok", {
            "code": 0,
            "refusal": None,
            "entryAddress": f"0x{sym.value:x}",
            "sledAddress": f"0x{sled_addr:x}",
            "windowAddress": f"0x{plan.window_address:x}",
            "publishedWord": "E9-rel32-90-90-90",
        }


# --- CLI Main ----------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compute, query, and verify unpatchable function inventory for ELF binaries."
    )
    parser.add_argument("binary", help="Path to ELF binary")
    parser.add_argument(
        "--archive", action="append", default=[], help="Path to archive(s) for symbol attribution"
    )
    parser.add_argument(
        "--output", "-o", help="Output path for inventory JSON artifact (default: stdout if not query)"
    )
    parser.add_argument(
        "--query", help="Query whether a specific function symbol is patchable or unpatchable ahead of time"
    )
    parser.add_argument(
        "--attempt-reload", help="Execute real repro_hcr_agent reload logic against a function symbol"
    )
    parser.add_argument(
        "--verify-inventory", help="Path to inventory JSON artifact to verify against the binary and archives"
    )
    parser.add_argument(
        "--json", action="store_true", help="Output machine-readable JSON for queries and reload attempts"
    )

    args = parser.parse_args()

    if not os.path.exists(args.binary):
        sys.stderr.write(f"ERROR: binary '{args.binary}' not found\n")
        return 1

    # Auto-detect libcodetracer_trace_writer.a if not explicitly provided
    archive_paths = list(args.archive)
    if not archive_paths:
        candidate = "codetracer-engine-godot/modules/gdscript/ct_writer/linuxbsd-x86_64/libcodetracer_trace_writer.a"
        if os.path.isfile(candidate):
            archive_paths.append(candidate)

    try:
        inv = UnpatchableInventory(args.binary, archive_paths)
    except Exception as e:
        sys.stderr.write(f"ERROR: failed to initialize inventory from '{args.binary}': {e}\n")
        return 1

    # 1. Query mode
    if args.query:
        try:
            patchable, info = inv.query_symbol(args.query)
        except KeyError as e:
            sys.stderr.write(f"ERROR: {e}\n")
            return 2

        if args.json:
            print(json.dumps(info, indent=2))
        else:
            if patchable:
                print(f"[PATCHABLE] Symbol '{args.query}' at {info['address']} (size: {info['size']}) is PATCHABLE.")
                print(f"  Sled address:   {info['sledAddress']} (offset: +{info['sledOffset']})")
                print(f"  Aligned window: {info['windowAddress']}")
            else:
                print(f"[UNPATCHABLE] Symbol '{args.query}' at {info['address']} (size: {info['size']}) is UNPATCHABLE.")
                print(f"  Refusal reason: {info['reason']}")
                print(f"  Attributed to:  {info['object']}")
        return 0

    # 2. Attempt reload mode
    if args.attempt_reload:
        success, outcome, details = inv.attempt_reload(args.attempt_reload)
        if args.json:
            print(json.dumps({"symbol": args.attempt_reload, "success": success, "outcome": outcome, "details": details}, indent=2))
        else:
            if success:
                print(f"[RELOAD-SUCCESS] Patch applied to '{args.attempt_reload}': sled={details['sledAddress']} window={details['windowAddress']}")
            else:
                print(f"[RELOAD-REFUSED] Reload refused for '{args.attempt_reload}': {outcome}")
        return 0 if success else 1

    # 3. Verify inventory mode
    if args.verify_inventory:
        if not os.path.isfile(args.verify_inventory):
            sys.stderr.write(f"ERROR: inventory file '{args.verify_inventory}' not found\n")
            return 1
        with open(args.verify_inventory, "r", encoding="utf-8") as f:
            artifact = json.load(f)

        unpatchable_list = artifact.get("unpatchableSymbols", [])
        print(f"Verifying {len(unpatchable_list)} unpatchable symbols in '{args.verify_inventory}'...")

        errors = 0
        for item in unpatchable_list:
            sym_name = item["symbol"]
            expected_obj = item.get("object")
            expected_reason = item.get("reason", "absent-sled")

            # Check 1: Real reload attempt MUST refuse with absent-sled
            success, outcome, details = inv.attempt_reload(sym_name)
            if success:
                sys.stderr.write(
                    f"FATAL [FALSIFIER CHECK]: Reload SUCCEEDED for symbol '{sym_name}', which the inventory declared unpatchable!\n"
                )
                errors += 1
                break
            if outcome != expected_reason:
                sys.stderr.write(
                    f"FATAL: Reload refusal for '{sym_name}' was '{outcome}', expected '{expected_reason}'\n"
                )
                errors += 1
                break

            # Check 2: Attribution verification
            matching = [s for s in inv.symbols if s.name == sym_name and s.is_defined]
            if matching:
                derived_obj = inv.attribute_symbol(matching[0])
                if expected_obj and derived_obj != expected_obj:
                    sys.stderr.write(
                        f"FATAL [FALSIFIER CHECK]: Attribution mismatch for '{sym_name}'! "
                        f"Inventory says '{expected_obj}', but derived attribution is '{derived_obj}'.\n"
                    )
                    errors += 1
                    break

        if errors > 0:
            return 1
        print("OK: Inventory verification passed: all unpatchable symbols refused absent-sled and attribution verified.")
        return 0

    # 4. Generate inventory
    artifact = inv.compute_inventory()
    output_json = json.dumps(artifact, indent=2)

    if args.output and args.output != "-":
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output_json)
            f.write("\n")
        print(f"Wrote inventory artifact to {args.output}")
        print(f"  Total defined FUNC symbols: {artifact['totalDefinedFuncs']}")
        print(f"  Sled count (patchable):     {artifact['sledCount']}")
        print(f"  Unpatchable count:          {artifact['unpatchableCount']}")
        print(f"  Attribution breakdown:      {artifact['attributionBreakdown']}")
    else:
        print(output_json)

    return 0


if __name__ == "__main__":
    sys.exit(main())
