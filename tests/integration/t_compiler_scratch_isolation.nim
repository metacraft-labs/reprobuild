## Regression coverage for installed-package compiler scratch isolation.
##
## Interface extraction and provider compilation consume an immutable source
## tree but must put every response file/intermediate/output in writable
## scratch. Provider compiles are also invoked concurrently in one process to
## prove their compiler CWD allocation is exclusive, not merely unlikely to
## collide.
##
## The last suites cover the search path the extraction launches its compile
## with. The search-path NimScript (`splitSearchPathReassertion`): with the
## real compiler's `nim dump`, the split command plus its script reach the
## search path the logical command reaches, and on Windows an extraction whose
## SDK reassertion alone is over the 32,767-character command-line limit
## compiles. The recipe-configuration paths the extraction replays
## (`recipeConfigSearchPathFlags`) leave out Nim's own library directories in
## the host's path syntax. No mocks there: a real SDK tree (junctions to this
## checkout's libraries) and the real compiler.

import std/[json, os, sequtils, strutils, tables, tempfiles, times, unittest]

import repro_core
import repro_hash
import repro_interface_artifacts
import repro_test_support

const RealNimCompiler = staticExec("command -v nim").strip()

type CompileJob = object
  modulePath: string
  outputPath: string
  artifactPath: string
  workDir: string
  scratchDir: string
  interfaceFingerprint: ContentDigest
  errorPath: string

proc compileInThread(job: CompileJob) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard compileProviderBinary(job.modulePath, job.outputPath,
        job.interfaceFingerprint, job.artifactPath, job.workDir,
        job.scratchDir)
    except CatchableError as exc:
      writeFile(job.errorPath, exc.msg)

proc transientChildren(root, prefix: string): seq[string] =
  if not dirExists(root):
    return
  for kind, path in walkDir(root):
    if path.extractFilename.startsWith(prefix):
      result.add(path)

proc runnerFiles(dir: string): tuple[sources, scripts: int] =
  ## The extraction runners in `dir`: their `.nim` sources and the `.nims`
  ## search-path scripts published beside them (`splitSearchPathReassertion`).
  ## The runner is named after both, so the two counts move together.
  for path in transientChildren(dir, "extract_runner_"):
    if path.endsWith(".nims"): inc result.scripts
    elif path.endsWith(".nim"): inc result.sources

proc writeCompilerObserver(path, cwdLog: string) =
  writeFile(path,
    "#!/bin/sh\n" &
    "printf '%s\\n' \"$PWD\" >> '" & cwdLog & "'\n" &
    "if [ \"${REPRO_TEST_NIM_FAIL:-0}\" = 1 ]; then exit 93; fi\n" &
    "if [ \"${REPRO_TEST_FAKE_PROVIDER:-0}\" = 1 ]; then\n" &
    "  output=\n" &
    "  for arg in \"$@\"; do\n" &
    "    case \"$arg\" in --out:*) output=${arg#--out:} ;; esac\n" &
    "  done\n" &
    "  test -n \"$output\" || exit 94\n" &
    "  sleep 1\n" &
    "  printf '%s\\n' fake-provider > \"$output\"\n" &
    "  exit 0\n" &
    "fi\n" &
    "exec '" & RealNimCompiler & "' \"$@\"\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

const providerBody = """
import repro_project_dsl

package immutableScratchFixture:
  build:
    discard
"""

when defined(posix) and isNixSupported:
  suite "compiler scratch isolation":
    test "runtime RPATH compiler argv is target-correct and deduplicated":
      let dirs = @["", "/runtime/one", "/runtime/two", "/runtime/one", ""]
      check runtimeRpathCompilerFlags(dirs, rltWindows).len == 0
      check runtimeRpathCompilerFlags(dirs, rltLinux) == @[
        "--passL:-Wl,--disable-new-dtags",
        "--passL:-Wl,-rpath,/runtime/one:/runtime/two"
      ]
      check runtimeRpathCompilerFlags(dirs, rltDarwin) == @[
        "--passL:-Wl,-rpath,/runtime/one",
        "--passL:-Wl,-rpath,/runtime/two"
      ]
      check runtimeRpathCompilerFlags(dirs, rltOtherPosix) == @[
        "--passL:-Wl,-rpath,/runtime/one",
        "--passL:-Wl,-rpath,/runtime/two"
      ]
      check runtimeRpathCompilerFlags(@["", ""], rltLinux).len == 0
      check runtimeRpathCompilerFlags(@["", ""], rltDarwin).len == 0
      let packagedRuntimeDirs = @[
        "/runtime/blake3/lib",
        "/runtime/xxhash/lib",
        "/runtime/sqlite/lib",
        "/runtime/openssl/lib",
        "/runtime/zstd/lib",
        "/runtime/clingo/lib"
      ]
      check runtimeRpathCompilerFlags(packagedRuntimeDirs, rltLinux) == @[
        "--passL:-Wl,--disable-new-dtags",
        "--passL:-Wl,-rpath," & packagedRuntimeDirs.join(":")
      ]
      check runtimeRpathCompilerFlags(packagedRuntimeDirs, rltDarwin) ==
        packagedRuntimeDirs.mapIt("--passL:-Wl,-rpath," & it)

    test "immutable source, atomic concurrent CWDs, and failure cleanup":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-compiler-scratch-", "")
      let sourceRoot = tempRoot / "immutable-source"
      let projectRoot = sourceRoot / "project"
      let outputRoot = tempRoot / "output"
      let scratchRoot = tempRoot / "writable scratch [concurrent]"
      let compilerObserver = tempRoot / "nim-observer.sh"
      let cwdLog = tempRoot / "compiler-cwds.log"
      createDir(projectRoot)
      createDir(outputRoot)
      createDir(scratchRoot)
      createSymlink(repoRoot / "libs", sourceRoot / "libs")
      let modulePath = projectRoot / "reprobuild.nim"
      writeFile(modulePath, providerBody)
      writeFile(cwdLog, "")
      writeCompilerObserver(compilerObserver, cwdLog)

      let oldCompiler = getEnv("REPRO_NIM_COMPILER")
      let oldMode = getEnv("REPRO_PROVIDER_NIMCACHE_MODE")
      let oldFail = getEnv("REPRO_TEST_NIM_FAIL")
      let oldFake = getEnv("REPRO_TEST_FAKE_PROVIDER")
      let oldRuntimeRpath = getEnv("REPROBUILD_RUNTIME_LIBRARY_PATH")
      let oldTmpDir = getEnv("TMPDIR")
      defer:
        putEnv("REPRO_NIM_COMPILER", oldCompiler)
        putEnv("REPRO_PROVIDER_NIMCACHE_MODE", oldMode)
        putEnv("REPRO_TEST_NIM_FAIL", oldFail)
        putEnv("REPRO_TEST_FAKE_PROVIDER", oldFake)
        putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", oldRuntimeRpath)
        if oldTmpDir.len > 0: putEnv("TMPDIR", oldTmpDir) else: delEnv("TMPDIR")
        setFilePermissions(modulePath, {fpUserRead, fpUserWrite})
        setFilePermissions(projectRoot,
          {fpUserRead, fpUserWrite, fpUserExec})
        setFilePermissions(sourceRoot,
          {fpUserRead, fpUserWrite, fpUserExec})
        removeDir(tempRoot)
      putEnv("REPRO_NIM_COMPILER", compilerObserver)
      putEnv("REPRO_PROVIDER_NIMCACHE_MODE", "per-binary")

      # Model an immutable package/source closure. The symlinked library tree
      # is read-only input too; no permission change reaches its target.
      setFilePermissions(modulePath, {fpUserRead})
      setFilePermissions(projectRoot, {fpUserRead, fpUserExec})
      setFilePermissions(sourceRoot, {fpUserRead, fpUserExec})

      let interfacePath = outputRoot / "fixture-interface.rbsz"
      let stubPath = outputRoot / "fixture-interface.nim"
      let interfaceArtifact = extractInterfaceFromModule(modulePath,
        interfacePath, stubPath, sourceRoot, scratchRoot)
      check fileExists(interfacePath)
      check fileExists(stubPath)
      check transientChildren(scratchRoot / "m7-temp",
        "repro-interface-extract-").len == 0
      # The runner SOURCE is content-keyed and deliberately persists: one file
      # per distinct runner source, never one per invocation, with its
      # search-path script beside it. Its staging file is the only transient
      # thing left in this directory.
      check transientChildren(scratchRoot / "m7-temp",
        "extract_runner_stage_").len == 0
      check runnerFiles(scratchRoot / "m7-temp") == (sources: 1, scripts: 1)

      # A forced compiler failure still removes the extractor's private CWD.
      putEnv("REPRO_TEST_NIM_FAIL", "1")
      expect OSError:
        discard extractInterfaceFromModule(modulePath,
          outputRoot / "failed-interface.rbsz",
          outputRoot / "failed-interface.nim", sourceRoot, scratchRoot)
      putEnv("REPRO_TEST_NIM_FAIL", "")
      check transientChildren(scratchRoot / "m7-temp",
        "repro-interface-extract-").len == 0
      # Still ONE: the second extraction names the same module, so it derives
      # the same content key and reuses the file the first one published.
      check transientChildren(scratchRoot / "m7-temp",
        "extract_runner_stage_").len == 0
      check runnerFiles(scratchRoot / "m7-temp") == (sources: 1, scripts: 1)

      # Use a lightweight compiler response for the concurrency assertion; the
      # extractor above already exercised the real compiler. Each call still
      # traverses the real provider plan/source discovery and hashes its output.
      # Warm the process-global compiler identity before starting threads so
      # the audit below records compile invocations, not concurrent --version
      # probes (and so the identity cache itself is not the subject under test).
      let runtimeRpath = (tempRoot / "runtime lib one") & $PathSep &
        (tempRoot / "runtime-lib-two")
      putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", runtimeRpath)
      let warmPlan = providerCompilePlan(modulePath,
        outputRoot / "warm-plan-only", interfaceArtifact.interfaceFingerprint,
        sourceRoot, scratchRoot)
      when defined(linux):
        check warmPlan.compilerCommand.contains(
          "--passL:-Wl,-rpath," & runtimeRpath)
        check warmPlan.compilerCommand.contains(
          "--passL:-Wl,--disable-new-dtags")
      elif defined(macosx):
        check warmPlan.compilerCommand.contains(
          "--passL:-Wl,-rpath," & (tempRoot / "runtime lib one"))
        check warmPlan.compilerCommand.contains(
          "--passL:-Wl,-rpath," & (tempRoot / "runtime-lib-two"))
      putEnv("REPRO_TEST_FAKE_PROVIDER", "1")
      writeFile(cwdLog, "")
      let jobA = CompileJob(
        modulePath: modulePath,
        outputPath: outputRoot / "provider-a",
        artifactPath: outputRoot / "provider-a.rbsz",
        workDir: sourceRoot,
        scratchDir: scratchRoot,
        interfaceFingerprint: interfaceArtifact.interfaceFingerprint,
        errorPath: outputRoot / "provider-a.error")
      let jobB = CompileJob(
        modulePath: modulePath,
        outputPath: outputRoot / "provider-b",
        artifactPath: outputRoot / "provider-b.rbsz",
        workDir: sourceRoot,
        scratchDir: scratchRoot,
        interfaceFingerprint: interfaceArtifact.interfaceFingerprint,
        errorPath: outputRoot / "provider-b.error")
      var threadA, threadB: Thread[CompileJob]
      createThread(threadA, compileInThread, jobA)
      createThread(threadB, compileInThread, jobB)
      joinThread(threadA)
      joinThread(threadB)
      check not fileExists(jobA.errorPath)
      check not fileExists(jobB.errorPath)
      check fileExists(jobA.outputPath)
      check fileExists(jobB.outputPath)
      let concurrentCwds = readFile(cwdLog).splitLines().filterIt(it.len > 0)
      check concurrentCwds.len == 2
      check concurrentCwds[0] != concurrentCwds[1]
      for compilerCwd in concurrentCwds:
        check compilerCwd.parentDir == scratchRoot
        check compilerCwd.extractFilename.startsWith("provider-compiler-cwd-")
        check not dirExists(compilerCwd)
      check transientChildren(scratchRoot, "provider-compiler-cwd-").len == 0

      # Provider failure has the same cleanup guarantee.
      putEnv("REPRO_TEST_NIM_FAIL", "1")
      putEnv("REPRO_TEST_FAKE_PROVIDER", "")
      expect OSError:
        discard compileProviderBinary(modulePath,
          outputRoot / "provider-failed",
          interfaceArtifact.interfaceFingerprint,
          outputRoot / "provider-failed.rbsz", sourceRoot, scratchRoot)
      check transientChildren(scratchRoot, "provider-compiler-cwd-").len == 0

      # No response, cache, output, or artifact was written below immutable
      # input. Only the fixture module and library symlink exist there.
      check toSeq(walkDir(projectRoot)).mapIt(it.path.extractFilename) ==
        @["reprobuild.nim"]

      # Bypassing the complete artifact cache must still preserve the public
      # interface and scratch isolation. C-object reuse alone is not a safety
      # contract: Nim's incremental check misses local header changes (below).
      putEnv("REPRO_TEST_NIM_FAIL", "")
      putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", oldRuntimeRpath)
      putEnv("REPRO_PROVIDER_NIMCACHE_MODE", "shared")
      # The shared interface nimcache lives under the temporary directory
      # (`interfaceExtractionNimcacheRoot`), outside any scratch or
      # action-cache root. A private one keeps the object counts below about
      # this fixture alone.
      createDir(tempRoot / "tmp")
      putEnv("TMPDIR", tempRoot / "tmp")

      let first = extractInterfaceFromModule(modulePath,
        outputRoot / "first.rbsz", outputRoot / "first.nim", sourceRoot,
        scratchRoot, useExtractionCache = false, consumerRoot = projectRoot)
      # EVERY object, the extraction runner's own included. That exclusion used
      # to be here, and it is what let the defect hide: the runner's module was
      # allocated a fresh random basename per invocation, so its object could
      # never be reused and its predecessor was never removed -- one rebuilt
      # object and three orphaned cache entries on every single warm run, with
      # no reaper. The runner source is content-keyed now, so the runner has
      # exactly one object here and it is subject to the same reuse claim as
      # everything else in the directory.
      var objectTimes = initTable[string, Time]()
      for path in walkDirRec(interfaceExtractionNimcacheRoot()):
        if path.endsWith(".o"):
          objectTimes[path] = getLastModificationTime(path)
      require objectTimes.len >= 4
      writeFile(cwdLog, "")
      let second = extractInterfaceFromModule(modulePath,
        outputRoot / "second.rbsz", outputRoot / "second.nim", sourceRoot,
        scratchRoot, useExtractionCache = false, consumerRoot = projectRoot)
      check first.interfaceFingerprint == second.interfaceFingerprint
      var rebuilt = 0
      for path, modified in objectTimes:
        if not fileExists(path) or getLastModificationTime(path) != modified:
          inc rebuilt
      var objectsAfter = 0
      for path in walkDirRec(interfaceExtractionNimcacheRoot()):
        if path.endsWith(".o"):
          inc objectsAfter
      checkpoint "shared objects: " & $objectTimes.len & ", rebuilt: " &
        $rebuilt & ", after: " & $objectsAfter
      # ASSERTED, not merely reported. These lines used to be a checkpoint
      # alone, so a warm extraction that rebuilt objects printed a number and
      # passed.
      check rebuilt == 0
      # AND THE SECOND HALF, WITHOUT WHICH THE FIRST IS VACUOUS HERE.
      # ``rebuilt`` ranges over the objects that existed BEFORE the warm run,
      # so it can only see an object that was touched or deleted. The defect
      # this test now covers was neither: the runner's module had a fresh
      # random basename every invocation, so a warm extraction ADDED
      # ``@mextract_runner_<rand>.nim.c.o`` beside its predecessor and left
      # both. Measured against the pre-fix code this case reported
      # "rebuilt: 0" and passed while the directory grew every run. Only the
      # COUNT catches it.
      check objectsAfter == objectTimes.len
      let compilerCwds = readFile(cwdLog).splitLines().filterIt(it.len > 0)
      # Two compiler processes per extraction: the `nim dump` that reads the
      # recipe's configuration search paths, and the compile. BOTH run in the
      # extraction's one private directory, never in the caller's.
      checkpoint "compiler cwds: " & $compilerCwds
      check compilerCwds.len == 2
      for compilerCwd in compilerCwds:
        check compilerCwd.parentDir == scratchRoot / "m7-temp"
        check compilerCwd.extractFilename.startsWith("repro-interface-extract-")
        check not dirExists(compilerCwd)
      check transientChildren(scratchRoot / "m7-temp",
        "repro-interface-extract-").len == 0
      check transientChildren(scratchRoot / "m7-temp",
        "extract_runner_stage_").len == 0
      check runnerFiles(scratchRoot / "m7-temp") == (sources: 1, scripts: 1)

      # Keep the process-wide compiler observer alive for this regression too.
      block:
        let root = createTempDir("repro-interface-header-change-", "")
        defer: removeDir(root)
        let source = root / "repro.nim"
        let header = root / "value.h"
        let expected = root / "expected.txt"
        writeFile(source, "import std/strutils\nimport repro_project_dsl\n" &
          "proc headerValue(): cint {.importc: \"header_value\", header: " &
          ("\"" & header & "\"").escape & ".}\n" &
          "doAssert $headerValue() == readFile(" & expected.escape & ").strip()\n" &
          "package headerFixture:\n  build:\n    discard\n")
        for value in [11, 23]:
          checkpoint "interface C header value: " & $value
          writeFile(header, "static inline int header_value(void) { return " &
            $value & "; }\n")
          writeFile(expected, $value)
          let artifactPath = root / ($value & ".rbsz")
          discard extractInterfaceFromModule(source, artifactPath,
            root / ($value & ".nim"), getCurrentDir(), root / "scratch",
            useExtractionCache = false, consumerRoot = root)
          check fileExists(artifactPath)

    test "SDK dependencies outrank configuration and extra paths without losing recipe imports":
      # Real module trees and the real compiler: either competing module emits
      # a compile error if selected. Successful extraction/link must therefore
      # use the actual SDK closure, not a simulated resolver or compiler.
      let root = createTempDir("repro-sdk-path-priority-", "")
      let project = root / "consumer"
      let configured = project / "configured imports"
      let extra = project / "extra imports"
      createDir(configured / "stew")
      createDir(extra)
      createDir(root / "scratch")
      createDir(root / "tmp")
      let oldTmp = getEnv("TMPDIR")
      let oldCache = getEnv("XDG_CACHE_HOME")
      putEnv("TMPDIR", root / "tmp")
      putEnv("XDG_CACHE_HOME", root / "cache")
      defer:
        if oldTmp.len > 0: putEnv("TMPDIR", oldTmp) else: delEnv("TMPDIR")
        if oldCache.len > 0: putEnv("XDG_CACHE_HOME", oldCache)
        else: delEnv("XDG_CACHE_HOME")
        removeDir(root)
      writeFile(configured / "stew/ptrops.nim",
        "{.error: \"consumer stew must not replace the SDK dependency\".}\n")
      writeFile(extra / "repro_core.nim",
        "{.error: \"extra path must not replace the SDK library\".}\n")
      writeFile(configured / "config_only.nim", "const configValue* = 37\n")
      writeFile(extra / "extra_only.nim", "const extraValue* = 19\n")
      writeFile(project / "config.nims", "switch(\"path\", " &
        configured.escape & ")\nswitch(\"define\", \"recipeConfigurationOnly\")\n")
      let modulePath = project / "repro.nim"
      writeFile(modulePath, """
import repro_project_dsl
import config_only, extra_only
static:
  doAssert configValue == 37 and extraValue == 19
when defined(reproInterfaceMode):
  static: doAssert not defined(recipeConfigurationOnly)
when defined(reproProviderMode):
  static: doAssert defined(recipeConfigurationOnly)
package namespaceFixture:
  build:
    discard
""")
      let artifact = root / "interface.rbsz"
      var extracted = false
      try:
        discard extractInterfaceFromModule(modulePath, artifact,
          root / "interface.nim", getCurrentDir(), root / "scratch",
          extraPaths = @[extra], useExtractionCache = false,
          consumerRoot = project)
        extracted = true
      except OSError as err:
        checkpoint(err.msg)
      check extracted
      check fileExists(artifact)
      let binary = root / "provider"
      let command = providerCompileCommand(modulePath, binary, getCurrentDir(),
        root / "scratch", extraFlags = @["--path:" & extra])
      let compiled = repro_interface_artifacts.runCommand(command,
        cwd = root / "scratch", raiseOnFailure = false)
      checkpoint(compiled.output)
      check compiled.exitCode == 0
      check fileExists(binary)

# ---------------------------------------------------------------------------
# The SDK roots' reassertion leaves the command line (reprobuild-pm issue
# 2026-10-30-windows-sdk-interface-compiler-command-exceeds-createprocess-
# limit). `splitSearchPathReassertion` moves each `--excludePath:<root>` /
# `--path:<root>` pair into a NimScript beside the main module. The two
# suites below check, with the real compiler and no mocks, that this changes
# nothing nim resolves, and that an extraction whose command line would be
# over Windows' limit compiles.

proc nimDumpSearchPaths(argv: openArray[string]; cwd: string): seq[string] =
  ## The search path nim ends up with for `argv` (a `nim dump` command), in
  ## probe order, as `nim dump --dump.format:json` reports it.
  let run = repro_interface_artifacts.runCommand(argv, cwd = cwd,
    raiseOnFailure = false)
  doAssert run.exitCode == 0, "nim dump failed:\n" & run.output
  let first = run.output.find('{')
  let last = run.output.rfind('}')
  doAssert first >= 0 and last > first, "nim dump printed no JSON"
  for node in parseJson(run.output[first .. last])["lib_paths"].getElems():
    result.add(node.getStr())

suite "the search-path script gives nim the search path the command line gives":
  test "kept roots, reasserted roots and a configuration that touches both":
    let nimExe = findExe("nim")
    doAssert nimExe.len > 0, "no nim on PATH"
    let root = createTempDir("repro-search-path-script-", "")
    defer: removeDir(root)
    # A space in every directory: the script's literals must carry it.
    let runnerDir = root / "runner dir"
    let keptOne = root / "kept one"
    let keptTwo = root / "kept two"
    let sdkOne = root / "sdk one"
    let sdkTwo = root / "sdk two"
    let configured = root / "configured by the runner dir"
    for dir in [runnerDir, keptOne, keptTwo, sdkOne, sdkTwo, configured]:
      createDir(dir)
    let main = runnerDir / "main.nim"
    writeFile(main, "discard\n")
    # The configuration the reassertion exists for: it adds a root of its own
    # (which then sits in front of every command-line root), removes a kept
    # root (which the command line's second pass re-adds) and adds a
    # reasserted root early.
    writeFile(runnerDir / "config.nims",
      "switch(\"path\", " & configured.escape & ")\n" &
      "switch(\"excludePath\", " & keptTwo.escape & ")\n" &
      "switch(\"path\", " & sdkOne.escape & ")\n")
    let logical = @[nimExe, "dump", "--dump.format:json", "--hints:off",
      "--warnings:off", "--path:" & keptOne, "--path:" & keptTwo,
      "--excludePath:" & sdkOne, "--excludePath:" & sdkTwo,
      "--path:" & sdkOne, "--path:" & sdkTwo, main]
    let launch = splitSearchPathReassertion(logical, main)
    check launch.movedArguments == 4
    let script = nimSearchPathScriptPath(main)

    let expected = nimDumpSearchPaths(logical, root)
    # Not vacuous: the reassertion put both SDK roots in front of the
    # configuration's root, and the kept roots after it.
    check expected.find(sdkTwo) == 0
    check expected.find(sdkOne) == 1
    check expected.find(configured) > expected.find(sdkOne)
    check expected.find(keptOne) > expected.find(configured)
    check expected.find(keptTwo) >= 0

    writeFile(script, launch.script)
    let split = nimDumpSearchPaths(launch.argv, root)
    # Equal, entry for entry, except that evaluating the script appends one
    # more copy of the standard library's root at the very end (every
    # NimScript run does; see `nim_search_path_script`). A duplicate behind
    # an earlier copy of the same directory cannot resolve anything
    # differently, so only that is allowed: the logical search path is a
    # prefix of the split one, and what follows it is already in it.
    checkpoint("logical: " & $expected)
    checkpoint("split:   " & $split)
    check split.len >= expected.len
    check split[0 ..< min(split.len, expected.len)] == expected
    for extra in split[min(split.len, expected.len) .. ^1]:
      check extra in expected
    check split.deduplicate == expected.deduplicate

    # And the script is what makes them equal: the same launch command
    # without it leaves sdkTwo off the path entirely.
    removeFile(script)
    let withoutScript = nimDumpSearchPaths(launch.argv, root)
    check withoutScript != expected
    check sdkTwo notin withoutScript

suite "the recipe's configuration search paths leave out nim's own library":
  test "a recipe configuration's path is kept and no standard-library directory is":
    # `recipeConfigSearchPathFlags` replays the search paths a recipe's own
    # configuration adds, minus the standard library's directories, which
    # every compile has anyway. `nim dump` spells them in the host's
    # separator; a filter that only knew `/` let all of them through on
    # Windows, onto the extraction's command line and in reverse order.
    let nimExe = findExe("nim")
    doAssert nimExe.len > 0, "no nim on PATH"
    let root = createTempDir("repro-recipe-config-paths-", "")
    defer: removeDir(root)
    let recipeDir = root / "recipe"
    let added = root / "added by the recipe"
    createDir(recipeDir)
    createDir(added)
    writeFile(recipeDir / "config.nims",
      "switch(\"path\", " & added.escape & ")\n")
    let recipe = recipeDir / "repro.nim"
    writeFile(recipe, "discard\n")

    # Nim's own prefix and library directories, from the same compiler.
    let dump = repro_interface_artifacts.runCommand(@[nimExe, "dump",
      "--dump.format:json", "--hints:off", "--warnings:off", recipe],
      cwd = root, raiseOnFailure = false)
    doAssert dump.exitCode == 0, "nim dump failed:\n" & dump.output
    let doc = parseJson(dump.output[dump.output.find('{') ..
      dump.output.rfind('}')])
    proc spelled(path: string): string =
      ## Separator- and (for Windows) case-neutral, independent of the
      ## production predicate.
      path.replace('\\', '/').strip(leading = false, chars = {'/'}).toLowerAscii
    let prefix = spelled(doc["prefixdir"].getStr())
    var stdlibDirs = 0
    for node in doc["lib_paths"].getElems():
      if spelled(node.getStr()).startsWith(prefix & "/"):
        inc stdlibDirs
    # Not vacuous: there were standard-library directories to leave out.
    check prefix.len > 0
    check stdlibDirs > 0

    let flags = recipeConfigSearchPathFlags(recipe, cwd = root)
    checkpoint($flags)
    check ("--path:" & added) in flags
    for flag in flags:
      check flag.startsWith("--path:")
      check not spelled(flag["--path:".len .. ^1]).startsWith(prefix & "/")

when defined(windows):
  import std/winlean

  suite "interface extraction beyond the Windows command-line limit":
    test "an extraction whose SDK reassertion alone is over 32,767 characters compiles":
      # The SDK is this checkout's `libs/`, rebuilt in a temporary directory
      # from one directory junction per library, plus empty padding
      # libraries whose `src` roots are reasserted like every other root.
      # Paths stay short (no MAX_PATH pressure); the NUMBER of roots puts the
      # reassertion over Windows' limit, as a growing SDK does. Before the
      # reassertion moved to the runner's NimScript this extraction failed
      # with `CreateProcessW failed (206)` before nim started.
      let checkout = currentSourcePath().parentDir().parentDir().parentDir()
      let root = createTempDir("repro-long-sdk-", "")
      let sdk = root / "sdk"
      createDir(sdk / "libs")
      var junctions: seq[string]
      defer:
        # Unlink each junction with RemoveDirectoryW, which removes the link
        # and never enters it, and delete the temporary tree only when every
        # one is gone: `removeDir` would walk THROUGH a junction into the
        # checkout.
        var allGone = true
        for junction in junctions:
          discard removeDirectoryW(newWideCString(junction))
          if dirExists(junction):
            allGone = false
        if allGone:
          removeDir(root)
        else:
          echo "left ", root, " in place: a junction could not be removed"
      for kind, path in walkDir(checkout / "libs"):
        if kind != pcDir:
          continue
        let junction = sdk / "libs" / path.extractFilename
        let made = repro_interface_artifacts.runCommand(
          @["cmd.exe", "/d", "/c", "mklink", "/J", junction, path],
          raiseOnFailure = false)
        checkpoint(made.output)
        doAssert made.exitCode == 0, "could not create the junction " & junction
        junctions.add(junction)
      for i in 0 ..< 160:
        createDir(sdk / "libs" / ("padding_library_with_a_long_name_" & $i) /
          "src")
      # A lower bound on the compile's logical command line: every
      # `libs/*/src` root is reasserted, once excluded and once re-added.
      var reassertion = 0
      for kind, path in walkDir(sdk / "libs"):
        if dirExists(path / "src"):
          let srcRoot = path / "src"
          inc reassertion, quoteShellWindows("--excludePath:" & srcRoot).len +
            quoteShellWindows("--path:" & srcRoot).len + 2
      checkpoint("reassertion of the SDK roots: " & $reassertion &
        " characters")
      check reassertion > 32_767
      let project = root / "consumer"
      createDir(project)
      createDir(root / "scratch")
      let modulePath = project / "repro.nim"
      writeFile(modulePath, providerBody)
      let artifact = root / "interface.rbsz"
      var extracted = false
      try:
        discard extractInterfaceFromModule(modulePath, artifact,
          root / "interface.nim", sdk, root / "scratch",
          useExtractionCache = false, consumerRoot = project)
        extracted = true
      except OSError as err:
        checkpoint(err.msg)
      check extracted
      check fileExists(artifact)
