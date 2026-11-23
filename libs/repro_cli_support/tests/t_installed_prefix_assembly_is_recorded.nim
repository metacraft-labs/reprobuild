## The installed-prefix assembly is a recorded edge: a second build of the
## same inputs reuses it, so the tree `--publish` sends is the one measured.
##
## THE DEFECT THIS PINS. `repro build --publish` of `.#prefix`, run after the
## prefix had been built and measured in the same checkout and action cache,
## re-ran `installed-prefix-reprobuild@<triple>` with `cdMiss` and
## `cache-publish-skipped: reasons=unblessed-entropy`. The assembly strips
## the debug info of every bundled library that carries any (the catalog's
## source builds) with llvm-objcopy, and llvm-objcopy given an OUTPUT PATH
## writes a temporary with a random name beside it and renames it into
## place. That `arc4random` draw comes from a tool no CLI spec blesses, so
## the engine withholds the edge's cache entry, and every build, the
## publishing one included, assembles the tree again. Given `- -` it reads
## standard input and writes standard output, and draws nothing.
##
## NO MOCKS. The producer's own assembly program runs, stripping a real
## library with debug info through the real `llvm-objcopy` and the exact
## command the reprobuild prefix uses (`LlvmObjcopyDebugStrip`), under the
## real monitor driver and shim, through the real evidence fold and the real
## per-edge store. A synthetic capture would grade the engine's bookkeeping;
## the defect is which tool really draws entropy.
##
## THE ASSERTIONS ARE ON THE RECORD. `cachePublishSkipReason` is empty and a
## record directory exists after the first build; the second build does not
## launch the edge and settles it `cdHit` from its own per-edge lookup
## (`asCacheHit`, not the no-op prefix's `asUpToDate`).
##
## PLATFORM. Linux only: the prefix is ELF and the case strips an ELF
## library. Without a tool on PATH the case skips with the reason, and fails
## in a gate run.

import std/[os, osproc, strutils, unittest]

import repro_build_engine
from repro_test_support import prepareMonitorTools
import repro_test_support/reasoned_skip
import repro_dsl_stdlib/packaging/producers/installed_prefix

proc missingTool(): string =
  for tool in ["cc", "readelf", "patchelf", "llvm-objcopy", "awk", "sed",
               "sort", "grep", "find", "mktemp"]:
    if findExe(tool).len == 0:
      return tool & " is not on PATH"
  ""

proc hostedConfig(cacheRoot: string): BuildEngineConfig =
  let tools = prepareMonitorTools(getCurrentDir(),
    getCurrentDir() / "build" / "test-prefix-assembly", "prefix-assembly")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: tools.monitorCliPath,
    monitorCliPath: tools.monitorCliPath,
    monitorCliArgs: tools.monitorCliArgs,
    maxParallelism: 1,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    bypassRunQuota: true,
    monitorHosting: mhmNever)

proc scratchRoot(name: string): string =
  result = absolutePath("build" / "test-tmp" /
    "t_installed_prefix_assembly_is_recorded" / name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc cc(dir, args: string) =
  # As in `t_installed_prefix`: a Nix linker wrapper would write an rpath
  # for every `-L` directory and the dev shell's `$out/lib`.
  let r = execCmdEx("sh -c " & quoteShell("env -u out -u NIX_LDFLAGS " &
    "NIX_DONT_SET_RPATH=1 cc " & args), workingDir = dir)
  doAssert r.exitCode == 0, r.output

proc perEdgeRecordDirCount(cacheRoot: string): int =
  let root = cacheRoot / "action-cache" / "hot-records"
  if not dirExists(root):
    return 0
  for kind, _ in walkDir(root):
    if kind == pcDir:
      inc result

proc assemblyGraph(spec: InstalledPrefixSpec; work: string): BuildGraph =
  ## The assembly edge `installedPrefix` declares, as an engine action: the
  ## same program, inputs and output. `cacheable = true` is load-bearing, as
  ## on the producer's edge: without it nothing is ever withheld.
  var inputs: seq[string]
  for e in spec.entries:
    inputs.add(e.source)
  graph([action("installed-prefix-probe@native",
    ["sh", "-c", assemblyScript(spec)], cwd = work, inputs = inputs,
    outputs = [spec.output], cacheable = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())])

suite "the installed-prefix assembly is recorded":

  test "an assembly that strips a library publishes, and the rebuild hits":
    when not defined(linux):
      skip("not Linux; an installed prefix is ELF")
    else:
      let missing = missingTool()
      if missing.len > 0:
        if getEnv("REPROBUILD_GATE_RUN") == "1":
          checkpoint(missing & " in a gate run")
          check false
        else:
          skip(missing)
      else:
        let root = scratchRoot("strip")
        let work = root / "work"
        createDir(work / "built" / "bin")
        createDir(work / "libs")
        writeFile(work / "bar.c", "int bar(void) { return 2; }\n")
        writeFile(work / "app.c",
          "int bar(void);\nint main(void) { return bar() == 2 ? 0 : 1; }\n")
        # Debug info, so the assembly strips it: the case under test.
        cc(work, "-g -shared -fPIC -Wl,-soname,libbar.so.1 " &
          "-o libs/libbar.so.1 bar.c")
        cc(work, "-o built/bin/app app.c -Llibs -l:libbar.so.1 " &
          "-Wl,-rpath-link,libs")
        let spec = InstalledPrefixSpec(name: "probe", triple: "native",
          output: work / "prefix",
          entries: @[PrefixEntry(source: work / "built" / "bin" / "app",
            dest: "bin/app")],
          librarySources: @[PrefixLibrarySource(dir: work / "libs",
            origin: "test:libs")],
          systemSonames: @GlibcSonames,
          recordLines: @["source_revision=abc123"],
          debugStripCommand: LlvmObjcopyDebugStrip)
        let cacheRoot = root / "cache"

        let first = runBuild(assemblyGraph(spec, work), hostedConfig(cacheRoot))
        require first.results.len == 1
        let a = first.results[0]
        checkpoint("first build: " & $a.status & " " & $a.cacheDecision &
          " skip=" & a.cachePublishSkipReason & " reason=" & a.reason)
        require a.status == asSucceeded
        check a.launched
        # The strip really ran, so the case is about it.
        check execCmdEx("readelf -S " & quoteShell(spec.output / "lib" /
          "libbar.so.1")).output.count(".debug") == 0
        # THE PROPERTY. Before the fix: "reasons=unblessed-entropy",
        # naming llvm-objcopy, and no record.
        check a.cachePublishSkipReason.len == 0
        check "entropy" notin a.cachePublishSkipReason
        check perEdgeRecordDirCount(cacheRoot) == 1

        let second = runBuild(assemblyGraph(spec, work),
          hostedConfig(cacheRoot))
        require second.results.len == 1
        let b = second.results[0]
        checkpoint("second build: " & $b.status & " " & $b.cacheDecision)
        check not b.launched
        check b.cacheDecision == cdHit
        check b.status == asCacheHit
