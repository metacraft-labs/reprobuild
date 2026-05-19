## Synthetic ELF64 / Mach-O fixture builders used by
## `integration_launch_plan_binding_strategies`.
##
## These produce minimal but byte-correct binaries with the exact layout
## that the RUNPATH / LC_RPATH rewriters in `./elf.nim` and `./macho.nim`
## know how to walk. They are NOT general fixtures — they are the
## deterministic targets the integration gate writes bytes to and reads
## bytes from. The integration gate validates that:
##
##   1. The parser can locate PT_DYNAMIC / LC_RPATH.
##   2. The rewriter updates the embedded RUNPATH / LC_RPATH bytes
##      in-place.
##   3. The number of new RUNPATH entries equals the dep count (the
##      FS-storm avoidance assertion from the spec).
##
## A real Reprobuild realization always emits an over-long RUNPATH
## placeholder at link time and rewrites it in place; the synthetic
## builders simulate that contract.

import std/[strutils]

# ---------------------------------------------------------------------------
# ELF64 builder
# ---------------------------------------------------------------------------

const
  EiClass64 = 2'u8
  EiData2Lsb = 1'u8
  EvCurrent = 1'u8
  EmX86_64 = 62'u16
  EtExec = 2'u16
  PtDynamic = 2'u32
  PfR = 4'u32
  ShtNull = 0'u32
  ShtProgbits = 1'u32
  ShtStrtab = 3'u32
  ShtDynamic = 6'u32
  ShfAlloc = 2'u64
  DtNull = 0'u64
  DtStrtab = 5'u64
  DtStrsz = 10'u64
  DtRunpath = 29'u64

proc writeU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  for shift in [0, 8, 16, 24]:
    outp.add(byte((value shr shift) and 0xff'u32))

proc writeU64Le(outp: var seq[byte]; value: uint64) =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    outp.add(byte((value shr shift) and 0xff'u64))

proc padTo(outp: var seq[byte]; targetLen: int) =
  while outp.len < targetLen:
    outp.add(0'u8)

type
  SyntheticElfSpec* = object
    placeholderRunpath*: string      ## NUL-padded slot for in-place rewrite
    runpathSlotLen*: int             ## bytes available for new RUNPATH

proc buildSyntheticElf64*(spec: SyntheticElfSpec): seq[byte] =
  ## Build a tiny ELF64 LE x86_64 EXEC with the following layout
  ## (offsets in bytes, all decimal):
  ##
  ##   0   0x40   ELF header
  ##   0x40 0x38  PT_DYNAMIC program header
  ##   0x78 ...   PT_DYNAMIC body (5 entries: STRTAB, STRSZ, RUNPATH,
  ##              NULL, NULL)
  ##   ...        .dynstr  (1 NUL + placeholder + NUL padding)
  ##   ...        .shstrtab
  ##   ...        section headers (NULL, .dynstr, .dynamic, .shstrtab)
  ##
  ## The PT_DYNAMIC entries point at the RUNPATH offset inside .dynstr.
  ## Section headers exist so the rewriter's `.dynstr` lookup succeeds.

  doAssert spec.runpathSlotLen >= spec.placeholderRunpath.len + 1
  let slotLen = spec.runpathSlotLen

  # --- layout planning ---
  let ehdrSize = 64
  let phdrSize = 56
  let phdrOff = ehdrSize
  let dynamicOff = phdrOff + phdrSize
  let dynamicEntries = 5
  let dynamicSize = dynamicEntries * 16
  let dynstrOff = dynamicOff + dynamicSize
  # .dynstr layout: leading 0 byte (table[0] = ''), then RUNPATH slot.
  let runpathStrOff = 1                                  # offset inside .dynstr
  let dynstrSize = 1 + slotLen                           # ends NUL-padded
  let shstrtabOff = dynstrOff + dynstrSize
  # Section header string table:
  # \0 .dynstr\0 .dynamic\0 .shstrtab\0
  let shstrtab = "\x00.dynstr\x00.dynamic\x00.shstrtab\x00"
  let shstrtabSize = shstrtab.len
  let shoff = shstrtabOff + shstrtabSize
  let shentSize = 64
  let shNum = 4                                          # NULL,.dynstr,.dynamic,.shstrtab
  let shStrIndex = 3'u16
  let totalSize = shoff + shNum * shentSize

  result = newSeqOfCap[byte](totalSize)

  # --- ELF header ---
  result.add(0x7f'u8)
  result.add(byte('E'))
  result.add(byte('L'))
  result.add(byte('F'))
  result.add(EiClass64)             # ei_class = ELFCLASS64
  result.add(EiData2Lsb)            # ei_data  = ELFDATA2LSB
  result.add(EvCurrent)             # ei_version
  result.add(0'u8)                  # ei_osabi = SYSV
  for _ in 0 ..< 8: result.add(0'u8)   # padding
  result.writeU16Le(EtExec)         # e_type
  result.writeU16Le(EmX86_64)       # e_machine
  result.writeU32Le(uint32(EvCurrent))    # e_version
  result.writeU64Le(0)              # e_entry
  result.writeU64Le(uint64(phdrOff))      # e_phoff
  result.writeU64Le(uint64(shoff))        # e_shoff
  result.writeU32Le(0)              # e_flags
  result.writeU16Le(uint16(ehdrSize))     # e_ehsize
  result.writeU16Le(uint16(phdrSize))     # e_phentsize
  result.writeU16Le(1)              # e_phnum
  result.writeU16Le(uint16(shentSize))    # e_shentsize
  result.writeU16Le(uint16(shNum))        # e_shnum
  result.writeU16Le(shStrIndex)     # e_shstrndx

  doAssert result.len == ehdrSize

  # --- PT_DYNAMIC program header ---
  result.writeU32Le(PtDynamic)               # p_type
  result.writeU32Le(PfR)                     # p_flags
  result.writeU64Le(uint64(dynamicOff))      # p_offset
  result.writeU64Le(0)                       # p_vaddr
  result.writeU64Le(0)                       # p_paddr
  result.writeU64Le(uint64(dynamicSize))     # p_filesz
  result.writeU64Le(uint64(dynamicSize))     # p_memsz
  result.writeU64Le(8)                       # p_align

  doAssert result.len == dynamicOff

  # --- PT_DYNAMIC entries ---
  result.writeU64Le(DtStrtab)
  result.writeU64Le(uint64(dynstrOff))       # using file-offset as d_val
  result.writeU64Le(DtStrsz)
  result.writeU64Le(uint64(dynstrSize))
  result.writeU64Le(DtRunpath)
  result.writeU64Le(uint64(runpathStrOff))   # offset inside .dynstr
  # Pad the rest with DT_NULL entries.
  result.writeU64Le(DtNull)
  result.writeU64Le(0)
  result.writeU64Le(DtNull)
  result.writeU64Le(0)

  doAssert result.len == dynstrOff

  # --- .dynstr ---
  # The "slot" the rewriter sees is the length of the NUL-terminated
  # placeholder string at runpathStrOff. To expose `slotLen` bytes of
  # writable space we pad the placeholder out to `slotLen-1` printable
  # characters (using '_'), then add the NUL terminator. This mirrors
  # how a real linker emits a long `-Wl,-rpath,<placeholder>` slot
  # using a single oversized placeholder argument.
  result.add(0'u8)                         # empty string at index 0
  let placeholder = spec.placeholderRunpath
  for ch in placeholder: result.add(byte(ord(ch)))
  # Pad the placeholder so the rewriter sees `slotLen - 1` writable
  # bytes followed by the trailing NUL.
  for _ in 0 ..< (slotLen - placeholder.len - 1):
    result.add(byte(ord('_')))
  result.add(0'u8)
  doAssert result.len == shstrtabOff

  # --- .shstrtab ---
  for ch in shstrtab: result.add(byte(ord(ch)))
  doAssert result.len == shoff

  # --- Section headers (in the order our parser walks them) ---
  # We use sh_offset = file offset (since this is a non-loadable
  # synthetic) and sh_size = the bytes the section occupies.

  proc writeSh(outp: var seq[byte]; nameOffsetInStrtab, typ, flags, vaddr,
               offset, size: uint64) =
    outp.writeU32Le(uint32(nameOffsetInStrtab))
    outp.writeU32Le(uint32(typ))
    outp.writeU64Le(flags)
    outp.writeU64Le(vaddr)
    outp.writeU64Le(offset)
    outp.writeU64Le(size)
    outp.writeU32Le(0)            # sh_link
    outp.writeU32Le(0)            # sh_info
    outp.writeU64Le(1)            # sh_addralign
    outp.writeU64Le(0)            # sh_entsize

  # SHT_NULL
  writeSh(result, 0, ShtNull, 0, 0, 0, 0)
  # .dynstr — name at offset 1 in shstrtab (after the leading NUL),
  # because shstrtab starts "\0.dynstr\0...".
  let dynstrNameOff = 1
  let dynamicNameOff = 1 + ".dynstr\x00".len
  let shstrtabNameOff = dynamicNameOff + ".dynamic\x00".len
  writeSh(result, uint64(dynstrNameOff), ShtStrtab, ShfAlloc, 0,
    uint64(dynstrOff), uint64(dynstrSize))
  writeSh(result, uint64(dynamicNameOff), ShtDynamic, ShfAlloc, 0,
    uint64(dynamicOff), uint64(dynamicSize))
  writeSh(result, uint64(shstrtabNameOff), ShtStrtab, 0, 0,
    uint64(shstrtabOff), uint64(shstrtabSize))

  doAssert result.len == totalSize

# ---------------------------------------------------------------------------
# Mach-O 64-bit builder
# ---------------------------------------------------------------------------

const
  MhMagic64 = 0xfeedfacf'u32
  CpuTypeX8664 = 0x01000007'u32
  CpuSubtypeAll = 3'u32
  McExecute = 2'u32
  LcRpath = 0x1c'u32 or 0x80000000'u32

proc buildSyntheticMacho64*(placeholderRpath: string; slotLen: int): seq[byte] =
  ## Build a Mach-O 64-bit LE with a single LC_RPATH load command whose
  ## embedded path string is `placeholderRpath` plus NUL padding up to
  ## `slotLen` bytes total. Just enough for the rewriter to locate and
  ## rewrite the LC_RPATH in place.
  doAssert slotLen >= placeholderRpath.len + 1
  # LC_RPATH layout: cmd (u32) + cmdsize (u32) + str_offset (u32) +
  # padding to align to 8 bytes + the NUL-terminated path string +
  # zero-padding so the load command's size is a multiple of 8.
  const rpathHeaderSize = 12                    # cmd + cmdsize + lc_str union
  # Pad rpath header to 8-byte alignment (already 12, round to 16).
  const rpathHeaderPadded = 16
  var stringFieldSize = slotLen
  # Pad the whole LC_RPATH so cmdsize is a multiple of 8.
  let raw = rpathHeaderPadded + stringFieldSize
  let alignedCmdSize = ((raw + 7) div 8) * 8
  stringFieldSize += alignedCmdSize - raw
  let cmdSize = rpathHeaderPadded + stringFieldSize

  result = newSeqOfCap[byte](32 + cmdSize)

  # mach_header_64
  result.writeU32Le(MhMagic64)               # magic
  result.writeU32Le(CpuTypeX8664)            # cputype
  result.writeU32Le(CpuSubtypeAll)           # cpusubtype
  result.writeU32Le(McExecute)               # filetype
  result.writeU32Le(1)                       # ncmds
  result.writeU32Le(uint32(cmdSize))         # sizeofcmds
  result.writeU32Le(0)                       # flags
  result.writeU32Le(0)                       # reserved

  doAssert result.len == 32

  # LC_RPATH command
  result.writeU32Le(LcRpath)                 # cmd
  result.writeU32Le(uint32(cmdSize))         # cmdsize
  result.writeU32Le(uint32(rpathHeaderPadded))    # path offset inside cmd
  # Pad to 16 bytes.
  while result.len < 32 + rpathHeaderPadded:
    result.add(0'u8)
  for ch in placeholderRpath:
    result.add(byte(ord(ch)))
  # Fill remaining bytes with 0 (NUL terminator + padding).
  while result.len < 32 + cmdSize:
    result.add(0'u8)
