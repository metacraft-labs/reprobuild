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

import std/[os, strutils, unittest]

import repro_project_dsl/target_object_check

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
