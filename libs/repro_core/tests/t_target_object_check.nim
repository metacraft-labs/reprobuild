## The object check of a cross build (CLI/build.md §"Cross Targets:
## `--target`", "Every staged native object is checked against the triple";
## ReproOS-Add-On-Mode A15, approved by Zahary Karadjov 2026-10-30).
##
## The ELF fixtures under `fixtures/target_object_check/` are real compiler
## output (zig 0.13 / clang and gcc; `regenerate.sh` there), not hand-made
## headers: what is under test is that the check reads what toolchains
## actually emit -- including that an FP-free hard-float assembly object
## carries the SOFT-float e_flags bit, which a check of e_flags alone would
## wrongly refuse. Only the Mach-O, PE, thin-archive and Java-class inputs
## are synthesised here, because no toolchain for them is in the dev shell
## and the check reads nothing of them beyond the magic and, for PE, the
## `e_lfanew` signature. Nothing is mocked.

import std/[os, sequtils, strutils, times, unittest]

import repro_core/target_object_check

const
  Fixtures = currentSourcePath().parentDir / "fixtures" / "target_object_check"
  ArmHf = "armv7-unknown-linux-musleabihf"
  ArmSoft = "armv7-unknown-linux-musleabi"
  X64 = "x86_64-unknown-linux-gnu"

proc fileProblems(name, triple: string): seq[string] =
  targetObjectMismatchesInFile(Fixtures / name, targetObjectRuleFor(triple),
    name)

var treeCounter = 0

proc stageTree(files: openArray[(string, string)]): string =
  ## A staged tree under a fresh temp dir: (relative path, fixture name or
  ## "=<literal bytes>").
  result = getTempDir() / ("t_target_object_check_" & $getCurrentProcessId() &
    "_" & $treeCounter)
  inc treeCounter
  for (rel, src) in files:
    createDir(parentDir(result / rel))
    if src.startsWith("="): writeFile(result / rel, src[1 .. ^1])
    else: copyFile(Fixtures / src, result / rel)

proc le32(v: int): string =
  result = newString(4)
  for i in 0 .. 3: result[i] = char((v shr (8 * i)) and 0xff)

suite "the object check against an armv7 hard-float target":
  test "a correct armv7 hard-float object, archive and shared object pass":
    for f in ["armhf.o", "armhf.a", "armhf.so"]:
      check fileProblems(f, ArmHf).len == 0

  test "FP-free hard-float assembly passes although its e_flags say soft":
    check fileProblems("armhf-asm.o", ArmHf).len == 0

  test "an x86-64 object is refused, naming the machine and class":
    let p = fileProblems("x86_64.o", ArmHf)
    check p.len == 1
    check "EM_X86_64" in p[0] and "EM_ARM" in p[0] and "ELFCLASS64" in p[0]

  test "an x86-64 member of an archive is refused by member name":
    let p = fileProblems("mixed.a", ArmHf)
    check p.len == 1
    check p[0].startsWith("mixed.a(x86_64.o): ")

  test "a soft-float object and a soft-float shared object are refused":
    let o = fileProblems("armsoft.o", ArmHf)
    check o.len == 1 and "soft-float" in o[0]
    let so = fileProblems("armsoft.so", ArmHf)
    check so.len == 1 and "EF_ARM_ABI_FLOAT_HARD" in so[0]

suite "the object check against other targets":
  test "a soft-float target refuses hard-float objects and images":
    check fileProblems("armsoft.o", ArmSoft).len == 0
    check fileProblems("armsoft.so", ArmSoft).len == 0
    check fileProblems("armhf.o", ArmSoft).len == 1
    check fileProblems("armhf.so", ArmSoft).len == 1

  test "an x86-64 target refuses every ARM object":
    check fileProblems("x86_64.o", X64).len == 0
    for f in ["armhf.o", "armhf.so", "armsoft.o"]:
      check fileProblems(f, X64).len == 1

  test "a CPU with no rule is refused, not left unchecked":
    expect UnknownTargetCpu:
      discard targetObjectRuleFor("mips-unknown-linux-gnu")

suite "formats that are never objects for a Linux target":
  test "Mach-O (thin and fat) and PE are refused; Java classes, scripts and data pass":
    let pe = "MZ" & repeat('\0', 0x3a) & le32(0x40) & "PE\0\0" & repeat('\0', 16)
    let root = stageTree([
      ("lib/thin.dylib", "=\xcf\xfa\xed\xfe" & repeat('\0', 28)),
      ("lib/fat.dylib", "=\xca\xfe\xba\xbe\0\0\0\x02" & repeat('\0', 24)),
      ("bin/tool.exe", "=" & pe),
      ("share/Main.class", "=\xca\xfe\xba\xbe\0\0\0\x41" & repeat('\0', 24)),
      ("bin/script", "=#!/bin/sh\necho hi\n"),
      ("share/data.bin", "=\0\x01\x02\x03 just data"),
      ("lib/ok.a", "armhf.a")])
    defer: removeDir(root)
    let p = targetObjectMismatches(root, ArmHf)
    check p.len == 3
    check p[0].startsWith("bin/tool.exe: a PE image")
    check p[1].startsWith("lib/fat.dylib: a Mach-O image")
    check p[2].startsWith("lib/thin.dylib: a Mach-O image")

  test "a thin archive is refused: its members are outside the tree":
    let root = stageTree([("lib/libx.a", "=!<thin>\n")])
    defer: removeDir(root)
    let p = targetObjectMismatches(root, ArmHf)
    check p.len == 1 and "thin archive" in p[0]

suite "refusal and host triples":
  test "refuseTargetObjectMismatches names every offending path":
    let root = stageTree([("usr/lib/libz.so", "x86_64.o"),
                          ("usr/lib/libgood.a", "armhf.a"),
                          ("usr/lib/libmix.a", "mixed.a")])
    defer: removeDir(root)
    try:
      refuseTargetObjectMismatches(root, ArmHf, "install mirror")
      check false
    except TargetObjectMismatch as e:
      check "2 staged object(s)" in e.msg
      check "usr/lib/libz.so: " in e.msg
      check "usr/lib/libmix.a(x86_64.o): " in e.msg
      check "libgood" notin e.msg

  test "a triple naming the build host is the host":
    check isHostTriple(hostTriple())
    check not isHostTriple("riscv64-unknown-linux-gnu")
    when defined(linux) and defined(amd64):
      check isHostTriple("x86_64-unknown-linux-gnu")
      check isHostTriple("x86_64-pc-linux-gnu")
      check not isHostTriple("x86_64-unknown-linux-musl")
      check not isHostTriple(ArmHf)

proc patchedCopy(fixture, dest: string; at: int; bytes: string) =
  ## A copy of a real fixture with ``bytes`` written at ``at``: a header
  ## field no toolchain in the dev shell writes on demand (an OS ABI other
  ## than System V, a contradictory float-ABI pair), on otherwise genuine
  ## compiler output.
  var data = readFile(Fixtures / fixture)
  for i, c in bytes: data[at + i] = c
  writeFile(dest, data)

const ArmGnuHf = "armv7-unknown-linux-gnueabihf"

suite "the loader, the OS ABI and both float flags":
  test "a dynamic image's loader must be the triple's C library's":
    check fileProblems("armhf-musl-exe", ArmHf).len == 0
    check fileProblems("armhf-glibc-exe", ArmGnuHf).len == 0
    let glibcOnMusl = fileProblems("armhf-glibc-exe", ArmHf)
    check glibcOnMusl.len == 1
    check "ld-linux-armhf.so.3" in glibcOnMusl[0] and "musl" in glibcOnMusl[0]
    let muslOnGlibc = fileProblems("armhf-musl-exe", ArmGnuHf)
    check muslOnGlibc.len == 1
    check "ld-musl-armhf.so.1" in muslOnGlibc[0] and "glibc" in muslOnGlibc[0]

  test "an image for another OS ABI is refused on a Linux triple":
    let root = stageTree(newSeq[(string, string)]())
    defer: removeDir(root)
    createDir(root)
    patchedCopy("armhf.so", root / "fbsd.so", 7, "\x09")   # ELFOSABI_FREEBSD
    let p = targetObjectMismatchesInFile(root / "fbsd.so",
      targetObjectRuleFor(ArmHf), "fbsd.so")
    check p.len == 1
    check "EI_OSABI 9" in p[0]
    patchedCopy("armhf.so", root / "gnu.so", 7, "\x03")    # ELFOSABI_GNU
    check targetObjectMismatchesInFile(root / "gnu.so",
      targetObjectRuleFor(ArmHf), "gnu.so").len == 0

  test "a hard-float image that also claims soft float is refused":
    let root = stageTree(newSeq[(string, string)]())
    defer: removeDir(root)
    createDir(root)
    # e_flags of armhf.so is 0x05000400; adding EF_ARM_ABI_FLOAT_SOFT.
    patchedCopy("armhf.so", root / "both.so", 36, le32(0x05000600))
    let p = targetObjectMismatchesInFile(root / "both.so",
      targetObjectRuleFor(ArmHf), "both.so")
    check p.len == 1
    check "EF_ARM_ABI_FLOAT_SOFT" in p[0]

suite "x32, bitcode":
  test "an x32 object is the x86-64 ISA in ELFCLASS32":
    check fileProblems("x32.o", "x86_64-unknown-linux-gnux32").len == 0
    let asX64 = fileProblems("x32.o", X64)
    check asX64.len == 1 and "ELFCLASS32" in asX64[0]
    let x64AsX32 = fileProblems("x86_64.o", "x86_64-unknown-linux-gnux32")
    check x64AsX32.len == 1 and "ELFCLASS64" in x64AsX32[0]

  test "LLVM bitcode is refused, alone and inside an archive":
    let p = fileProblems("armhf-lto.o", ArmHf)
    check p.len == 1 and "LLVM bitcode" in p[0]
    let wrapped = stageTree([("w.bc", "=\xDE\xC0\x17\x0B" & repeat('\0', 28))])
    defer: removeDir(wrapped)
    check targetObjectMismatches(wrapped, ArmHf).len == 1

suite "symlinks are resolved inside the staged root":
  test "an absolute link resolves under the root, never on the build host":
    # The host's /bin/sh is a host executable; the staged tree's is ARM.
    # Following the link on the host would report a mismatch.
    let root = stageTree([("bin/sh", "armhf.so"),
                          ("usr/lib/x86.o", "x86_64.o")])
    defer: removeDir(root)
    createSymlink("/bin/sh", root / "usr/sh-link")
    createSymlink("/usr/lib/x86.o", root / "usr/x86-link")
    createSymlink("/no/such/file", root / "usr/dangling")
    let p = targetObjectMismatches(root, ArmHf)
    check p.len == 2
    check p.anyIt(it.startsWith("usr/lib/x86.o: "))
    check p.anyIt(it.startsWith("usr/x86-link: "))
    check not p.anyIt("sh-link" in it)

  test "a link climbing out of the root is refused unread":
    let root = stageTree([("lib/a.o", "armhf.o")])
    defer: removeDir(root)
    createSymlink("../../../../../../../../bin/sh", root / "lib/escape")
    let p = targetObjectMismatches(root, ArmHf)
    check p.len == 1
    check p[0].startsWith("lib/escape: ") and "outside the staged tree" in p[0]

  test "the root itself bounds a resolution":
    let root = stageTree([("a/b.o", "armhf.o")])
    defer: removeDir(root)
    check resolveInStagedRoot(root, "a/b.o") == ("a/b.o", true)
    check resolveInStagedRoot(root, "a/../../b.o").ok == false

suite "what the engine asks":
  test "the triple a build's outputs are held to, from REPRO_VARIANTS":
    check objectCheckTripleFromVariants("") == ""
    check objectCheckTripleFromVariants("buildType=release") == ""
    check objectCheckTripleFromVariants("targetTriple=native") == ""
    check objectCheckTripleFromVariants("targetTriple=" & hostTriple()) == ""
    check objectCheckTripleFromVariants(
      "buildType=release,targetTriple=" & ArmHf) == ArmHf
    check objectCheckTripleFromVariants(
      "targetTriple=riscv64-unknown-linux-gnu,targetTriple=" & ArmHf) == ArmHf

  test "an action's outputs: a tree, a file, and a link to one":
    let root = stageTree([("tree/lib/a.o", "armhf.o"),
                          ("tree/lib/x.o", "x86_64.o"),
                          ("hello", "x86_64.o"),
                          ("good", "armhf.so")])
    defer: removeDir(root)
    createSymlink("hello", root / "hello-link")
    let p = targetObjectMismatchesInPaths(
      [root / "tree", root / "hello", root / "good", root / "hello-link",
       root / "absent"], ArmHf)
    check p.len == 3
    check p.anyIt(it.startsWith(root / "tree" & "/lib/x.o: "))
    check p.anyIt(it.startsWith(root / "hello: "))
    check p.anyIt(it.startsWith(root / "hello-link: "))

suite "the consume-time scan is reused while the tree is unchanged":
  test "a rewrite rescans; an untouched tree reuses the scan":
    let root = stageTree([("lib/a.o", "armhf.o")])
    defer: removeDir(root)
    var memo: TargetObjectScanMemo
    check targetObjectMismatches(memo, root, ArmHf).len == 0
    # Adding a host object changes the stat fingerprint: rescanned.
    copyFile(Fixtures / "x86_64.o", root / "lib/x.o")
    check targetObjectMismatches(memo, root, ArmHf).len == 1
    removeFile(root / "lib/x.o")
    check targetObjectMismatches(memo, root, ArmHf).len == 0
    # Reuse is visible only through a change the fingerprint cannot see: the
    # same size and modification time with other bytes. (Not a case a build
    # produces; it shows the memo answers instead of rescanning.)
    # (A whole-second time: `setLastModificationTime` keeps microseconds
    # only, so a nanosecond time read back could not be restored.)
    let pinned = fromUnix(1_700_000_000)
    setLastModificationTime(root / "lib/a.o", pinned)
    check targetObjectMismatches(memo, root, ArmHf).len == 0
    var bytes = readFile(root / "lib/a.o")
    bytes[18] = '\x3e'   # e_machine := EM_X86_64, same length
    writeFile(root / "lib/a.o", bytes)
    setLastModificationTime(root / "lib/a.o", pinned)
    check targetObjectMismatches(memo, root, ArmHf).len == 0
    check targetObjectMismatches(root, ArmHf).len == 1

suite "declared exemptions":
  test "an exempted path passes; an archive member under it too":
    let root = stageTree([("usr/lib/bpf/prog.o", "x86_64.o"),
                          ("usr/lib/libmix.a", "mixed.a"),
                          ("usr/bin/tool", "x86_64.o")])
    defer: removeDir(root)
    let exemptions = @[
      TargetObjectExemption(path: "usr/lib/bpf/prog.o", reason: "BPF program"),
      TargetObjectExemption(path: "usr/lib/libmix.a", reason: "test")]
    let left = applyTargetObjectExemptions(targetObjectMismatches(root, ArmHf),
      exemptions, requireUse = true)
    check left.len == 1
    check left[0].startsWith("usr/bin/tool: ")

  test "matching is on whole components at the end of the reported path":
    let found = @["/abs/out/install@t/usr/lib/fw.bin: x86-64",
                  "/abs/out/install@t/usr/lib/xfw.bin: x86-64"]
    let left = applyTargetObjectExemptions(found,
      [TargetObjectExemption(path: "usr/lib/fw.bin", reason: "firmware")],
      requireUse = false)
    check left == @["/abs/out/install@t/usr/lib/xfw.bin: x86-64"]

  test "a stale exemption is refused where the whole tree was scanned":
    let root = stageTree([("usr/lib/a.o", "armhf.o")])
    defer: removeDir(root)
    let stale = [TargetObjectExemption(path: "usr/lib/a.o", reason: "was BPF")]
    let left = applyTargetObjectExemptions(targetObjectMismatches(root, ArmHf),
      stale, requireUse = true)
    check left.len == 1
    check "holds nothing the check refuses" in left[0]
    check applyTargetObjectExemptions(targetObjectMismatches(root, ArmHf),
      stale, requireUse = false).len == 0

  test "the channel round-trips and refuses what it cannot read":
    let es = @[TargetObjectExemption(path: "usr/lib/fw/a.bin", reason: "fw"),
               TargetObjectExemption(path: "usr/lib/b.o", reason: "BPF: tc")]
    check decodeTargetObjectExemptions(encodeTargetObjectExemptions(es)) == es
    check decodeTargetObjectExemptions("").len == 0
    expect ValueError: discard decodeTargetObjectExemptions("no-tab-here")
    for bad in [TargetObjectExemption(path: "usr/lib/a.o", reason: " "),
                TargetObjectExemption(path: "/usr/lib/a.o", reason: "x"),
                TargetObjectExemption(path: "usr/../etc/a", reason: "x"),
                TargetObjectExemption(path: "usr/lib/*.o", reason: "x"),
                TargetObjectExemption(path: "usr/lib/a\tb", reason: "x")]:
      expect ValueError: validateTargetObjectExemption(bad)

suite "the publication gate":
  test "a host-platform or CPU-less publication is not checked":
    let root = stageTree([("bin/tool", "armhf.so")])
    defer: removeDir(root)
    let host = hostTriple().split('-')
    check targetObjectMismatchesForPublication(root, host[0], "linux", "gnu",
      "").len == 0
    check targetObjectMismatchesForPublication(root, "any", "linux", "", "").len == 0

  test "the rpi2 identity takes armhf objects and refuses host ones":
    # armv7 / linux / gnu / "": the consumer's conventions, which do not
    # state the float ABI, so only machine, class and data are held.
    let good = stageTree([("usr/bin/a", "armhf.so"), ("usr/lib/b.a", "armhf.a")])
    defer: removeDir(good)
    check targetObjectMismatchesForPublication(good, "armv7", "linux", "gnu",
      "").len == 0
    let bad = stageTree([("usr/bin/a", "x86_64.o")])
    defer: removeDir(bad)
    let p = targetObjectMismatchesForPublication(bad, "armv7", "linux", "gnu", "")
    check p.len == 1 and "EM_X86_64" in p[0]

  test "an ABI field that states the float ABI is held to it":
    let soft = stageTree([("usr/lib/a.so", "armsoft.so")])
    defer: removeDir(soft)
    check targetObjectMismatchesForPublication(soft, "armv7", "linux",
      "gnueabihf", "").len == 1
    check targetObjectMismatchesForPublication(soft, "armv7", "linux",
      "gnu", "").len == 0

  test "a libc field names the loader a dynamic image must use":
    let root = stageTree([("bin/a", "armhf-glibc-exe")])
    defer: removeDir(root)
    check targetObjectMismatchesForPublication(root, "armv7", "linux",
      "gnueabihf", "musl-1.2.5").len == 1
    check targetObjectMismatchesForPublication(root, "armv7", "linux",
      "gnueabihf", "glibc-2.41").len == 0

  test "a declared exemption passes its path":
    let root = stageTree([("usr/lib/bpf/p.o", "x86_64.o")])
    defer: removeDir(root)
    check targetObjectMismatchesForPublication(root, "armv7", "linux", "gnu",
      "", [TargetObjectExemption(path: "usr/lib/bpf/p.o", reason: "BPF")]).len == 0
