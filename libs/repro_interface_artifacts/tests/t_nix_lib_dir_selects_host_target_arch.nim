## ``nixLibDirIn`` — the Nix-store fallback of the source library discovery —
## selects a library the host target can load, not the first one it sorts to.
##
## WHY. When no explicit prefix, dev-shell link input or Homebrew prefix names
## OpenSSL (or SQLite), discovery falls back to globbing the store for
## ``*-openssl-*`` and taking the first sorted prefix whose libdir holds the
## library. A store is not single-architecture: the CI runners' shared store
## holds i686 and aarch64 builds beside the x86-64 ones, under store names that
## differ only in their hash. In the CodeTracer CI failure recorded in
## reprobuild-pm
## ``issues/2026-10-03-source-interface-extraction-cannot-load-openssl-in-codetracer-ci.md``
## the first match was a 32-bit OpenSSL 3.6.2; it was baked as ``-L`` and
## ``-Wl,-rpath``, and the load failed with
## ``libcrypto.so.3: wrong ELF class: ELFCLASS32``.
##
## HOW. A store-shaped root in a temp directory, holding prefixes whose
## ``libssl`` is a real object-file HEADER (ELF or Mach-O, the only bytes the
## selector reads) of a chosen class and machine. The prefix that sorts first
## is always the incompatible one, so a selector that does not inspect the
## header returns it. Falsifiability (observed on macOS arm64): with the sort
## kept and the architecture filter disabled, the first five cases fail by
## returning the ``0…`` prefix, and only the unclassified-header case passes.
## The pre-fix unsorted ``walkDir`` returned whichever prefix the directory
## listed first, so it failed or passed these cases by directory order.
##
## NO MOCKS: the real selector over the real filesystem. The fake store root
## exists because the property is "skip the incompatible candidate", and the
## host's own ``/nix/store`` cannot be relied on to hold one.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

const
  sslNames = ["libssl.dylib", "libssl.3.dylib", "libssl.so", "libssl.so.3"]
  sslName = when defined(macosx): "libssl.dylib" else: "libssl.so"
  # ELF e_machine values, from the System V gABI
  # (https://www.sco.com/developers/gabi/latest/ch4.eheader.html).
  EM_386 = 0x03'u16
  EM_X86_64 = 0x3E'u16
  EM_AARCH64 = 0xB7'u16
  # Mach-O cputype values, from <mach/machine.h>.
  CPU_TYPE_X86_64 = 0x01000007'u32
  CPU_TYPE_ARM64 = 0x0100000C'u32

when hostCPU == "arm64":
  const hostMachine = EM_AARCH64
  const foreignMachine = EM_X86_64
  const hostCpuType = CPU_TYPE_ARM64
  const foreignCpuType = CPU_TYPE_X86_64
elif hostCPU == "amd64":
  const hostMachine = EM_X86_64
  const foreignMachine = EM_AARCH64
  const hostCpuType = CPU_TYPE_X86_64
  const foreignCpuType = CPU_TYPE_ARM64

proc elfHeader(elfClass: byte; machine: uint16): string =
  ## A little-endian ELF identification + ``e_machine``: ``EI_CLASS`` at
  ## byte 4 (1 = 32-bit, 2 = 64-bit), ``EI_DATA`` at 5, ``e_machine`` at 18.
  result = newString(64)
  result[0] = '\x7F'
  result[1] = 'E'
  result[2] = 'L'
  result[3] = 'F'
  result[4] = char(elfClass)
  result[5] = '\x01'                      # ELFDATA2LSB
  result[6] = '\x01'                      # EV_CURRENT
  result[18] = char(machine and 0xFF)
  result[19] = char(machine shr 8)

proc arArchive(members: openArray[(string, string)]): string =
  ## A GNU-layout ar(5) archive: the 8-byte magic, then each member as a
  ## 60-byte header (name padded to 16, decimal size at 48..57, the "`\n"
  ## end marker) and its data padded to an even offset.
  result = "!<arch>\n"
  for (name, data) in members:
    var hdr = name
    while hdr.len < 16: hdr.add(' ')
    hdr.add("0           ")             # mtime (12)
    hdr.add("0     0     ")             # uid, gid (6 + 6)
    hdr.add("100644  ")                 # mode (8)
    var size = $data.len
    while size.len < 10: size.add(' ')
    hdr.add(size)
    hdr.add("`\n")
    doAssert hdr.len == 60
    result.add(hdr)
    result.add(data)
    if data.len mod 2 == 1: result.add('\n')

proc machO64Header(cpuType: uint32): string =
  ## ``MH_MAGIC_64`` (0xFEEDFACF, stored little-endian) and ``cputype``.
  result = newString(32)
  result[0] = '\xCF'
  result[1] = '\xFA'
  result[2] = '\xED'
  result[3] = '\xFE'
  for i in 0 .. 3:
    result[4 + i] = char((cpuType shr (8 * i)) and 0xFF)

proc fatHeader(cpuTypes: openArray[uint32]): string =
  ## A universal binary: ``FAT_MAGIC`` (0xCAFEBABE) and ``nfat_arch``, then
  ## one 20-byte ``fat_arch`` per slice, all big-endian.
  proc be32(value: uint32): string =
    result = newString(4)
    for i in 0 .. 3:
      result[i] = char((value shr (8 * (3 - i))) and 0xFF)
  result = "\xCA\xFE\xBA\xBE" & be32(uint32(cpuTypes.len))
  for cpuType in cpuTypes:
    result.add(be32(cpuType) & be32(0) & be32(0) & be32(0) & be32(0))

proc nativeHeader(): string =
  ## A header of the format and machine this host's loader accepts.
  when defined(macosx): machO64Header(hostCpuType)
  else: elfHeader(2, hostMachine)

proc foreign64Header(): string =
  ## A 64-bit object of this host's format but another machine.
  when defined(macosx): machO64Header(foreignCpuType)
  else: elfHeader(2, foreignMachine)

proc addPrefix(storeRoot, name, header: string): string =
  ## Create ``<storeRoot>/<name>/lib/<libssl>`` holding ``header``; return
  ## the libdir the selector is expected to report for it.
  result = storeRoot / name / "lib"
  createDir(result)
  writeFile(result / sslName, header)

when hostCPU in ["arm64", "amd64"]:
  suite "nix store library fallback selects the host target architecture":
    test "a 32-bit library that sorts first is skipped":
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      # The CI shape: an i686 OpenSSL whose store hash sorts first.
      discard addPrefix(storeRoot, "0000-openssl-3.6.2", elfHeader(1, EM_386))
      let native = addPrefix(storeRoot, "1111-openssl-3.6.1", nativeHeader())
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == native

    test "a 64-bit library of a foreign machine that sorts first is skipped":
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      discard addPrefix(storeRoot, "0000-openssl-3.6.2", foreign64Header())
      let native = addPrefix(storeRoot, "1111-openssl-3.6.1", nativeHeader())
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == native

    test "an object in the other platform's format is skipped":
      # A Linux loader cannot map a Mach-O and dyld cannot map an ELF, even
      # when the machine matches.
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      let otherFormat =
        when defined(macosx): elfHeader(2, hostMachine)
        else: machO64Header(hostCpuType)
      discard addPrefix(storeRoot, "0000-openssl-3.6.2", otherFormat)
      let native = addPrefix(storeRoot, "1111-openssl-3.6.1", nativeHeader())
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == native

    test "a universal binary is accepted only when it carries the host cpu":
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      discard addPrefix(storeRoot, "0000-openssl-3.6.2",
        fatHeader([foreignCpuType]))
      let universal = addPrefix(storeRoot, "1111-openssl-3.6.1",
        fatHeader([foreignCpuType, hostCpuType]))
      let native = addPrefix(storeRoot, "2222-openssl-3.6.0", nativeHeader())
      # dyld picks the host slice out of a universal binary; a Linux loader
      # cannot use one at all.
      let expected = when defined(macosx): universal else: native
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == expected

    test "no loadable candidate yields no directory rather than a wrong one":
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      discard addPrefix(storeRoot, "0000-openssl-3.6.2", elfHeader(1, EM_386))
      discard addPrefix(storeRoot, "1111-openssl-3.6.1", foreign64Header())
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == ""

    test "an archive does not vouch for a foreign shared library beside it":
      # SQLite's store prefixes ship `libsqlite3.a` next to `libsqlite3.so`.
      # The archive's header cannot be classified, but the linker prefers the
      # shared object, so the directory is as foreign as its `.so`. Judged
      # name by name, the archive alone used to select the directory: an
      # armhf cross-compile on an x86-64 Nix host linked the store's x86-64
      # SQLite (`libsqlite3.so is incompatible with elf32-littlearm`).
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      let foreignDir = storeRoot / "0000-sqlite-3.51.2" / "lib"
      createDir(foreignDir)
      writeFile(foreignDir / "libsqlite3.so", foreign64Header())
      writeFile(foreignDir / "libsqlite3.a", "!<arch>\n")
      let nativeDir = storeRoot / "1111-sqlite-3.51.1" / "lib"
      createDir(nativeDir)
      writeFile(nativeDir / "libsqlite3.so", nativeHeader())
      writeFile(nativeDir / "libsqlite3.a", "!<arch>\n")
      check nixLibDirIn(storeRoot, "*-sqlite-*", SqliteLibraryNames) == nativeDir

    test "a static archive is classified by its first object member":
      # A cross-build leaves `sqlite-static-aarch64-unknown-linux-musl` in
      # the store with only a `libsqlite3.a`. The archive's own header says
      # nothing about the architecture, so the first member carrying an
      # object header decides -- after the GNU symbol table, whose data is
      # no object header. Measured 2026-10-30 on an x86-64 host: without
      # this the sorted-first store prefix was that archive, and every
      # native link died with `cannot find -lsqlite3`.
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      let foreignDir = storeRoot / "0000-sqlite-static-3.51.2" / "lib"
      createDir(foreignDir)
      writeFile(foreignDir / "libsqlite3.a", arArchive([
        ("/", "\0\0\0\1" & "\0\0\0\x44" & "sqlite3_open\0"),
        ("sqlite3.o/", foreign64Header())]))
      let nativeDir = storeRoot / "1111-sqlite-static-3.51.1" / "lib"
      createDir(nativeDir)
      writeFile(nativeDir / "libsqlite3.a", arArchive([
        ("/", "\0\0\0\1" & "\0\0\0\x44" & "sqlite3_open\0"),
        ("sqlite3.o/", nativeHeader())]))
      check nixLibDirIn(storeRoot, "*-sqlite-*", SqliteLibraryNames) == nativeDir

    test "an archive with no object member is left to the linker":
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      let tableOnly = storeRoot / "0000-sqlite-static-3.51.2" / "lib"
      createDir(tableOnly)
      writeFile(tableOnly / "libsqlite3.a", arArchive([("/", "\0\0\0\0")]))
      check nixLibDirIn(storeRoot, "*-sqlite-*", SqliteLibraryNames) == tableOnly

    test "a header the selector cannot classify is left to the linker":
      # A static archive or a linker script (glibc's libc.so is one) is not an
      # object header; rejecting it would break hosts whose layout is fine.
      let storeRoot = createTempDir("repro-nix-libdir-", "")
      defer: removeDir(storeRoot)
      let script = addPrefix(storeRoot, "0000-openssl-3.6.2",
        "/* GNU ld script */\nINPUT(libssl.so.3)\n")
      discard addPrefix(storeRoot, "1111-openssl-3.6.1", nativeHeader())
      check nixLibDirIn(storeRoot, "*-openssl-*", sslNames) == script
