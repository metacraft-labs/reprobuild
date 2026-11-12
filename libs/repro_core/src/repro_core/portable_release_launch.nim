## Running the helpers a portable Linux release compiles for itself.
##
## The portable Linux release archive (`scripts/release/
## write_posix_loader_launcher.sh`) runs every `bin/.<app>.real` through the
## glibc loader it bundles in `<prefix>/lib`, with `--library-path
## <prefix>/lib`. Its libraries — `libclingo.so`, `libzstd.so.1`, the
## `libstdc++.so.6` clingo needs — were built against that bundled glibc, and
## their own RUNPATHs name build-host store directories that do not exist on
## the target. Only the explicit `--library-path` makes them loadable.
##
## The interface-extract runner and the provider binary are different: the
## engine compiles them on the target with the host's C compiler, so they are
## linked against the HOST glibc and carry the host's `PT_INTERP`. With no
## clingo prefix on the host, the engine links them with a `$ORIGIN` RUNPATH
## and copies `libclingo.so` / `libzstd.so.1` beside them
## (`repro_interface_artifacts.portableReleaseRpathFlags` and
## `stagePortableReleaseLibraries`). Run directly, that copy loads only when the
## host's glibc and libstdc++ are at least as new as the bundled ones: on
## Debian bookworm (glibc 2.36, GCC 12) clingo's `GLIBC_2.38`,
## `GLIBCXX_3.4.32` and `CXXABI_1.3.15` references are unresolvable and the
## helper dies at module init with `could not load: libclingo.so`.
##
## So such a helper is started the way the launcher starts the engine: through
## the bundled loader, with `--library-path` naming the release's lib
## directory. `--library-path` governs every object's dependencies, including
## the ones a `dlopen`ed library's own RUNPATH cannot find; a link-time
## `--dynamic-linker` plus RUNPATH does not (a RUNPATH applies only to the
## object that carries it, and `libclingo.so`'s names build-host directories).
## Nothing is baked into the helper: the loader and directory are those of the
## release that is running NOW, so a helper compiled by a release that has since
## moved or been replaced still starts.
##
## A glibc binary runs on a NEWER glibc, which is what the bundled one is on
## every host older than it. The bound: a helper linked on a host whose glibc is
## NEWER than the bundled one fails under the bundled loader if it references a
## symbol version the bundled glibc lacks (`version 'GLIBC_2.xx' not found`).
## The bundled loader does not search the host's library directories or read
## its `/etc/ld.so.cache`, so the helper must need nothing beyond the C library
## and what the release's lib directory ships; the provider and runner link
## only the C library family, and clingo / zstd are `dlopen`ed by leaf name.
##
## Which helpers: only an ELF whose RUNPATH carries the `$ORIGIN` entry that
## `portableReleaseRpathFlags` writes. That entry is written only when the
## release must supply clingo, so a helper linked against a host or Nix clingo
## prefix keeps the loader and libraries it was linked for. `$ORIGIN` is the
## marker on purpose: the helpers of every release since that flag was
## introduced carry it, so this engine starts those correctly too.

import std/[os, strutils]

const PortableReleaseHelperRunpathMarker* = "$ORIGIN"
  ## The RUNPATH entry `portableReleaseRpathFlags` links into a helper when
  ## only the portable release can supply clingo.

proc portableReleaseLibDirFor*(imageDir: string;
                               probe: proc(path: string): bool): string =
  ## ``imageDir`` when it is the private libdir of a Linux portable release
  ## archive, else "". See `portableReleaseLibDir`.
  if imageDir.len > 0 and probe(imageDir / "libc.so.6") and
     probe(imageDir / "libclingo.so"):
    imageDir
  else:
    ""

proc portableReleaseLibDir*(): string =
  ## The private libdir of the portable Linux release archive this process
  ## runs from, else "".
  ##
  ## The launcher runs every `.real` binary through the glibc loader it
  ## bundles in `<prefix>/lib`, so `/proc/self/exe`, hence `getAppFilename()`,
  ## is that loader and its directory is the archive's private libdir. That
  ## launcher publishes no `REPROBUILD_RUNTIME_LIBRARY_PATH` and the archive
  ## ships no `include/clingo.h`, so neither the runtime RPATH nor the clingo
  ## prefix probe of the helper compile finds anything on a host without a Nix
  ## store.
  ##
  ## That directory cannot simply go into a host-linked helper's RPATH: it
  ## also holds the bundled `libc.so.6`, which the HOST loader would then map
  ## in place of the host libc the helper was linked against. The bundled libc
  ## beside clingo is what identifies the layout.
  when defined(linux):
    portableReleaseLibDirFor(parentDir(getAppFilename()),
      proc(path: string): bool = fileExists(path))
  else:
    ""

proc readAt(f: File; offset: uint64; n: int): string =
  if n <= 0 or offset > uint64(high(int64)):
    return ""
  f.setFilePos(int64(offset))
  result = newString(n)
  let got = f.readBuffer(addr result[0], n)
  result.setLen(got)

proc le16(s: string; at: int): uint64 =
  uint64(ord(s[at])) or (uint64(ord(s[at + 1])) shl 8)

proc le32(s: string; at: int): uint64 =
  for i in 0 ..< 4:
    result = result or (uint64(ord(s[at + i])) shl (8 * i))

proc le64(s: string; at: int): uint64 =
  for i in 0 ..< 8:
    result = result or (uint64(ord(s[at + i])) shl (8 * i))

proc elfRunpathEntries*(path: string): seq[string] =
  ## The entries of the DT_RUNPATH (or, absent one, DT_RPATH) of the ELF64
  ## little-endian image at ``path``, in order; empty when it has neither,
  ## when it is not such an image, or when it cannot be read. Reads only the
  ## headers, the dynamic section and the one string, so it is cheap on a
  ## large binary. Layout: the System V gABI, "Program Header" and "Dynamic
  ## Section" (https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html,
  ## https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.dynamic.html).
  const
    PtLoad = 1'u64
    PtDynamic = 2'u64
    DtNull = 0'u64
    DtStrtab = 5'u64
    DtRpath = 15'u64
    DtRunpath = 29'u64
    MaxHeaderBytes = 1 shl 16
    MaxDynamicBytes = 1 shl 20
    MaxStringBytes = 1 shl 16
  var f: File
  if not open(f, path, fmRead):
    return
  defer: f.close()
  try:
    let head = readAt(f, 0, 64)
    # ELFCLASS64, ELFDATA2LSB: the only layouts a portable Linux release ships.
    if head.len < 64 or not head.startsWith("\x7fELF") or head[4] != '\x02' or
        head[5] != '\x01':
      return
    let phOff = le64(head, 32)
    let phEntSize = int(le16(head, 54))
    let phNum = int(le16(head, 56))
    if phEntSize < 56 or phNum == 0 or phEntSize * phNum > MaxHeaderBytes:
      return
    let ph = readAt(f, phOff, phEntSize * phNum)
    if ph.len < phEntSize * phNum:
      return
    var loads: seq[tuple[offset, vaddr, filesz: uint64]] = @[]
    var dynOff, dynSize: uint64
    for i in 0 ..< phNum:
      let base = i * phEntSize
      case le32(ph, base)
      of PtLoad:
        loads.add((le64(ph, base + 8), le64(ph, base + 16), le64(ph, base + 32)))
      of PtDynamic:
        dynOff = le64(ph, base + 8)
        dynSize = le64(ph, base + 32)
      else:
        discard
    if dynSize == 0 or dynSize > uint64(MaxDynamicBytes):
      return
    let dyn = readAt(f, dynOff, int(dynSize))
    var strtab, runpath, rpath: uint64
    var haveStrtab, haveRunpath, haveRpath = false
    var pos = 0
    while pos + 16 <= dyn.len:
      let tag = le64(dyn, pos)
      let value = le64(dyn, pos + 8)
      if tag == DtNull:
        break
      case tag
      of DtStrtab: (strtab, haveStrtab) = (value, true)
      of DtRunpath: (runpath, haveRunpath) = (value, true)
      of DtRpath: (rpath, haveRpath) = (value, true)
      else: discard
      pos += 16
    if not haveStrtab or not (haveRunpath or haveRpath):
      return
    let strIndex = if haveRunpath: runpath else: rpath
    # DT_STRTAB is a virtual address; the PT_LOAD that maps it gives its file
    # offset.
    var strtabOffset: uint64
    var mapped = false
    for load in loads:
      if strtab >= load.vaddr and strtab - load.vaddr < load.filesz:
        strtabOffset = load.offset + (strtab - load.vaddr)
        mapped = true
        break
    if not mapped or strIndex > uint64(high(int32)):
      return
    let raw = readAt(f, strtabOffset + strIndex, MaxStringBytes)
    let nul = raw.find('\0')
    if nul < 0:
      return
    for entry in raw[0 ..< nul].split(':'):
      if entry.len > 0:
        result.add(entry)
  except CatchableError:
    result = @[]

proc portableReleaseHelperArgvFor*(argv: openArray[string];
                                   loader, libDir: string;
                                   runpathOf: proc(path: string): seq[string];
                                   cwd = ""): seq[string] =
  ## ``argv`` started through ``loader`` with ``--library-path libDir`` when
  ## its program is a helper linked for the portable release (its RUNPATH
  ## carries `PortableReleaseHelperRunpathMarker`), else ``argv`` unchanged.
  ## See the module documentation. ``runpathOf`` reads an image's RUNPATH
  ## entries; it is a parameter so a test can drive the decision without an
  ## archive. A relative program path is resolved against ``cwd`` (the
  ## child's working directory) for that read; the argv keeps the caller's
  ## spelling, which the loader resolves in the same directory. A bare name
  ## is left alone: the loader would search its library path for it rather
  ## than `PATH`.
  result = @argv
  if argv.len == 0 or loader.len == 0 or libDir.len == 0:
    return
  let program = argv[0]
  if '/' notin program:
    return
  let image =
    if program.isAbsolute or cwd.len == 0: program
    else: cwd / program
  if PortableReleaseHelperRunpathMarker notin runpathOf(image):
    return
  result = @[loader, "--library-path", libDir] & @argv

proc portableReleaseHelperArgv*(argv: openArray[string]; cwd = ""):
    seq[string] =
  ## `portableReleaseHelperArgvFor` for the release this process runs from:
  ## under the portable launcher `getAppFilename()` is the bundled loader
  ## itself. Outside a portable Linux release, ``argv`` unchanged.
  result = @argv
  when defined(linux):
    let libDir = portableReleaseLibDir()
    if libDir.len == 0:
      return
    let loader = getAppFilename()
    if not extractFilename(loader).startsWith("ld-"):
      return
    result = portableReleaseHelperArgvFor(argv, loader, libDir,
      elfRunpathEntries, cwd)
