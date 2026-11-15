## The ELF relocation step of a tarball realization points every dynamically
## linked program under the declared directories at the loader and C library
## the archive carries, and the relocated program runs.
##
## Dependency-Provisioning-In-Build-Graph.md §4.2, "Relocating a dynamically
## linked archive", and Caching-Architecture.md §"Design for XPC-AREQ1" D3
## item 2. The engine realizes Bootlin's glibc toolchain this way; here the
## "archive" is a staging tree built on the spot so the case runs offline:
## a program compiled by the dev shell's C compiler, the dev shell's own
## glibc loader and C library copied into `sysroot/lib`, a second hard link
## to the program, an object file and a script beside it.
##
## Cases:
##   * the program's `PT_INTERP` becomes the tree's loader and its
##     `DT_RPATH` ends with the tree's library directory, both absolute in the
##     final prefix; it runs; a hard link is rewritten once and the object
##     file and the script are untouched; a second pass rewrites nothing
##     (the step is idempotent, so realizing twice gives the same bytes);
##   * a declared loader missing from the tree, or no `patchelf`, fails the
##     realization instead of sealing an unrelocated tree;
##   * the GCC specs edit extends the `*link:` spec and nothing else;
##   * declared spec defaults (`gccSpecDefault`) are appended to the specs
##     they name, an empty spec included, and a spec the dump lacks or an
##     entry without a spec name fails;
##   * the Linux toolchain pin's defaults, written into a real GCC's specs,
##     give the command lines Buildroot's wrapper gives: stack protector,
##     PIE and `-z now -z relro` by default, each dropped by the options the
##     wrapper honours, and a later user option still wins.
##
## Falsifying mutations: dropping `--set-interpreter` (or keying the hard
## link check off) turns the first case red; returning without the
## missing-loader check turns the second red; appending to the wrong spec
## turns the third and fourth red; dropping a condition from the pin's spec
## text (or a default) turns the fifth red.
##
## No mocks: the real `patchelf` (the dev shell's, the same program the
## stdlib package provisions), a real compiler, a real glibc loader, the real
## filesystem. The fifth case runs the dev shell's UNWRAPPED `gcc` (the Nix
## wrapper adds hardening options of its own, which would make the check
## vacuous) with `-###`, which prints the commands without running them.
## Linux only: it is the platform the relocation exists for.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_project_dsl/install_mirror_relocation
import repro_tool_profiles/elf_relocation
import repro_dsl_stdlib/linux_toolchain_pin
import repro_test_support/reasoned_skip

proc run(command: string): tuple[output: string; exitCode: int] =
  execCmdEx(command)

proc runTool(argv: seq[string]): tuple[output: string; exitCode: int] =
  ## The process runner the realizer would inject (``ElfToolRunner``).
  execCmdEx(quoteShellCommand(argv))

proc stagedTree(): tuple[root, program, obj: string] =
  ## A staging tree holding one dynamically linked program built by the dev
  ## shell's `cc`, against a loader and libc copied into `sysroot/lib`.
  result.root = createTempDir("repro-elf-relocation-", "")
  createDir(result.root / "bin")
  createDir(result.root / "sysroot" / "lib")
  let source = result.root / "hello.c"
  writeFile(source, "#include <stdio.h>\nint main(void) { puts(\"relocated\"); return 0; }\n")
  result.program = result.root / "bin" / "hello"
  let compiled = run("cc -o " & quoteShell(result.program) & " " &
    quoteShell(source))
  doAssert compiled.exitCode == 0, compiled.output
  result.obj = result.root / "bin" / "hello.o"
  let objCompiled = run("cc -c -o " & quoteShell(result.obj) & " " &
    quoteShell(source))
  doAssert objCompiled.exitCode == 0, objCompiled.output
  for name in ["ld-linux-x86-64.so.2", "libc.so.6"]:
    let found = run("cc -print-file-name=" & name).output.strip()
    doAssert fileExists(found), "the dev shell's cc does not know " & name
    copyFile(expandFilename(found), result.root / "sysroot" / "lib" / name)
    setFilePermissions(result.root / "sysroot" / "lib" / name,
      {fpUserRead, fpUserWrite, fpUserExec})
  createHardlink(result.program, result.root / "bin" / "hello-link")
  writeFile(result.root / "bin" / "script.sh", "#!/bin/sh\necho hi\n")

proc detailFor(): TarballArchiveDetail =
  TarballArchiveDetail(
    elfInterpreter: "sysroot/lib/ld-linux-x86-64.so.2",
    elfRunpath: @["sysroot/lib"],
    elfPatchDirs: @["bin"])

suite "ELF relocation of a tarball realization":
  test "programs ask for the tree's loader, run, and a second pass is a no-op":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      let patchelf = findExe("patchelf")
      require patchelf.len > 0
      let tree = stagedTree()
      defer: removeDir(tree.root)
      let objBefore = readFile(tree.obj)
      let rewritten = relocateElfTree(detailFor(), tree.root, tree.root,
        patchelf, runTool)
      # One program; its hard link is the same file; the object file and
      # the script are not dynamically linked programs.
      check rewritten == 1
      let facts = readElfRuntimeFacts(tree.program)
      check facts.interpreter ==
        tree.root / "sysroot" / "lib" / "ld-linux-x86-64.so.2"
      check facts.runPaths.len >= 1
      check facts.runPaths[^1] == tree.root / "sysroot" / "lib"
      check readElfRuntimeFacts(tree.root / "bin" / "hello-link").interpreter ==
        facts.interpreter
      check readFile(tree.obj) == objBefore
      let ran = run(quoteShell(tree.program))
      checkpoint ran.output
      check ran.exitCode == 0
      check ran.output.strip() == "relocated"
      let programBytes = readFile(tree.program)
      check relocateElfTree(detailFor(), tree.root, tree.root, patchelf,
        runTool) == 0
      check readFile(tree.program) == programBytes

  test "a missing declared loader or no patchelf fails the realization":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      let patchelf = findExe("patchelf")
      require patchelf.len > 0
      let tree = stagedTree()
      defer: removeDir(tree.root)
      var missing = detailFor()
      missing.elfInterpreter = "sysroot/lib/ld-missing.so"
      expect ElfRelocationError:
        discard relocateElfTree(missing, tree.root, tree.root, patchelf, runTool)
      expect ElfRelocationError:
        discard relocateElfTree(detailFor(), tree.root, tree.root, "", runTool)
      var noDirs = detailFor()
      noDirs.elfPatchDirs = @[]
      expect ElfRelocationError:
        discard relocateElfTree(noDirs, tree.root, tree.root, patchelf, runTool)
      # Nothing was rewritten by the refused runs.
      check readElfRuntimeFacts(tree.program).interpreter !=
        tree.root / "sysroot" / "lib" / "ld-linux-x86-64.so.2"

  test "the specs edit extends the link spec and nothing else":
    let dumped = "*asm:\n--64\n\n*link:\n%{shared:-shared} -m elf_x86_64\n\n" &
      "*lib:\n-lc\n"
    let edited = gccLinkSpecsText(dumped, "/p/ld.so", ["/p/lib"])
    let lines = edited.splitLines()
    check lines[1] == "--64"
    check lines[4] == "%{shared:-shared} -m elf_x86_64" &
      " %{!shared:%{!static:%{!static-pie:-dynamic-linker /p/ld.so}}}" &
      " %{!static:%{!static-pie:-rpath /p/lib}}"
    check lines[7] == "-lc"
    expect ElfRelocationError:
      discard gccLinkSpecsText("*lib:\n-lc\n", "/p/ld.so", ["/p/lib"])

  test "declared spec defaults are appended to the specs they name":
    let dumped = "*cc1:\n%(cc1_cpu)\n\n*link:\n-m elf_x86_64\n\n" &
      "*self_spec:\n\n\n*lib:\n-lc\n"
    let edited = gccLinkSpecsText(dumped, "/p/ld.so", ["/p/lib"],
      ["cc1:-fstack-protector-strong", "link: -z now",
       "self_spec:%{!shared:-pie}"])
    let lines = edited.splitLines()
    check lines[1] == "%(cc1_cpu) -fstack-protector-strong"
    check lines[4] == "-m elf_x86_64" &
      " %{!shared:%{!static:%{!static-pie:-dynamic-linker /p/ld.so}}}" &
      " %{!static:%{!static-pie:-rpath /p/lib}} -z now"
    check lines[7] == "%{!shared:-pie}"
    check lines[10] == "-lc"
    expect ElfRelocationError:
      discard gccLinkSpecsText(dumped, "/p/ld.so", ["/p/lib"],
        ["cc1plus:-O2"])
    expect ElfRelocationError:
      discard gccLinkSpecsText(dumped, "/p/ld.so", ["/p/lib"], [":-O2"])
    expect ElfRelocationError:
      discard gccLinkSpecsText(dumped, "/p/ld.so", ["/p/lib"], ["-O2"])

  test "the Linux toolchain pin's spec defaults match Buildroot's wrapper":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      # The dev shell's `gcc` is a Nix wrapper; `nix-support/orig-cc` in its
      # package names the GCC it wraps.
      let wrapper = findExe("gcc")
      require wrapper.len > 0
      let origCc = wrapper.parentDir.parentDir / "nix-support" / "orig-cc"
      require fileExists(origCc)
      let gcc = readFile(origCc).strip() / "bin" / "gcc"
      require fileExists(gcc)
      let dumped = run(quoteShell(gcc) & " -dumpspecs")
      require dumped.exitCode == 0
      let dir = createTempDir("repro-gcc-spec-defaults-", "")
      defer: removeDir(dir)
      let specs = dir / "specs"
      writeFile(specs, gccLinkSpecsText(dumped.output, "/p/ld.so",
        ["/p/lib"], LinuxToolchainGccSpecDefaults))
      writeFile(dir / "t.c", "int main(void) { return 0; }\n")
      proc commands(args: string; withSpecs = true): string =
        ## The cc1 and collect2 command lines the driver would run, with the
        ## written specs or (``withSpecs = false``) with its own.
        let specsArg = if withSpecs: " -specs=" & quoteShell(specs) else: ""
        let shown = run(quoteShell(gcc) & specsArg & " -### " & args & " " & quoteShell(dir / "t.c") & " -o " &
          quoteShell(dir / "t.out") & " 2>&1")
        checkpoint(args & ":\n" & shown.output)
        doAssert shown.exitCode == 0, shown.output
        var sawCc1, sawCollect2 = false
        for line in shown.output.splitLines():
          # The driver's own options after its self specs, quoted
          # (`'-pie'`): shows a `-pie` the self spec added even where a
          # default-PIE GCC links `-pie` anyway.
          if line.startsWith("COLLECT_GCC_OPTIONS="):
            result.add("options: " & line & "\n")
            continue
          let command = line.strip().replace("\"", "")
          let program = command.split(' ')[0]
          if program.endsWith("/cc1") or program.endsWith("/collect2"):
            sawCc1 = sawCc1 or program.endsWith("/cc1")
            sawCollect2 = sawCollect2 or program.endsWith("/collect2")
            result.add(" " & command & "\n")
        # Vacuity guard: the `notin` checks below mean nothing unless both
        # command lines were found.
        doAssert sawCc1 and sawCollect2, "no cc1 or collect2 command in:\n" &
          shown.output
      let plain = commands("")
      check " -fstack-protector-strong" in plain
      check " -fPIE" in plain
      check " -pie" in plain
      check "'-pie'" in plain
      check "'-pie'" notin commands("", withSpecs = false)
      check " -z now -z relro" in plain
      check "Scrt1.o" in plain
      for disables in ["-no-pie", "-fno-pie", "-static", "-D__KERNEL__"]:
        let lines = commands(disables)
        check " -fPIE" notin lines
        # A GCC configured with --enable-default-pie (nixpkgs' is) links
        # `-pie` by itself where the option does not turn PIE off; only a
        # `-pie` the defaults added is a failure.
        check "'-pie'" notin lines
        if " -pie" notin commands(disables, withSpecs = false):
          check " -pie" notin lines
        check " -fstack-protector-strong" in lines
      check " -z now" notin commands("-D__KERNEL__")
      let shared = commands("-shared -fPIC")
      check " -pie" notin shared
      check "'-pie'" notin shared
      check " -fPIE" notin shared
      # A user option after the defaults wins: cc1 sees the default first.
      let noSsp = commands("-fno-stack-protector")
      check noSsp.find(" -fstack-protector-strong") <
        noSsp.find(" -fno-stack-protector")
