## The object check of a cross build: every native object a build stages for
## ``--target=<triple>`` must be an object for that triple.
##
## CLI/build.md §"Cross Targets: `--target`", "Every staged native object is
## checked against the triple" (ReproOS-Add-On-Mode A15; approved by Zahary
## Karadjov, 2026-10-30). The constructor refusal
## (``requireCrossTargetConsulted``) stops the stdlib constructors that do
## not thread a target; this module checks the BYTES, so an edge a recipe
## wrote itself (``shell``, a raw ``buildAction``) that compiled for the host
## is refused too. It runs where a target mirror is written
## (``repro-install-mirror-publish --check-target``), in the engine before an
## action tagged for publication counts as succeeded under ``--target`` (so
## nothing reaches a store or a binary cache under a target identity
## unchecked), and where a mirror is consumed (the tool-profile sibling
## resolver).
##
## Formats, by their leading bytes:
##
## * ELF -- ``e_ident[EI_CLASS]``, ``e_ident[EI_DATA]``, ``e_machine`` and,
##   for ARM, the ``EF_ARM_ABI_FLOAT_*`` bits of ``e_flags``
##   (https://refspecs.linuxfoundation.org/elf/gabi4+/ch4.eheader.html;
##   ARM ELF ABI, "ELF Header" e_flags:
##   https://github.com/ARM-software/abi-aa/blob/main/aaelf32/aaelf32.rst);
##   on a Linux triple ``EI_OSABI`` must be System V or GNU, and a
##   ``PT_INTERP`` loader must belong to the triple's C library (glibc's
##   ``ld-linux*``, musl's ``ld-musl-*``).
## * ``ar`` archives (``!<arch>\n``), System V/GNU and BSD member naming
##   (https://www.freebsd.org/cgi/man.cgi?query=ar&sektion=5); every member
##   is classified as a file of its own. A thin archive's members live
##   outside the archive, so it is refused rather than followed.
## * Mach-O, thin and fat (``mach-o/loader.h``, ``mach-o/fat.h``) and PE
##   (``MZ`` + ``PE\0\0`` at ``e_lfanew``,
##   https://learn.microsoft.com/windows/win32/debug/pe-format): never an
##   object for a Linux target.
## * LLVM bitcode (``BC\xC0\xDE`` and its wrapper): refused under a target,
##   because its triple is not decoded here.
##
## A symlink in a staged tree is resolved inside that tree: an absolute target
## is the path the link will name once installed, so it is read under the
## staged root, never on the build host, and a link that climbs out of the
## root is refused unread. Everything else -- scripts, text, data, compressed
## objects such as ``.ko.xz`` -- is out of scope and passes. Pure ``std`` on
## purpose: the build engine, the install-mirror publisher and the resolver
## all import it and each keeps a narrow import closure.

import std/[algorithm, os, strutils, times]

type
  TargetOsFamily* = enum
    tofLinux, tofDarwin, tofWindows, tofOther

  ArmFloatAbi* = enum
    afaNotArm, afaHard, afaSoft

  TargetLibc* = enum
    ## The C library a Linux triple's dynamically linked images load
    ## through, as its ABI field names it. ``tlcOther`` checks nothing.
    tlcOther, tlcGnu, tlcMusl

  TargetObjectRule* = object
    ## What a native object must carry to belong to ``triple``.
    triple*: string
    machine*: uint16          ## ``e_machine``
    machineName*: string
    elfClass*: uint8          ## 1 = ELFCLASS32, 2 = ELFCLASS64
    elfData*: uint8           ## 1 = ELFDATA2LSB, 2 = ELFDATA2MSB
    os*: TargetOsFamily
    armFloat*: ArmFloatAbi
    libc*: TargetLibc

  UnknownTargetCpu* = object of ValueError
    ## The triple names a CPU this check has no rule for. Refused rather
    ## than left unchecked (fail closed).

  TargetObjectMismatch* = object of ValueError
    ## A staged tree holds a native object that is not for the triple.

const
  EM_386 = 3'u16
  EM_ARM = 40'u16
  EM_X86_64 = 62'u16
  EM_AARCH64 = 183'u16
  EM_RISCV = 243'u16
  EF_ARM_ABI_FLOAT_HARD = 0x400'u32
  EF_ARM_ABI_FLOAT_SOFT = 0x200'u32
  ELFOSABI_NONE = 0'u8        ## System V; what Linux toolchains write
  ELFOSABI_GNU = 3'u8         ## ELFOSABI_LINUX; GNU extensions (IFUNC, …)

proc machineName(machine: uint16): string =
  case machine
  of EM_386: "x86 (EM_386)"
  of EM_ARM: "ARM (EM_ARM)"
  of EM_X86_64: "x86-64 (EM_X86_64)"
  of EM_AARCH64: "AArch64 (EM_AARCH64)"
  of EM_RISCV: "RISC-V (EM_RISCV)"
  else: "e_machine " & $machine

proc canonicalCpu*(cpu: string): string =
  ## One spelling per CPU family, for comparing a triple with the host.
  let c = cpu.toLowerAscii()
  if c in ["x86_64", "amd64", "x64"]: "x86_64"
  elif c in ["aarch64", "arm64"]: "aarch64"
  elif c in ["i386", "i486", "i586", "i686", "x86", "i86"]: "i386"
  elif c.startsWith("riscv64"): "riscv64"
  elif c.startsWith("arm"): "arm"
  else: c

proc tripleOs*(triple: string): TargetOsFamily =
  for part in triple.toLowerAscii().split('-'):
    if part == "linux": return tofLinux
    if part in ["darwin", "macos", "macosx", "ios"]: return tofDarwin
    if part in ["windows", "mingw32", "w64", "win32"]: return tofWindows
  tofOther

proc tripleEnv*(triple: string): string =
  ## The ABI/environment component (``gnu``, ``musleabihf``, …), or "".
  let parts = triple.toLowerAscii().split('-')
  if parts.len >= 3:
    let last = parts[^1]
    for prefix in ["gnu", "musl", "eabi", "android", "msvc", "uclibc"]:
      if last.startsWith(prefix): return last
  ""

proc hostTriple*(): string =
  ## The triple of the machine this process runs on, in the spelling the
  ## comparison below uses. Linux hosts are taken to be glibc
  ## (``gnu``/``gnueabihf``): Nim does not tell a musl host apart, and
  ## Reprobuild's supported Linux build hosts are glibc.
  let cpu = canonicalCpu(hostCPU)
  when defined(linux):
    let env = if cpu == "arm": "gnueabihf" else: "gnu"
    (if cpu == "arm": "armv7" else: cpu) & "-unknown-linux-" & env
  elif defined(macosx):
    cpu & "-apple-darwin"
  elif defined(windows):
    cpu & "-pc-windows-msvc"
  else:
    cpu & "-unknown-" & hostOS

proc isHostTriple*(triple: string): bool =
  ## A triple that names the build host itself (same CPU family, OS and
  ## ABI; the vendor field is ignored). ``--target=<host triple>`` is a
  ## native build in every respect. An empty ABI matches the host's.
  if triple.len == 0: return false
  let host = hostTriple()
  let cpu = canonicalCpu(triple.split('-')[0])
  if cpu != canonicalCpu(host.split('-')[0]): return false
  if tripleOs(triple) != tripleOs(host): return false
  let env = tripleEnv(triple)
  env.len == 0 or env == tripleEnv(host)

proc targetObjectRuleFor*(triple: string): TargetObjectRule =
  ## The rule a ``triple``'s objects are held to. Raises
  ## ``UnknownTargetCpu`` for a CPU with no row.
  let t = triple.toLowerAscii()
  result.triple = triple
  result.os = tripleOs(t)
  result.elfData = 1
  case canonicalCpu(t.split('-')[0])
  of "arm":
    result.machine = EM_ARM
    result.elfClass = 1
    result.armFloat = if tripleEnv(t).endsWith("hf"): afaHard else: afaSoft
  of "aarch64":
    result.machine = EM_AARCH64
    result.elfClass = 2
  of "x86_64":
    result.machine = EM_X86_64
    # x32 (`x86_64-*-gnux32`) is the x86-64 ISA in ELFCLASS32 images.
    result.elfClass = if tripleEnv(t).endsWith("x32"): 1 else: 2
  of "i386":
    result.machine = EM_386
    result.elfClass = 1
  of "riscv64":
    result.machine = EM_RISCV
    result.elfClass = 2
  else:
    raise newException(UnknownTargetCpu,
      "--target '" & triple & "': no object-check rule for its CPU, so its " &
      "staged objects cannot be verified; refusing rather than leaving them " &
      "unchecked (CLI/build.md §\"Cross Targets: `--target`\")")
  result.machineName = machineName(result.machine)
  if result.os == tofLinux:
    let env = tripleEnv(t)
    result.libc =
      if env.startsWith("musl"): tlcMusl
      elif env.startsWith("gnu"): tlcGnu
      else: tlcOther

# ---------------------------------------------------------------------------
# Byte reading
# ---------------------------------------------------------------------------

proc readAt(f: File; offset: int64; n: int): string =
  if n <= 0: return ""
  result = newString(n)
  f.setFilePos(offset)
  let got = f.readBuffer(addr result[0], n)
  result.setLen(max(got, 0))

proc u16(s: string; at: int; lsb: bool): uint16 =
  if lsb: uint16(ord(s[at])) or (uint16(ord(s[at + 1])) shl 8)
  else: (uint16(ord(s[at])) shl 8) or uint16(ord(s[at + 1]))

proc u32(s: string; at: int; lsb: bool): uint32 =
  if lsb:
    uint32(ord(s[at])) or (uint32(ord(s[at + 1])) shl 8) or
      (uint32(ord(s[at + 2])) shl 16) or (uint32(ord(s[at + 3])) shl 24)
  else:
    (uint32(ord(s[at])) shl 24) or (uint32(ord(s[at + 1])) shl 16) or
      (uint32(ord(s[at + 2])) shl 8) or uint32(ord(s[at + 3]))

const
  ElfMagic = "\x7fELF"
  ArMagic = "!<arch>\n"
  ThinArMagic = "!<thin>\n"
  BitcodeMagic = "BC\xC0\xDE"
  BitcodeWrapperMagic = "\xDE\xC0\x17\x0B"   ## 0x0B17C0DE, little-endian

proc isMachO(head: string): bool =
  if head.len < 8: return false
  let m = head[0 .. 3]
  if m in ["\xfe\xed\xfa\xce", "\xfe\xed\xfa\xcf",
           "\xce\xfa\xed\xfe", "\xcf\xfa\xed\xfe"]:
    return true
  if m in ["\xca\xfe\xba\xbe", "\xca\xfe\xba\xbf"]:
    # A Java class file shares 0xCAFEBABE; its next word is a version pair
    # (major >= 45), where a fat Mach-O's is a small architecture count.
    return u32(head, 4, false) < 45
  false

const
  ET_REL = 1'u16
  SHT_ARM_ATTRIBUTES = 0x70000003'u32
  TagFile = 1'u64
  TagFpArch = 10'u64
  TagAbiVfpArgs = 28'u64

type ArmAttributes = object
  hasFpArch: bool     ## ``Tag_FP_arch`` present: compiled for an FPU
  vfpArgs: int        ## ``Tag_ABI_VFP_args``; -1 when absent (= 0, base PCS)

proc uleb(s: string; pos: var int): uint64 =
  var shift = 0
  while pos < s.len:
    let b = uint64(ord(s[pos]))
    inc pos
    result = result or ((b and 0x7f) shl shift)
    if (b and 0x80) == 0: return
    shift += 7
    if shift > 63: return

proc armAttributeIsString(tag: uint64): bool =
  ## ARM IHI 0045 (addenda32, "Attribute syntax"): tags 4, 5 and 67 are
  ## NTBS; from 32 on, odd tags are NTBS and even ones ULEB128.
  ## Tag_compatibility (32) is a ULEB128 followed by an NTBS.
  tag in [4'u64, 5, 67] or (tag > 32 and (tag and 1) == 1)

proc parseArmAttributes(sec: string): ArmAttributes =
  ## The public ``aeabi`` subsection's file-scope attributes of an
  ## ``.ARM.attributes`` section (ARM IHI 0045, "Build Attributes":
  ## https://github.com/ARM-software/abi-aa/blob/main/addenda32/addenda32.rst).
  result.vfpArgs = -1
  if sec.len < 1 or sec[0] != 'A': return
  var pos = 1
  while pos + 4 <= sec.len:
    let subLen = int(u32(sec, pos, true))
    if subLen < 5 or pos + subLen > sec.len: return
    let subEnd = pos + subLen
    var p = pos + 4
    let nameEnd = sec.find('\0', p)
    if nameEnd < 0 or nameEnd >= subEnd: return
    let vendor = sec[p ..< nameEnd]
    p = nameEnd + 1
    if vendor == "aeabi":
      while p < subEnd:
        let tagStart = p
        let tag = uleb(sec, p)
        if p + 4 > subEnd: return
        let size = int(u32(sec, p, true))
        p += 4
        let blockEnd = tagStart + size
        if size < 5 or blockEnd > subEnd: return
        if tag == TagFile:
          while p < blockEnd:
            let a = uleb(sec, p)
            if a == 32:
              discard uleb(sec, p)
              let z = sec.find('\0', p)
              p = (if z < 0: blockEnd else: z + 1)
            elif armAttributeIsString(a):
              let z = sec.find('\0', p)
              p = (if z < 0: blockEnd else: z + 1)
            else:
              let v = uleb(sec, p)
              if a == TagFpArch and v != 0: result.hasFpArch = true
              elif a == TagAbiVfpArgs: result.vfpArgs = int(v)
        p = blockEnd
    pos = subEnd

proc readArmAttributes(f: File; offset, size: int64; head: string;
                       lsb: bool): ArmAttributes =
  ## Find and parse the ``SHT_ARM_ATTRIBUTES`` section of the ELF32 image
  ## at ``offset``. Absent / unreadable sections yield "no attributes".
  result.vfpArgs = -1
  let shoff = int64(u32(head, 32, lsb))
  let shentsize = int64(u16(head, 46, lsb))
  let shnum = int64(u16(head, 48, lsb))
  if shoff <= 0 or shentsize < 40 or shnum <= 0 or
      shoff + shentsize * shnum > size:
    return
  for i in 0'i64 ..< shnum:
    let sh = readAt(f, offset + shoff + i * shentsize, 40)
    if sh.len < 40: return
    if u32(sh, 4, lsb) == SHT_ARM_ATTRIBUTES:
      let at = int64(u32(sh, 16, lsb))
      let len = int64(u32(sh, 20, lsb))
      if at < 0 or len <= 0 or len > 1_048_576 or at + len > size: return
      return parseArmAttributes(readAt(f, offset + at, int(len)))

const
  PT_INTERP = 3'u32
  MaxInterpLen = 4096

proc u64(s: string; at: int; lsb: bool): uint64 =
  let lo = uint64(u32(s, at, lsb))
  let hi = uint64(u32(s, at + 4, lsb))
  if lsb: lo or (hi shl 32) else: (lo shl 32) or hi

proc readInterpreter(f: File; offset, size: int64; head: string;
                     is64, lsb: bool): string =
  ## The ``PT_INTERP`` path of the ELF image at ``offset``, or "" when it has
  ## none (a static executable, a relocatable object, most shared objects).
  ## Program-header layout: gABI "Program Header"
  ## (https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html).
  let phoff = if is64: int64(u64(head, 32, lsb)) else: int64(u32(head, 28, lsb))
  let phentsize = int64(u16(head, if is64: 54 else: 42, lsb))
  let phnum = int64(u16(head, if is64: 56 else: 44, lsb))
  let need = if is64: 56'i64 else: 32'i64
  if phoff <= 0 or phentsize < need or phnum <= 0 or
      phoff + phentsize * phnum > size:
    return ""
  for i in 0'i64 ..< phnum:
    let ph = readAt(f, offset + phoff + i * phentsize, int(need))
    if ph.len < int(need): return ""
    if u32(ph, 0, lsb) != PT_INTERP: continue
    let at = if is64: int64(u64(ph, 8, lsb)) else: int64(u32(ph, 4, lsb))
    let len = if is64: int64(u64(ph, 32, lsb)) else: int64(u32(ph, 16, lsb))
    if at < 0 or len <= 0 or len > MaxInterpLen or at + len > size:
      return ""
    return readAt(f, offset + at, int(len)).strip(chars = {'\0'},
      leading = false)
  ""

proc interpreterProblem(interp: string; rule: TargetObjectRule): string =
  ## Why a dynamically linked image's loader does not belong to the triple's
  ## C library, or "". glibc's loaders are ``ld-linux*.so.*`` (``ld64.so.*``
  ## on some 64-bit ports); musl's are ``ld-musl-<arch>.so.1``
  ## (https://wiki.musl-libc.org/guidelines-for-distributions.html).
  if interp.len == 0 or rule.libc == tlcOther: return ""
  let base = interp.extractFilename()
  let isMusl = base.startsWith("ld-musl-")
  let isGlibc = base.startsWith("ld-linux") or base.startsWith("ld64.so") or
    base.startsWith("ld.so")
  case rule.libc
  of tlcMusl:
    if not isMusl:
      return "loads through " & interp & ", the triple is musl (ld-musl-*)"
  of tlcGnu:
    if not isGlibc:
      return "loads through " & interp & ", the triple is glibc (ld-linux*)"
  of tlcOther: discard
  ""

proc checkElf(f: File; offset, size: int64; head: string;
              rule: TargetObjectRule): string =
  ## "" when the ELF image at ``offset`` fits ``rule``, else why.
  if head.len < 52:
    return "truncated ELF header"
  let cls = uint8(ord(head[4]))
  let data = uint8(ord(head[5]))
  if data notin [1'u8, 2'u8]:
    return "ELF with an invalid EI_DATA " & $data
  let lsb = data == 1
  let machine = u16(head, 18, lsb)
  var problems: seq[string]
  if machine != rule.machine:
    problems.add(machineName(machine) & ", the triple needs " &
      rule.machineName)
  if cls != rule.elfClass:
    problems.add("ELFCLASS" & (if cls == 1: "32" elif cls == 2: "64" else: $cls) &
      ", the triple needs ELFCLASS" & (if rule.elfClass == 1: "32" else: "64"))
  if data != rule.elfData:
    problems.add((if lsb: "little" else: "big") & "-endian, the triple needs " &
      (if rule.elfData == 1: "little" else: "big") & "-endian")
  if rule.os == tofLinux:
    let osabi = uint8(ord(head[7]))
    if osabi notin [ELFOSABI_NONE, ELFOSABI_GNU]:
      problems.add("EI_OSABI " & $osabi & ", a Linux triple needs 0 " &
        "(System V) or 3 (GNU/Linux)")
  if problems.len == 0 and cls in [1'u8, 2'u8]:
    let why = interpreterProblem(
      readInterpreter(f, offset, size, head, cls == 2, lsb), rule)
    if why.len > 0: problems.add(why)
  if problems.len == 0 and rule.armFloat != afaNotArm:
    # The float ABI. A LINKED image (executable, shared object) carries it
    # in e_flags, which the linker sets from the target: hard-float needs
    # EF_ARM_ABI_FLOAT_HARD. A RELOCATABLE object's e_flags do not say it:
    # measured 2026-10-30 with zig 0.13 (clang), an FP-free assembly object
    # built for arm-linux-musleabihf carries EF_ARM_ABI_FLOAT_SOFT. Its
    # build attributes do: Tag_ABI_VFP_args = 1 is hard-float argument
    # passing, absent/0 is the base (soft) PCS -- which FP-free code also
    # declares, so a missing tag counts against hard-float only for an
    # object that was compiled for an FPU (Tag_FP_arch present).
    let etype = u16(head, 16, lsb)
    let flags = u32(head, 36, lsb)
    if etype == ET_REL:
      let attrs = readArmAttributes(f, offset, size, head, lsb)
      case rule.armFloat
      of afaHard:
        if attrs.vfpArgs <= 0 and attrs.hasFpArch:
          problems.add("a soft-float (base PCS) object compiled for an " &
            "FPU (Tag_ABI_VFP_args " & (if attrs.vfpArgs < 0: "absent"
            else: $attrs.vfpArgs) & "), the triple is hard-float")
      of afaSoft:
        if attrs.vfpArgs == 1:
          problems.add("a hard-float object (Tag_ABI_VFP_args: VFP " &
            "registers), the triple is soft-float")
      of afaNotArm: discard
    else:
      case rule.armFloat
      of afaHard:
        if (flags and EF_ARM_ABI_FLOAT_HARD) == 0:
          problems.add("not a hard-float image (e_flags 0x" &
            toHex(flags, 8) & " lacks EF_ARM_ABI_FLOAT_HARD), the triple " &
            "is hard-float")
        elif (flags and EF_ARM_ABI_FLOAT_SOFT) != 0:
          problems.add("an image claiming both float ABIs (e_flags 0x" &
            toHex(flags, 8) & " sets EF_ARM_ABI_FLOAT_SOFT), the triple " &
            "is hard-float")
      of afaSoft:
        if (flags and EF_ARM_ABI_FLOAT_HARD) != 0:
          problems.add("a hard-float image (e_flags 0x" & toHex(flags, 8) &
            "), the triple is soft-float")
      of afaNotArm: discard
  problems.join("; ")

proc checkBlob(f: File; offset, size: int64; rule: TargetObjectRule;
               where: string; acc: var seq[string]; depth = 0)

proc checkArchive(f: File; offset, size: int64; rule: TargetObjectRule;
                  where: string; acc: var seq[string]; depth: int) =
  var pos = offset + 8
  let stop = offset + size
  var longNames = ""
  while pos + 60 <= stop:
    let hdr = readAt(f, pos, 60)
    if hdr.len < 60 or hdr[58 .. 59] != "`\n":
      acc.add(where & ": malformed ar member header at offset " & $pos)
      return
    var name = hdr[0 .. 15].strip(leading = false)
    let memberSize = try: parseBiggestInt(hdr[48 .. 57].strip())
                     except ValueError: -1
    if memberSize < 0 or pos + 60 + memberSize > stop:
      acc.add(where & ": malformed ar member size at offset " & $pos)
      return
    var dataAt = pos + 60
    var dataSize = memberSize
    if name.startsWith("#1/"):
      # BSD: the name is the first <n> bytes of the member data.
      let n = try: parseInt(name[3 .. ^1]) except ValueError: -1
      if n < 0 or n > dataSize:
        acc.add(where & ": malformed BSD ar name at offset " & $pos)
        return
      name = readAt(f, dataAt, n).strip(chars = {'\0'}, leading = false)
      dataAt += n
      dataSize -= n
    if name == "//":
      longNames = readAt(f, dataAt, int(dataSize))
    elif name in ["/", "/SYM64/"] or name.startsWith("__.SYMDEF"):
      discard
    else:
      if name.startsWith("/") and name.len > 1 and name[1] in Digits:
        let at = try: parseInt(name[1 .. ^1]) except ValueError: -1
        if at >= 0 and at < longNames.len:
          var e = longNames.find('\n', at)
          if e < 0: e = longNames.len
          name = longNames[at ..< e]
      name.removeSuffix('/')
      checkBlob(f, dataAt, dataSize, rule, where & "(" & name & ")", acc,
        depth + 1)
    pos = pos + 60 + memberSize
    if (pos and 1) == 1: inc pos

proc checkBlob(f: File; offset, size: int64; rule: TargetObjectRule;
               where: string; acc: var seq[string]; depth = 0) =
  ## Classify the ``size`` bytes at ``offset`` and append a line to ``acc``
  ## for each native object in them that does not fit ``rule``.
  if size < 4: return
  let head = readAt(f, offset, int(min(size, 64'i64)))
  if head.startsWith(ElfMagic):
    if rule.os == tofDarwin or rule.os == tofWindows:
      acc.add(where & ": an ELF object, the triple is not an ELF platform")
      return
    let why = checkElf(f, offset, size, head, rule)
    if why.len > 0: acc.add(where & ": " & why)
  elif head.startsWith(ArMagic):
    if depth > 4:
      acc.add(where & ": archives nested too deeply")
    else:
      checkArchive(f, offset, size, rule, where, acc, depth)
  elif head.startsWith(ThinArMagic):
    acc.add(where & ": a thin archive; its members live outside the staged " &
      "tree and cannot be checked")
  elif head.startsWith(BitcodeMagic) or head.startsWith(BitcodeWrapperMagic):
    # LLVM bitcode (an LTO object, or one inside an archive). Its target
    # triple is a record of the bitstream's MODULE_BLOCK
    # (https://llvm.org/docs/BitCodeFormat.html), which this module does not
    # decode; an unverified object is refused rather than passed.
    acc.add(where & ": LLVM bitcode, whose target triple this check does " &
      "not decode; refused under --target rather than left unverified")
  elif isMachO(head):
    if rule.os != tofDarwin:
      acc.add(where & ": a Mach-O image, the triple is not a Darwin target")
  elif head.startsWith("MZ") and size >= 0x40:
    let peAt = int64(u32(readAt(f, offset + 0x3c, 4) & "\0\0\0\0", 0, true))
    if peAt >= 0x40 and peAt + 4 <= size and
        readAt(f, offset + peAt, 4) == "PE\0\0":
      if rule.os != tofWindows:
        acc.add(where & ": a PE image, the triple is not a Windows target")

proc targetObjectMismatchesInFile*(path: string; rule: TargetObjectRule;
                                   display = ""): seq[string] =
  ## Every mismatch in the file at ``path`` (one line each); empty when it
  ## is not a native object or fits ``rule``.
  var f: File
  if not open(f, path, fmRead):
    return @[(if display.len > 0: display else: path) & ": cannot be read"]
  try:
    checkBlob(f, 0, getFileSize(f), rule,
      if display.len > 0: display else: path, result)
  finally:
    close(f)

const MaxSymlinkHops = 40

proc resolveInStagedRoot*(root, rel: string): tuple[rel: string; ok: bool] =
  ## Resolve ``rel`` under the staged tree ``root`` without ever leaving it.
  ## Each symlink met on the way is read and followed RELATIVE TO ``root``:
  ## an absolute link target names the path it will have once the tree is
  ## installed (a DESTDIR-style staging tree), so ``/usr/lib/x`` resolves to
  ## ``<root>/usr/lib/x``, never to the build host's ``/usr/lib/x``. A ``..``
  ## that would climb above ``root``, or a chain of more than
  ## ``MaxSymlinkHops`` links, is ``ok = false``.
  var pending = rel.replace('\\', '/').split('/')
  var resolved: seq[string]
  var hops = 0
  while pending.len > 0:
    let c = pending[0]
    pending.delete(0)
    if c.len == 0 or c == ".": continue
    if c == "..":
      if resolved.len == 0: return ("", false)
      resolved.setLen(resolved.len - 1)
      continue
    let candidate = root / (resolved & @[c]).join("/")
    if symlinkExists(candidate):
      inc hops
      if hops > MaxSymlinkHops: return ("", false)
      let target = expandSymlink(candidate).replace('\\', '/')
      if target.startsWith("/"): resolved.setLen(0)
      pending = target.split('/') & pending
    else:
      resolved.add(c)
  (resolved.join("/"), true)

proc treeMismatches(root: string; rule: TargetObjectRule;
                    display: string): seq[string] =
  ## Every mismatch under the staged tree ``root``. Regular files are read
  ## in place; a symlink is resolved by ``resolveInStagedRoot`` and its
  ## target read only when that lands on a regular file inside ``root``. A
  ## link that leaves the tree is a mismatch line (its target is not read);
  ## a dangling link, or one naming a directory, is skipped.
  let prefix = if display.len > 0: display & "/" else: ""
  for rel in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile,
                        pcLinkToDir}, relative = true, skipSpecial = true):
    let shown = prefix & rel.replace('\\', '/')
    let abs = root / rel
    if not symlinkExists(abs):
      result.add(targetObjectMismatchesInFile(abs, rule, shown))
      continue
    let (target, ok) = resolveInStagedRoot(root, rel)
    if not ok:
      result.add(shown & ": a symlink leading outside the staged tree (-> " &
        expandSymlink(abs) & "); not followed")
      continue
    let resolvedAbs = root / target
    if fileExists(resolvedAbs) and not symlinkExists(resolvedAbs):
      result.add(targetObjectMismatchesInFile(resolvedAbs, rule, shown))

proc targetObjectMismatches*(root, triple: string): seq[string] =
  ## Every mismatch under the staged tree ``root`` against ``triple``,
  ## sorted by path. Raises ``UnknownTargetCpu``.
  let rule = targetObjectRuleFor(triple)
  if not dirExists(root):
    return
  result = treeMismatches(root, rule, "")
  result.sort()

proc targetObjectMismatchesInPaths*(paths: openArray[string];
                                    triple: string): seq[string] =
  ## Every mismatch in ``paths`` -- an action's declared outputs, each a
  ## file or a directory tree -- against ``triple``, sorted. A directory is
  ## its own staged root; a file is checked in place, and a file that is a
  ## symlink is resolved with its directory as the root. Absent paths are
  ## skipped (an action's optional outputs). Raises ``UnknownTargetCpu``.
  let rule = targetObjectRuleFor(triple)
  for path in paths:
    if dirExists(path) and not symlinkExists(path):
      result.add(treeMismatches(path, rule, path))
    elif symlinkExists(path):
      let dir = path.parentDir()
      let (target, ok) = resolveInStagedRoot(dir, path.extractFilename())
      if not ok:
        result.add(path & ": a symlink leading outside its directory (-> " &
          expandSymlink(path) & "); not followed")
      elif fileExists(dir / target) and not symlinkExists(dir / target):
        result.add(targetObjectMismatchesInFile(dir / target, rule, path))
    elif fileExists(path):
      result.add(targetObjectMismatchesInFile(path, rule, path))
  result.sort()

proc refuseTargetObjectMismatches*(found: seq[string];
                                   root, triple, context: string) =
  ## Raise ``TargetObjectMismatch`` naming every line of ``found`` (a scan
  ## of the staged tree ``root`` against ``triple``) when it is not empty.
  if found.len == 0: return
  var msg = context & ": " & $found.len & " staged object(s) under " & root &
    " are not for --target '" & triple & "' (CLI/build.md §\"Cross " &
    "Targets: `--target`\", the object check):"
  for line in found:
    msg.add("\n  " & line)
  raise newException(TargetObjectMismatch, msg)

proc refuseTargetObjectMismatches*(root, triple, context: string) =
  ## Raise ``TargetObjectMismatch`` naming every offending path when the
  ## staged tree ``root`` holds an object that is not for ``triple``.
  refuseTargetObjectMismatches(targetObjectMismatches(root, triple), root,
    triple, context)

proc objectCheckTripleFromVariants*(raw: string): string =
  ## The triple a build's published outputs are checked against, from a
  ## ``REPRO_VARIANTS`` value (``name=value`` pairs, comma separated; the
  ## channel ``repro build --target`` writes and the stdlib reads), or ""
  ## for a native build: no ``targetTriple``, ``native``, or the build
  ## host's own triple. The last assignment wins, as it does for the
  ## stdlib's reader.
  for item in raw.split(','):
    let kv = item.split('=', 1)
    if kv.len == 2 and kv[0].strip() == "targetTriple":
      result = kv[1].strip()
  if result.len == 0 or result.toLowerAscii() == "native" or
      isHostTriple(result):
    result = ""

proc stagedTreeStatFingerprint*(root: string): string =
  ## A fingerprint of the staged tree ``root`` from ``lstat`` alone: every
  ## entry's relative path, kind, size and modification time, in sorted
  ## order, links not followed (a link contributes its own target string).
  ## Two equal fingerprints mean the tree was not rewritten in between, so a
  ## scan of it can be reused; any write, rename, removal or relink changes
  ## it. Cheap next to the scan it guards, which reads every native object.
  var rows: seq[string]
  if not dirExists(root):
    return ""
  for rel in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir,
                        pcLinkToDir}, relative = true, skipSpecial = true):
    let abs = root / rel
    if symlinkExists(abs):
      rows.add(rel & "\0L\0" & expandSymlink(abs))
    else:
      let info = getFileInfo(abs, followSymlink = false)
      rows.add(rel & "\0" & $info.kind & "\0" & $info.size & "\0" &
        $info.lastWriteTime.toUnix() & "." &
        $info.lastWriteTime.nanosecond())
  rows.sort()
  rows.join("\n")

type
  TargetObjectScanMemo* = object
    ## Scans of staged trees, keyed by (root, triple) and valid while the
    ## tree's ``stagedTreeStatFingerprint`` is unchanged. Owned by the
    ## caller, so its lifetime is the caller's (one resolution session).
    entries: seq[tuple[root, triple, fingerprint: string;
                       found: seq[string]]]

proc targetObjectMismatches*(memo: var TargetObjectScanMemo;
                             root, triple: string): seq[string] =
  ## ``targetObjectMismatches(root, triple)``, answered from ``memo`` when
  ## the tree has not changed since it was last scanned.
  let fingerprint = stagedTreeStatFingerprint(root)
  for entry in memo.entries:
    if entry.root == root and entry.triple == triple and
        entry.fingerprint == fingerprint:
      return entry.found
  result = targetObjectMismatches(root, triple)
  for entry in memo.entries.mitems:
    if entry.root == root and entry.triple == triple:
      entry.fingerprint = fingerprint
      entry.found = result
      return
  memo.entries.add((root, triple, fingerprint, result))

# ---------------------------------------------------------------------------
# Declared exemptions
# ---------------------------------------------------------------------------

type
  TargetObjectExemption* = object
    ## A path a recipe declares to hold a foreign-architecture object it
    ## ships on purpose (an ``EM_BPF`` program, device firmware), with why.
    ## Declared one path at a time with a reason; there is no pattern and no
    ## implicit allowlist (CLI/build.md §"Cross Targets: `--target`").
    path*: string    ## relative to the installed prefix, ``/``-separated
    reason*: string

const TargetObjectExemptionsEnvVar* = "REPRO_TARGET_OBJECT_EXEMPTIONS"
  ## The channel a package's exemptions travel to every action it emits:
  ## one ``<path>\t<reason>`` per line. Part of each action's environment,
  ## and so of its identity: changing an exemption changes the cache key.

proc validateTargetObjectExemption*(e: TargetObjectExemption) =
  ## Raise ``ValueError`` for an exemption that is not one relative path
  ## with a reason.
  if e.reason.strip().len == 0:
    raise newException(ValueError, "target object exemption '" & e.path &
      "' has no reason; an exemption must say why the object is foreign")
  if e.path.len == 0 or e.path.startsWith("/") or '\\' in e.path:
    raise newException(ValueError, "target object exemption '" & e.path &
      "' must be one /-separated path relative to the installed prefix")
  for c in e.path & e.reason:
    if c in {'\0', '\t', '\n', '\r'}:
      raise newException(ValueError, "target object exemption '" & e.path &
        "' holds a control character")
  for part in e.path.split('/'):
    if part in ["", ".", ".."] or '*' in part or '?' in part or '[' in part:
      raise newException(ValueError, "target object exemption '" & e.path &
        "' must name one path: no empty, '.', '..' or wildcard components")

proc encodeTargetObjectExemptions*(es: openArray[TargetObjectExemption]):
    string =
  var lines: seq[string]
  for e in es:
    validateTargetObjectExemption(e)
    lines.add(e.path & "\t" & e.reason)
  lines.join("\n")

proc decodeTargetObjectExemptions*(raw: string): seq[TargetObjectExemption] =
  ## Raises ``ValueError`` on a malformed line rather than dropping it: an
  ## exemption that cannot be read must not silently widen or narrow.
  for line in raw.split('\n'):
    if line.len == 0: continue
    let tab = line.find('\t')
    if tab < 1:
      raise newException(ValueError, TargetObjectExemptionsEnvVar &
        ": malformed entry '" & line & "'")
    let e = TargetObjectExemption(path: line[0 ..< tab],
                                  reason: line[tab + 1 .. ^1])
    validateTargetObjectExemption(e)
    result.add(e)

proc mismatchPath(line: string): string =
  ## The path a mismatch line names: before ``(`` (an archive member) or
  ## ``: `` (the reason), whichever comes first.
  var stop = line.find(": ")
  if stop < 0: stop = line.len
  let paren = line.find('(')
  if paren >= 0 and paren < stop: stop = paren
  line[0 ..< stop]

proc namesExemptPath(shown, exempt: string): bool =
  ## Whether the reported path ``shown`` is ``exempt``, matched on whole
  ## path components at the end (a mirror reports ``usr/lib/x``, the engine
  ## an absolute output path ending in it).
  let s = shown.replace('\\', '/')
  s == exempt or s.endsWith("/" & exempt)

proc applyTargetObjectExemptions*(found: seq[string];
                                  exemptions: openArray[TargetObjectExemption];
                                  requireUse: bool): seq[string] =
  ## ``found`` without the lines an exemption covers. With ``requireUse`` --
  ## where the scan saw the package's whole staged tree, i.e. the mirror --
  ## an exemption that covered no line is reported as stale: it names
  ## nothing the check refuses, so it must be removed rather than linger as a
  ## silent allowance for whatever lands there next.
  var used = newSeq[bool](exemptions.len)
  for line in found:
    let shown = mismatchPath(line)
    var covered = false
    for i, e in exemptions:
      if namesExemptPath(shown, e.path):
        covered = true
        used[i] = true
    if not covered:
      result.add(line)
  if requireUse:
    for i, e in exemptions:
      if not used[i]:
        result.add(e.path & ": declared exempt from the object check (" &
          e.reason & ") but holds nothing the check refuses; remove the " &
          "exemption")
  result.sort()

# ---------------------------------------------------------------------------
# The publication gate: a prefix published under another platform's identity
# ---------------------------------------------------------------------------

proc isHostPlatform*(cpu, os: string): bool =
  ## Whether a cache identity's platform names the build host's CPU family
  ## and OS (the ABI and libc fields are the consumer's conventions and do
  ## not change which objects a host build produces).
  let host = hostTriple()
  canonicalCpu(cpu) == canonicalCpu(host.split('-')[0]) and
    tripleOs(cpu & "-unknown-" & os) == tripleOs(host)

proc targetObjectRuleForPlatform*(cpu, os, abi, libcVariant: string):
    TargetObjectRule =
  ## The rule a prefix published under the platform (``cpu``, ``os``,
  ## ``abi``, ``libcVariant``) of a cache identity is held to. Raises
  ## ``UnknownTargetCpu`` for a CPU with no rule. The identity's ABI field
  ## is the CONSUMER's convention (a static-musl armhf binary is published as
  ## ``armv7 / linux / gnu / ""`` for a glibc Raspberry Pi; Binary-Caches.md
  ## §"Publishing for a host that cannot build"), so the ARM float ABI is
  ## checked only when that field states it (``…hf`` hard, ``…eabi`` soft),
  ## and the loader only when the libc field names glibc or musl.
  result = targetObjectRuleFor(cpu & "-unknown-" & os &
    (if abi.len > 0: "-" & abi else: ""))
  if result.machine == EM_ARM:
    let a = abi.toLowerAscii()
    result.armFloat =
      if a.endsWith("hf"): afaHard
      elif a.endsWith("eabi"): afaSoft
      else: afaNotArm
  let libc = libcVariant.toLowerAscii()
  result.libc =
    if result.os != tofLinux: tlcOther
    elif libc.startsWith("glibc"): tlcGnu
    elif libc.startsWith("musl"): tlcMusl
    else: tlcOther

proc targetObjectMismatchesForPublication*(prefix, cpu, os, abi,
                                           libcVariant: string;
    exemptions: openArray[TargetObjectExemption] = []): seq[string] =
  ## The publication gate (CLI/build.md §"Cross Targets: `--target`"):
  ## every mismatch in ``prefix`` against the platform it is about to be
  ## published under, or @[] when that platform is the build host's (a host
  ## prefix may legitimately carry another target's objects, e.g. a
  ## ``rust-std`` component) or names no CPU (``""`` / ``any``: data).
  ## Raises ``UnknownTargetCpu`` for a non-host CPU with no rule.
  if cpu.len == 0 or cpu.toLowerAscii() in ["any", "noarch", "all"] or
      isHostPlatform(cpu, os):
    return
  let rule = targetObjectRuleForPlatform(cpu, os, abi, libcVariant)
  var found: seq[string]
  if dirExists(prefix) and not symlinkExists(prefix):
    found = treeMismatches(prefix, rule, "")
  elif fileExists(prefix):
    found = targetObjectMismatchesInFile(prefix, rule, prefix.extractFilename)
  applyTargetObjectExemptions(found, exemptions, requireUse = false)
