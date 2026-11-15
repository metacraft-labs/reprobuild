## The embedded-path scan behind Caching-Architecture.md D4 finds a checkout
## path wherever a real toolchain puts it -- in raw bytes, in a zlib or zstd
## compressed ELF debug section, inside an `ar` member, behind a symbolic
## link, under a directory output -- and fails closed on what it cannot read.
##
## Why the compressed cases are the point: GCC compresses `.debug_*` by
## default on the toolchains reprobuild provisions, so a `-g` object names its
## checkout only inside a compressed stream; a plain byte search of it finds
## nothing (measured on the provisioned toolchain). A scan that missed it
## would let a second checkout be served the first's debug info.
##
## No mocks: the objects are compiled by the dev shell's real `gcc` with
## `-gz=zlib` / `-gz=zstd` (the gABI `ELFCOMPRESS_ZLIB` / `ELFCOMPRESS_ZSTD`
## section compression), archived by the real `ar`, and the uncompressed
## control is produced by the real `objcopy --decompress-debug-sections`. The
## one hand-made input is the corrupted object of the fail-closed case, a
## real object with bytes of its compressed section overwritten, because no
## toolchain emits a broken stream on purpose.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine/embedded_root_scan

proc sh(cmd, dir: string): tuple[output: string, code: int] =
  let res = execCmdEx(cmd, workingDir = dir)
  (res.output, res.exitCode)

proc requireOk(cmd, dir: string) =
  let res = sh(cmd, dir)
  if res.code != 0:
    raise newException(OSError, "`" & cmd & "` failed (" & $res.code & "):\n" &
      res.output)

proc needlesFor(root: string): seq[EmbeddedRootNeedle] =
  @[EmbeddedRootNeedle(label: "project", path: root)]

proc compressedSections(obj, dir: string): string =
  ## `readelf -S -W` lines of `.debug_*` sections carrying the `C`
  ## (`SHF_COMPRESSED`) flag. Columns after the index: Name Type Address Off
  ## Size ES Flg Lk Inf Al (Flg is absent when a section has no flags).
  for line in sh("readelf -S -W " & quoteShell(obj), dir).output.splitLines():
    if "]" notin line:
      continue
    let fields = line.split("]", 1)[1].splitWhitespace()
    if fields.len >= 10 and fields[0].startsWith(".debug_") and
        'C' in fields[6]:
      result.add(line & "\n")

suite "the embedded checkout-path scan sees through a real toolchain's outputs":
  var root: string

  setup:
    root = createTempDir("repro-embedded-scan-", "")
    createDir(root / "src")
    writeFile(root / "src" / "add.c",
      "int add(int a, int b) {\n    return a + b;\n}\n")

  teardown:
    if root.len > 0 and dirExists(root):
      removeDir(root)

  test "a zlib-compressed -g object names its checkout only inside the section":
    requireOk("gcc -c -O2 -g -gz=zlib -o add.o " & quoteShell(root / "src/add.c"),
      root)
    let obj = root / "add.o"
    # Vacuity guard: the section really is compressed, and the path really
    # is invisible to a plain byte search.
    check compressedSections(obj, root).len > 0
    check root notin readFile(obj)
    let finding = scanOutputForEmbeddedRoots(obj, needlesFor(root))
    checkpoint(finding.describe("project:add.o"))
    check finding.found
    check finding.label == "project"
    check "(zlib)" in finding.where
    check ".debug_" in finding.where

  test "a zstd-compressed -g object is found as well":
    ## No toolchain on this host WRITES `ELFCOMPRESS_ZSTD` sections (measured
    ## in the dev shell: binutils 2.46 "is not built with zstd support", LLVM
    ## "was not built with LLVM_ENABLE_ZSTD", and `gcc -gz=zstd` silently
    ## emits zlib), so this case assembles one, and that assembly is the only
    ## constructed input of the file: GCC's own object with its compressed
    ## `.debug_line_str` re-pointed at a stream the real `zstd` CLI made from
    ## the section's real contents (extracted by `objcopy`), behind a gABI
    ## `Elf64_Chdr` with `ch_type = ELFCOMPRESS_ZSTD`. What it proves is that
    ## the scan decodes a zstd section; the zlib cases above prove it reads
    ## what this toolchain actually writes.
    requireOk("gcc -c -O2 -g -gz=zlib -o add.o " & quoteShell(root / "src/add.c"),
      root)
    requireOk("objcopy --decompress-debug-sections add.o plain.o", root)
    requireOk("objcopy --dump-section .debug_line_str=sec.bin plain.o dumped.o",
      root)
    requireOk("zstd -19 -q -f -o sec.zst sec.bin", root)
    let expanded = readFile(root / "sec.bin")
    let stream = readFile(root / "sec.zst")
    check root in expanded                    # the section names the checkout
    var index = -1
    for line in sh("readelf -S -W add.o", root).output.splitLines():
      if ".debug_line_str" in line and "[" in line:
        index = parseInt(line.split("[", 1)[1].split("]", 1)[0].strip())
    require index > 0
    var data = readFile(root / "add.o")
    proc le(value: uint64; width: int): string =
      for i in 0 ..< width:
        result.add(char((value shr (8 * i)) and 0xff))
    proc readLe(at, width: int): uint64 =
      for i in 0 ..< width:
        result = result or (uint64(ord(data[at + i])) shl (8 * i))
    while data.len mod 8 != 0:
      data.add('\0')
    let newOffset = data.len
    data.add(le(2, 4) & le(0, 4) & le(uint64(expanded.len), 8) & le(1, 8))
    data.add(stream)
    let shoff = int(readLe(0x28, 8))
    let header = shoff + index * 64
    let patchedOffset = le(uint64(newOffset), 8)
    let patchedSize = le(uint64(24 + stream.len), 8)
    for i in 0 ..< 8:
      data[header + 24 + i] = patchedOffset[i]
      data[header + 32 + i] = patchedSize[i]
    writeFile(root / "z.o", data)
    check root notin data
    let finding = scanOutputForEmbeddedRoots(root / "z.o", needlesFor(root))
    checkpoint(finding.describe("project:z.o"))
    check finding.found
    check "(zstd)" in finding.where

  test "a legacy zlib-gnu (.zdebug) object is found as well":
    ## The pre-gABI GNU format carries no `SHF_COMPRESSED` flag: a `.zdebug*`
    ## section holding "ZLIB", a big-endian size and a zlib stream. binutils
    ## 2.46 still writes it, so a scan that looked only at the flag would
    ## call this object path-free.
    requireOk("gcc -c -O2 -g -gz=none -o add.o " &
      quoteShell(root / "src/add.c"), root)
    requireOk("objcopy --compress-debug-sections=zlib-gnu add.o gnu.o", root)
    let obj = root / "gnu.o"
    # Vacuity guard: the legacy sections exist and hide the path from a
    # plain byte search.
    check ".zdebug_" in sh("readelf -S -W gnu.o", root).output
    check root notin readFile(obj)
    let finding = scanOutputForEmbeddedRoots(obj, needlesFor(root))
    checkpoint(finding.describe("project:gnu.o"))
    check finding.found
    check "(zlib-gnu)" in finding.where
    check ".zdebug_" in finding.where

  test "an archive member's compressed debug info is found through the archive":
    requireOk("gcc -c -O2 -g -gz=zlib -o add.o " & quoteShell(root / "src/add.c"),
      root)
    requireOk("ar rcs libm.a add.o", root)
    let archive = root / "libm.a"
    check root notin readFile(archive)
    let finding = scanOutputForEmbeddedRoots(archive, needlesFor(root))
    checkpoint(finding.describe("project:libm.a"))
    check finding.found
    check "member add.o" in finding.where
    check "(zlib)" in finding.where

  test "the same object decompressed by objcopy is found in its raw bytes":
    ## An independent producer of the expanded bytes: what the scan reports
    ## for the compressed object, a plain search finds in objcopy's output.
    requireOk("gcc -c -O2 -g -gz=zlib -o add.o " & quoteShell(root / "src/add.c"),
      root)
    requireOk("objcopy --decompress-debug-sections add.o plain.o", root)
    check root in readFile(root / "plain.o")
    let finding = scanOutputForEmbeddedRoots(root / "plain.o", needlesFor(root))
    check finding.found
    check finding.where.endsWith("bytes")

  test "a prefix-mapped debug object and a no-debug object are path-free":
    ## The negative controls: what D4 must NOT refuse.
    requireOk("gcc -c -O2 -g -gz=zlib -ffile-prefix-map=" & root &
      "=. -o mapped.o " & quoteShell(root / "src/add.c"), root)
    requireOk("gcc -c -O2 -o plain.o " & quoteShell(root / "src/add.c"), root)
    requireOk("ar rcs libmapped.a mapped.o plain.o", root)
    for output in ["mapped.o", "plain.o", "libmapped.a"]:
      let finding = scanOutputForEmbeddedRoots(root / output, needlesFor(root))
      checkpoint(output & ": " & finding.describe(output))
      check not finding.found
      check finding.unscannable.len == 0

  test "a __FILE__ string is found in raw bytes":
    writeFile(root / "src" / "where.c",
      "const char *where(void) { return __FILE__; }\n")
    requireOk("gcc -c -O2 -o where.o " & quoteShell(root / "src/where.c"), root)
    let finding = scanOutputForEmbeddedRoots(root / "where.o", needlesFor(root))
    check finding.found
    check finding.where.endsWith("bytes")

  test "a symbolic link to a checkout path and a directory output are scanned":
    createDir(root / "out" / "nested")
    writeFile(root / "out" / "nested" / "clean.txt", "nothing here\n")
    createSymlink(root / "src" / "add.c", root / "out" / "nested" / "link")
    let finding = scanOutputForEmbeddedRoots(root / "out", needlesFor(root))
    checkpoint(finding.describe("project:out"))
    check finding.found
    check "link target" in finding.where
    removeFile(root / "out" / "nested" / "link")
    check not scanOutputForEmbeddedRoots(root / "out", needlesFor(root)).found

  test "a compressed section that does not decode is unscannable, not clean":
    requireOk("gcc -c -O2 -g -gz=zlib -o add.o " & quoteShell(root / "src/add.c"),
      root)
    # Overwrite the start of the largest compressed stream: find a section
    # name's offset through readelf and clobber 16 bytes after its header.
    let lines = sh("readelf -S -W add.o", root).output.splitLines()
    var offset = -1
    for line in lines:
      if ".debug_info" in line:
        let fields = line.split("]", 1)[^1].splitWhitespace()
        # Name Type Address Off Size ...
        offset = parseHexInt(fields[3])
        break
    require offset > 0
    var bytes = readFile(root / "add.o")
    for i in 0 ..< 16:
      bytes[offset + 24 + i] = '\xff'
    writeFile(root / "broken.o", bytes)
    let finding = scanOutputForEmbeddedRoots(root / "broken.o", needlesFor(root))
    checkpoint(finding.unscannable)
    check not finding.found
    check finding.unscannable.len > 0
    check "does not decode" in finding.unscannable or
      "cannot be read" in finding.unscannable

  test "the filesystem root is never a needle":
    ## Every absolute path contains `/`; a root there says nothing about a
    ## checkout and would make every record non-portable.
    check needleSpellings(@[EmbeddedRootNeedle(label: "x", path: "/")]).len == 0
    check needleSpellings(@[EmbeddedRootNeedle(label: "x",
      path: "/tmp/a/")]) == @[EmbeddedRootNeedle(label: "x", path: "/tmp/a")]
