## Regression coverage for installed-package compiler scratch isolation.
##
## Interface extraction and provider compilation consume an immutable source
## tree but must put every response file/intermediate/output in writable
## scratch. Provider compiles are also invoked concurrently in one process to
## prove their compiler CWD allocation is exclusive, not merely unlikely to
## collide.

import std/[os, sequtils, strutils, tempfiles, unittest]

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
    if kind in {pcDir, pcLinkToDir} and path.extractFilename.startsWith(prefix):
      result.add(path)

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
      defer:
        putEnv("REPRO_NIM_COMPILER", oldCompiler)
        putEnv("REPRO_PROVIDER_NIMCACHE_MODE", oldMode)
        putEnv("REPRO_TEST_NIM_FAIL", oldFail)
        putEnv("REPRO_TEST_FAKE_PROVIDER", oldFake)
        putEnv("REPROBUILD_RUNTIME_LIBRARY_PATH", oldRuntimeRpath)
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

      # A forced compiler failure still removes the extractor's private CWD.
      putEnv("REPRO_TEST_NIM_FAIL", "1")
      expect OSError:
        discard extractInterfaceFromModule(modulePath,
          outputRoot / "failed-interface.rbsz",
          outputRoot / "failed-interface.nim", sourceRoot, scratchRoot)
      putEnv("REPRO_TEST_NIM_FAIL", "")
      check transientChildren(scratchRoot / "m7-temp",
        "repro-interface-extract-").len == 0

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
