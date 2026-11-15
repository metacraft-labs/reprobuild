## A preloaded monitor shim carries no DT_RUNPATH, and a program that brings
## its own C runtime runs under the monitor.
##
## The shim is LD_PRELOADed into processes it did not choose. Its DT_NEEDED is
## the C runtime (`libc.so.6`, `ld-linux-*.so.*`, and with some links `libm`,
## `librt`, `libdl`, `libpthread`), and those must resolve through the process
## that loads it. glibc's loader searches the DT_RPATH of the requesting object
## and of the objects that loaded it, the executable included, ONLY when the
## requesting object has no DT_RUNPATH (ld.so(8),
## https://man7.org/linux/man-pages/man8/ld.so.8.html; `_dl_map_object` in
## glibc's elf/dl-load.c). So any DT_RUNPATH on the shim, even one naming a
## directory that does not exist, switches off the program's DT_RPATH for the
## shim's dependencies. A program that finds its C runtime THROUGH its DT_RPATH
## — a toolchain realized into a store with its own glibc, its PT_INTERP and
## DT_RPATH rewritten to point at it — then resolves the shim's `libm.so.6`
## against the shim's runpath and its loader's compiled-in default directories,
## finds nothing, and never starts:
##
##   ar: error while loading shared libraries: libm.so.6: cannot open shared
##     object file: No such file or directory
##
## Every shim built in a nixpkgs dev shell carried such a runpath:
## `<checkout>/outputs/out/lib`, from the `-rpath $out/lib` stdenv's setup
## puts into `NIX_LDFLAGS` (`$out` is `<checkout>/outputs/out` in
## `nix develop`). `NIX_DONT_SET_RPATH=1`, which the shim's links already set,
## does not remove it, and the existing check did not see it: it looks for a
## runpath directory that PROVIDES a C runtime, and a directory that does not
## exist provides nothing.
##
## The cases, one per build path that produces the shim plus the behaviour:
##
##   1. STRUCTURAL, on the published `build/lib` shim — what the suite and
##      every monitored action actually inject (after the test phase's
##      `.#test-fixtures` build, the engine's own shim edge produced it).
##   2. The gate's own verdict function must report a runpath to a directory
##      that does not exist, which the runtime-providing check cannot.
##   3. BUILD PATH: io-mon's shim builder, driven exactly as
##      `scripts/build_apps.sh` and `scripts/run_tests.sh` drive it (through
##      `preload_shim_link_without_rpath`). Two real builds from a dev-shell
##      `NIX_LDFLAGS`: through the helper (must carry no runpath) and without
##      it (the polarity control: must carry the runpath, or the toolchain
##      does not read `NIX_LDFLAGS` and the case says so).
##   4. BUILD PATH: the engine's `reprobuild.test_fixtures.monitor_shim` edge.
##      Its lowered argv and environment are read from `repro graph`, and the
##      link is run exactly as the engine runs it (the action environment
##      layered over the engine's own), with the same polarity control.
##   5. BEHAVIOUR: a real `ar` rewritten onto a C runtime of its own runs
##      under `repro debug io monitor`, completes, and its reads are
##      recorded. A negative control proves the subject is what it claims:
##      the same shim with a runpath added must make it fail to start.
##
## Mocks and fabrications, and why (per the repository policy on justifying
## every mock): NO mocks — the compiler, the linker wrapper, the loader, the
## monitor and the shim are all real. Three inputs are fabricated from real
## files because the condition they stand for cannot be found on a host:
##
##   * `NIX_LDFLAGS="-rpath <scratch>/outputs/out/lib"` in cases 3 and 4 is
##     the exact value stdenv's setup produces in a dev shell, set explicitly
##     so the case does not depend on which shell the suite was started from.
##   * The foreign C runtime of case 5 is a copy of the store glibc the subject
##     already runs on, with the store path compiled into the copied loader
##     overwritten by a same-length path that does not exist. That gives a
##     loader whose default directories are empty, which is the defining
##     property of the real case (a sysroot glibc whose defaults are `/lib64`,
##     empty on NixOS) and the only thing that makes the subject depend on its
##     DT_RPATH. Without it a copied loader still finds the C runtime in its
##     store defaults and the case would pass over a broken shim.
##   * The negative control's shim is a copy of the published one with a
##     DT_RUNPATH and one extra C-runtime DT_NEEDED added by `patchelf`: the
##     shape of the defect, built from the artifact under test. The copy keeps
##     the file name `librepro_monitor_shim.so`, because the shim recognizes
##     its own mapping by that name (a renamed copy patches its own syscall
##     sites and dies of SIGTRAP; recorded as a separate defect).
##
## Skip rules, each announced: not Linux (DT_RUNPATH is an ELF concept);
## `patchelf` / `readelf` / `bash` missing; the shim or `build/bin/repro` not
## built; case 3 without an io-mon checkout or `nim`; case 4 when the engine
## cannot lower `.#test-fixtures`; case 5 when no dynamically linked `ar`
## running on a store C runtime is on PATH.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

const
  MissingLibraryNeedle = "cannot open shared object file"
    ## The loader's own wording when a DT_NEEDED entry is not found anywhere
    ## on the search path. Asserted beside the exit code because a nonzero
    ## exit alone does not say WHICH thing failed.
  ShimFileName = "librepro_monitor_shim.so"
  CRuntimeSonames = ["libc.so.6", "libm.so.6", "librt.so.1", "libdl.so.2",
    "libpthread.so.0", "libanl.so.1", "libutil.so.1", "libresolv.so.2"]
    ## The C-runtime libraries copied into the fabricated runtime; the same
    ## family `PRELOAD_SHIM_C_RUNTIME_SONAMES` names in the shell library.

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc shimLib(): string =
  repoRoot() / "scripts" / "lib" / "preloaded_shim_loader.sh"

proc tool(name: string): string = findExe(name)

proc haveElfTools(): bool =
  tool("patchelf").len > 0 and tool("readelf").len > 0 and
    tool("bash").len > 0

proc shimPath(): string = monitorShimPath(repoRoot())

proc reproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

## Every fact about an artifact's dynamic section is read by the SAME shell
## functions the build scripts and the lint gate use, so this file cannot
## agree with the ELF files while disagreeing with what ships.
proc bashLib(call: string;
             env: openArray[tuple[name, value: string]] = []): seq[string] =
  let cmd = "set -u; source " & shimLib().quoteShell & "; " & call
  let res = runShell(shellCommand(@[tool("bash"), "-c", cmd], env))
  for line in res.output.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0: result.add(trimmed)

proc runpathOf(file: string): seq[string] =
  bashLib("preload_shim_runpath_tag_entries " & file.quoteShell)

proc dynamicSection(file: string): string =
  runShell(shellCommand(@[tool("readelf"), "-d", "-W", file])).output

proc readelfRead(file: string): bool =
  ## The positive half of every "no runpath" assertion: a reader that came
  ## back empty because it could not read the file looks exactly like a clean
  ## shim. Every library here has a dynamic section with DT_NEEDED entries.
  "(NEEDED)" in dynamicSection(file) and "libc.so.6" in dynamicSection(file)

proc devShellLdflags(scratch: string): string =
  ## What stdenv's setup puts into `NIX_LDFLAGS` when a dev shell whose
  ## `$out` is `<scratch>/outputs/out` is entered.
  "-rpath " & (scratch / "outputs" / "out" / "lib")

proc siblingSource(envName, sibling: string): string =
  ## A source root the way the build scripts resolve it: the environment
  ## override (the dev shell sets these to the pinned store paths) with any
  ## trailing `/src` stripped, else the sibling checkout.
  var value = getEnv(envName)
  if value.len > 0:
    if value.endsWith("/src"): value = value[0 ..< value.len - 4]
    return value
  repoRoot().parentDir / sibling

proc storeHashlessCopy(prefix: string): string =
  ## A same-length path to a directory that does not exist, for overwriting
  ## `prefix` inside a copied loader. Only the final path component changes,
  ## so the result is still an absolute path of the same shape.
  let slash = prefix.rfind('/')
  result = prefix[0 .. slash] & repeat('x', prefix.len - slash - 1)

suite "the preloaded monitor shim carries no DT_RUNPATH":

  test "the published shim carries no DT_RUNPATH at all":
    when not defined(linux):
      skip("DT_RUNPATH is an ELF concept; on " & hostOS & " the shim " &
        "carries LC_RPATH or resolves by search order instead")
    else:
      if not haveElfTools():
        skip("patchelf, readelf and bash are required to read the shim's " &
          "dynamic section")
      elif not fileExists(shimPath()):
        skip(shimPath() & " is not built; run `just build`")
      else:
        let runpath = runpathOf(shimPath())
        checkpoint(shimPath() & " DT_RUNPATH: " &
          (if runpath.len == 0: "(none)" else: runpath.join(":")))
        check readelfRead(shimPath())
        check runpath.len == 0
        let findings = bashLib("preload_shim_search_path_findings " &
          shimPath().quoteShell)
        if findings.len > 0:
          checkpoint("findings:\n  " & findings.join("\n  "))
        check findings.len == 0

  test "the gate reports a runpath to a directory that does not exist":
    when not defined(linux):
      skip("DT_RUNPATH is an ELF concept; see the first case")
    else:
      if not haveElfTools():
        skip("patchelf, readelf and bash are required")
      elif not fileExists(shimPath()):
        skip(shimPath() & " is not built; run `just build`")
      else:
        let scratch = createTempDir("repro-shim-runpath-gate-", "")
        defer: removeDirEventually(scratch)
        let copy = scratch / ShimFileName
        copyFile(shimPath(), copy)
        setFilePermissions(copy, {fpUserRead, fpUserWrite, fpUserExec})
        let missing = scratch / "outputs" / "out" / "lib"
        discard requireSuccess(shellCommand(@[tool("patchelf"),
          "--set-rpath", missing, copy]))
        check missing in dynamicSection(copy)
        check "(RUNPATH)" in dynamicSection(copy)
        # The check that existed before could not see it: the directory does
        # not exist, so it provides no C runtime. That is the whole defect.
        check bashLib("preload_shim_imposed_runtime_dirs " &
          copy.quoteShell).len == 0
        let findings = bashLib("preload_shim_search_path_findings " &
          copy.quoteShell)
        checkpoint("findings: " & findings.join(" | "))
        check findings == @["runpath\t" & missing]

  test "io-mon's builder, driven as the build scripts drive it, adds none":
    when not defined(linux):
      skip("DT_RUNPATH is an ELF concept; see the first case")
    else:
      let ioMon = siblingSource("IO_MON_SRC", "io-mon")
      let builder = ioMon / "scripts" / "build_shim.sh"
      if not haveElfTools():
        skip("patchelf, readelf and bash are required")
      elif not fileExists(builder):
        skip("no io-mon shim builder at " & builder &
          "; set IO_MON_SRC or check out io-mon beside this repository")
      elif tool("nim").len == 0:
        skip("`nim` is not on PATH, so the shim cannot be built")
      else:
        let scratch = createTempDir("repro-shim-runpath-builder-", "")
        defer: removeDirEventually(scratch)
        let ldflags = devShellLdflags(scratch)
        proc build(name: string; throughHelper: bool):
            tuple[code: int; output, shim: string] =
          let outDir = scratch / name
          createDir(outDir)
          let env = @[
            ("NIX_LDFLAGS", ldflags),
            ("IO_MON_SHIM_OUT_DIR", outDir),
            ("IO_MON_SHIM_NIMCACHE_DIR", outDir / "nimcache"),
            ("IO_MON_BUILD_MODE", "debug"),
            ("STACKABLE_HOOKS_SRC",
              siblingSource("STACKABLE_HOOKS_SRC", "nim-stackable-hooks") /
                "src"),
            ("SHM_QUEUE_SRC",
              siblingSource("SHM_QUEUE_SRC", "nim-shm-queue") / "src"),
            ("SHM_GSET_SRC",
              siblingSource("SHM_GSET_SRC", "nim-shm-gset") / "src")]
          let launch =
            if throughHelper:
              "preload_shim_link_without_rpath bash " & builder.quoteShell
            else:
              "NIX_DONT_SET_RPATH=1 bash " & builder.quoteShell
          let res = runShell(shellCommand(@[tool("bash"), "-c",
            "set -u; source " & shimLib().quoteShell & "; " & launch], env))
          (res.code, res.output, outDir / ShimFileName)

        let built = build("through-helper", throughHelper = true)
        if built.code != 0:
          checkpoint("build through the helper failed:\n" & built.output)
        check built.code == 0
        let fixed = built.shim
        check fileExists(fixed)
        if fileExists(fixed):
          check readelfRead(fixed)
          let runpath = runpathOf(fixed)
          checkpoint("through preload_shim_link_without_rpath: " &
            (if runpath.len == 0: "(none)" else: runpath.join(":")))
          check runpath.len == 0

        # POLARITY. Same builder, same NIX_LDFLAGS, only the helper removed:
        # with a toolchain that reads NIX_LDFLAGS this is the defect itself.
        let controlBuilt = build("control", throughHelper = false)
        if controlBuilt.code != 0:
          checkpoint("control build failed:\n" & controlBuilt.output)
        check controlBuilt.code == 0
        let control = controlBuilt.shim
        if fileExists(control):
          let runpath = runpathOf(control)
          checkpoint("control (NIX_DONT_SET_RPATH=1 alone): " &
            (if runpath.len == 0: "(none)" else: runpath.join(":")))
          if runpath.len == 0:
            checkpoint("this toolchain does not read NIX_LDFLAGS, so the " &
              "control cannot show the defect; the assertion above still " &
              "holds")
          else:
            check runpath == @[scratch / "outputs" / "out" / "lib"]

  test "the engine's monitor-shim edge links with no linker-wrapper rpath":
    when not defined(linux):
      skip("DT_RUNPATH is an ELF concept; see the first case")
    else:
      if not haveElfTools():
        skip("patchelf, readelf and bash are required")
      elif not fileExists(reproBin()):
        skip(reproBin() & " is missing; run `just build`")
      else:
        let graphRun = runShellSplit(shellCommand(@[reproBin(), "graph",
          ".#test-fixtures", "--tool-provisioning=path", "--format=json"]),
          repoRoot())
        var action: JsonNode = nil
        if graphRun.code == 0:
          try:
            for a in parseJson(graphRun.stdout){"actions"}:
              if a{"id"}.getStr() == "reprobuild.test_fixtures.monitor_shim":
                action = a
          except CatchableError as err:
            checkpoint("graph output was not JSON: " & err.msg)
        if action.isNil:
          checkpoint("repro graph exit=" & $graphRun.code & "\n" &
            graphRun.stderr)
          skip("the engine could not lower .#test-fixtures here, so the " &
            "monitor-shim edge's link cannot be replayed")
        else:
          var declared: seq[(string, string)]
          for entry in action{"env"}:
            let text = entry.getStr()
            let eq = text.find('=')
            if eq > 0: declared.add((text[0 ..< eq], text[eq + 1 .. ^1]))
          checkpoint("lowered env: " & $declared)
          check ("NIX_DONT_SET_RPATH", "1") in declared
          check ("NIX_LDFLAGS", "") in declared

          let scratch = createTempDir("repro-shim-runpath-edge-", "")
          defer: removeDirEventually(scratch)
          proc link(name: string; env: openArray[(string, string)]):
              tuple[code: int; output, shim: string] =
            ## Run the lowered argv the way the engine runs it: the action's
            ## environment layered over the engine's own, here the test's
            ## plus a dev shell's NIX_LDFLAGS. Only the output and nimcache
            ## move into scratch.
            let outDir = scratch / name
            createDir(outDir)
            var table = newStringTable()
            for k, v in envPairs(): table[k] = v
            table["NIX_LDFLAGS"] = devShellLdflags(scratch)
            for (k, v) in env: table[k] = v
            var argv: seq[string]
            for item in action{"argv"}:
              var arg = item.getStr()
              if arg.startsWith("--out:"):
                arg = "--out:" & (outDir / ShimFileName)
              elif arg.startsWith("--nimcache:"):
                arg = "--nimcache:" & (outDir / "nimcache")
              argv.add(arg)
            let p = startProcess(argv[0], workingDir = action{"cwd"}.getStr(),
              args = argv[1 .. ^1], env = table,
              options = {poStdErrToStdOut})
            let output = p.outputStream.readAll()
            let code = p.waitForExit()
            p.close()
            (code, output, outDir / ShimFileName)

          let linked = link("as-lowered", declared)
          if linked.code != 0:
            checkpoint("link as lowered failed:\n" & linked.output)
          check linked.code == 0
          let fixed = linked.shim
          check fileExists(fixed)
          if fileExists(fixed):
            check readelfRead(fixed)
            let runpath = runpathOf(fixed)
            checkpoint("as lowered: " &
              (if runpath.len == 0: "(none)" else: runpath.join(":")))
            check runpath.len == 0

          # POLARITY: the lowered environment minus the NIX_LDFLAGS entries,
          # which is what the edge declared before.
          var before: seq[(string, string)]
          for (k, v) in declared:
            if not k.startsWith("NIX_LDFLAGS"): before.add((k, v))
          let controlLinked = link("control", before)
          if controlLinked.code != 0:
            checkpoint("control link failed:\n" & controlLinked.output)
          check controlLinked.code == 0
          let control = controlLinked.shim
          if fileExists(control):
            let runpath = runpathOf(control)
            checkpoint("control: " &
              (if runpath.len == 0: "(none)" else: runpath.join(":")))
            if runpath.len == 0:
              checkpoint("this toolchain does not read NIX_LDFLAGS, so the " &
                "control cannot show the defect")
            else:
              check runpath == @[scratch / "outputs" / "out" / "lib"]

  test "a program on a C runtime of its own runs under the monitor":
    when not defined(linux):
      skip("DT_RUNPATH is an ELF concept; see the first case")
    else:
      var ar = tool("ar")
      if ar.len > 0:
        ar = runShell(shellCommand(@["readlink", "-f", ar])).output.strip()
      let interp =
        if ar.len > 0 and haveElfTools():
          runShell(shellCommand(@[tool("patchelf"), "--print-interpreter",
            ar])).output.strip()
        else: ""
      if not haveElfTools():
        skip("patchelf, readelf and bash are required")
      elif not fileExists(shimPath()):
        skip(shimPath() & " is not built; run `just build`")
      elif not fileExists(reproBin()):
        skip(reproBin() & " is missing; run `just build`")
      elif interp.len == 0 or not interp.startsWith("/nix/store/"):
        skip("no dynamically linked `ar` running on a store C runtime is " &
          "on PATH (ar=" & ar & ", interpreter=" & interp & "), so no " &
          "loader with empty default directories can be fabricated here")
      else:
        let runtimeLib = interp.parentDir
        let runtimePrefix = runtimeLib.parentDir
        let scratch = createTempDir("repro-shim-foreign-loader-", "")
        defer: removeDirEventually(scratch)

        # The foreign C runtime: the loader and the C-runtime libraries,
        # copied, with the store path compiled into the loader overwritten so
        # its default directories hold nothing.
        let fab = scratch / "runtime"
        createDir(fab)
        for soname in CRuntimeSonames:
          if fileExists(runtimeLib / soname):
            copyFile(runtimeLib / soname, fab / soname)
        let loader = fab / interp.extractFilename
        var loaderBytes = readFile(interp)
        check runtimePrefix in loaderBytes
        loaderBytes = loaderBytes.replace(runtimePrefix,
          storeHashlessCopy(runtimePrefix))
        check runtimePrefix notin loaderBytes
        writeFile(loader, loaderBytes)
        for f in walkFiles(fab / "*"):
          setFilePermissions(f, {fpUserRead, fpUserWrite, fpUserExec})

        # The subject: the real `ar`, its PT_INTERP and DT_RPATH pointing at
        # the fabricated runtime first and its own other libraries after.
        var rpath = @[fab]
        for entry in runShell(shellCommand(@[tool("patchelf"),
            "--print-rpath", ar])).output.strip().split(':'):
          if entry.len > 0 and entry != runtimeLib: rpath.add(entry)
        let subject = scratch / "bin" / "ar"
        createDir(subject.parentDir)
        copyFile(ar, subject)
        setFilePermissions(subject, {fpUserRead, fpUserWrite, fpUserExec})
        discard requireSuccess(shellCommand(@[tool("patchelf"),
          "--set-interpreter", loader, "--force-rpath", "--set-rpath",
          rpath.join(":"), subject]))

        writeFile(scratch / "member.txt", "a member\n")
        let archive = scratch / "t.a"
        let made = runShell(shellCommand(@[subject, "rc", archive,
          "member.txt"]), scratch)
        checkpoint("bare `ar rc`: exit " & $made.code & "\n" & made.output)
        require made.code == 0

        proc monitored(shim, depfile: string): CmdResult =
          runShell(shellCommand(@[reproBin(), "debug", "io", "monitor",
            "--depfile=" & depfile, "--", subject, "t", archive],
            @[("REPRO_MONITOR_SHIM_LIB", shim), ("REPRO_CACHE_DISABLE", "1"),
              ("REPRO_BINARY_CACHE_URL", "")]), scratch)

        # NEGATIVE CONTROL: the published shim plus a DT_RUNPATH, and a
        # C-runtime dependency the subject does not load itself, so the
        # loader has to find it on the shim's search path. If the subject
        # could still start, its loader's defaults find the C runtime and
        # nothing below would say anything.
        var extra = ""
        let subjectNeeds = runShell(shellCommand(@[tool("patchelf"),
          "--print-needed", subject])).output
        for candidate in ["libanl.so.1", "libutil.so.1", "libm.so.6",
                          "librt.so.1"]:
          if extra.len == 0 and fileExists(fab / candidate) and
              candidate notin subjectNeeds:
            extra = candidate
        require extra.len > 0
        let negDir = scratch / "with-runpath"
        let posDir = scratch / "without-runpath"
        for dir in [negDir, posDir]:
          createDir(dir)
          copyFile(shimPath(), dir / ShimFileName)
          setFilePermissions(dir / ShimFileName,
            {fpUserRead, fpUserWrite, fpUserExec})
          discard requireSuccess(shellCommand(@[tool("patchelf"),
            "--remove-rpath", "--add-needed", extra, dir / ShimFileName]))
        discard requireSuccess(shellCommand(@[tool("patchelf"),
          "--set-rpath", scratch / "outputs" / "out" / "lib",
          negDir / ShimFileName]))
        let refused = monitored(negDir / ShimFileName, scratch / "neg.iomon")
        checkpoint("with a runpath: exit " & $refused.code & "\n" &
          refused.output)
        check refused.code != 0
        check MissingLibraryNeedle in refused.output
        check extra in refused.output
        # ...and moving ONLY the runpath makes it start.
        let accepted = monitored(posDir / ShimFileName, scratch / "pos.iomon")
        checkpoint("same shim, no runpath: exit " & $accepted.code & "\n" &
          accepted.output)
        check accepted.code == 0

        # THE CASE: the published shim.
        let depfile = scratch / "evidence.iomon"
        let run = monitored(shimPath(), depfile)
        checkpoint("published shim: exit " & $run.code & "\n" & run.output)
        check run.code == 0
        check MissingLibraryNeedle notin run.output
        check "member.txt" in run.output
        check fileExists(depfile)
        if fileExists(depfile):
          let inspected = runShell(shellCommand(@[reproBin(), "debug", "io",
            "monitor", "inspect", depfile]))
          check inspected.code == 0
          var readArchive, loadedForeignLoader = false
          for line in inspected.output.splitLines:
            if " file-read " in line and ("path=" & archive & " ") in line:
              readArchive = true
            if " library-load " in line and ("path=" & loader & " ") in line:
              loadedForeignLoader = true
          if not (readArchive and loadedForeignLoader):
            checkpoint("inspect:\n" & inspected.output)
          check readArchive
          check loadedForeignLoader
          check "completeness=mcComplete" in inspected.output
