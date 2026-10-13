## Direct Nim-invocation + JSON->RBPI bridge for the M83 profile-compile
## path.
##
## This module is the "interior" of the compile step — the bit that
## actually runs `nim c` against the user's profile source and converts
## the emitted JSON `ProfileIntent` into the RBPI binary envelope. It is
## invoked directly by tests and by the internal
## `__repro-compile-profile` helper subcommand; the BuildAction-based
## edge in `edge.nim` wraps it so the build engine can cache the result.
##
## DEVIATION from a literal "binary emit" pipeline: the Phase A
## `repro_profile` library emits JSON on stdout. We deliberately do NOT
## change that surface (it would risk regressing every Phase A gate);
## instead we capture the JSON, parse it via `parseProfileIntentJson`,
## and re-encode through `encodeRbpi` (Phase B). The JSON ->
## ProfileIntent -> RBPI round-trip is lossless by construction.

import std/[os, osproc, streams, strtabs, strutils]
from repro_core/paths import extendedPath
from repro_core/process_streams import drainStream

import repro_profile
import repro_profile_intent

import ./sources

# ---------------------------------------------------------------------------
# Errors.
# ---------------------------------------------------------------------------

type
  CompileFailure* = object of CatchableError
    stderrText*: string

const ProfileNimCompilerEnvVar* = "REPRO_NIM_COMPILER"
  ## The compiler an installed `repro` was built with. The Nix package's
  ## wrapper sets it to the fork (`package.nix`), and the provider compile
  ## already honours it (`repro_interface_artifacts.nimCompilerPath`).

proc resolveProfileNimCompiler*(): string =
  ## The `nim` that compiles a profile: `$REPRO_NIM_COMPILER` when set, the
  ## first `nim` on `PATH` otherwise — the provider compile's order, so one
  ## installed `repro` compiles its recipes and its profiles with the same
  ## compiler (the profile imports the very libs that compiler built the
  ## binary from).
  ##
  ## An explicit `$REPRO_NIM_COMPILER` that names no file is refused rather
  ## than quietly replaced by whatever `PATH` offers: the variable is the
  ## caller's stated choice, and silently compiling with a different
  ## compiler is the failure it exists to prevent.
  let explicit = getEnv(ProfileNimCompilerEnvVar)
  if explicit.len > 0:
    # A bare command name (no directory part) is looked up on PATH, as the
    # provider compile's launcher (`poUsePath`) would; it still has to
    # resolve, so a typo is refused here rather than at spawn time.
    if explicit.extractFilename == explicit:
      let resolved = findExe(explicit)
      if resolved.len > 0:
        return resolved
    if not fileExists(extendedPath(explicit)):
      raise newException(CompileFailure,
        "repro profile compile: $" & ProfileNimCompilerEnvVar & "=" & explicit &
        " does not name an existing file. Point it at a Nim compiler, or " &
        "unset it to use the `nim` on PATH.")
    return explicit
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(CompileFailure,
      "repro profile compile: no Nim compiler. Set $" & ProfileNimCompilerEnvVar &
      " (an installed `repro` package sets it), or put Nim >= 2.0 " &
      "(https://nim-lang.org/install.html) on PATH, and retry.")
  nimExe

proc requireReprobuildSources*(repoRoot: string) =
  ## Refuse a source root that holds no reprobuild libs, naming the
  ## variables that select one. Without this the failure surfaced as
  ## `setCurrentDir` on a path nobody chose — the build sandbox baked into
  ## `CompiledRepoRoot`.
  if not dirExists(extendedPath(repoRoot / LibsDirName / "repro_profile" /
      "src")):
    raise newException(CompileFailure,
      "repro profile compile: no reprobuild sources at " & repoRoot &
      " (expected " & LibsDirName & "/repro_profile/src). An installed " &
      "package names them in $REPROBUILD_SOURCE_ROOT; a checkout can be " &
      "selected with $REPROBUILD_REPO_ROOT.")

proc profileCompileArgv*(nimExe, profileRoot, nimcacheDir, outBinary,
                         repoRoot: string): seq[string] =
  ## The `nim c` command line for a profile compile, as an argv sequence.
  ##
  ## Built as a sequence and handed to the process launcher unchanged. It
  ## used to be one string assembled with `quoteShell` and split again with
  ## `parseCmdLine`; on POSIX `quoteShell` quotes with single quotes, which
  ## `parseCmdLine` does not honour, so any path with a space came apart —
  ## and the macOS default state directory (`~/Library/Application
  ## Support/repro/home`) puts one in the nimcache path of every apply:
  ## `Error: arguments can only be given if the '--run' option is selected`.
  ## Each element below is one argument whatever characters it holds.
  result = @[nimExe, "c", "--hints:off", "--warnings:off",
    "--nimcache:" & nimcacheDir,
    "--out:" & outBinary]
  for path in profileNimPaths(repoRoot):
    result.add "--path:" & path
  result.add profileRoot

# ---------------------------------------------------------------------------
# Direct Nim invocation (two-phase: `nim c` then run the binary).
# ---------------------------------------------------------------------------

proc compileProfileBinary*(profileRoot, nimcacheDir, outBinary: string;
                           repoRoot: string;
                           verbose: bool = false): tuple[
    jsonOutput: string; stderrText: string] =
  ## Two-phase invocation: `nim c` (no `-r`) emits the binary, then we
  ## run it directly. The split keeps Nim's diagnostic
  ## chatter on stderr and the profile binary's stdout JSON on stdout.
  ## Raises `CompileFailure` if either step exits non-zero.
  let nimExe = resolveProfileNimCompiler()
  let repoRootAbs = absolutePath(repoRoot)
  requireReprobuildSources(repoRootAbs)
  createDir(extendedPath(nimcacheDir))
  createDir(extendedPath(outBinary.parentDir))

  # Stage a wrapper config.nims next to the profile so nim's parent-walk
  # picks it up and pulls in reprobuild's config.nims (which resolves
  # sibling-repo paths from env vars: NIMCRYPTO_SRC, BEARSSL_SRC, IO_MON_SRC,
  # etc.). Without this, a profile at e.g. C:\Users\admin\reprobuild-source\
  # never sees reprobuild's config.nims, and transitive imports of
  # repro_project_dsl -> nimcrypto/sha2 fail with "cannot open file".
  let profileDir = profileRoot.parentDir
  let stagedConfig = profileDir / "config.nims"
  let upstreamConfig = repoRootAbs / "config.nims"
  var didStageConfig = false
  if fileExists(extendedPath(upstreamConfig)) and
     not fileExists(extendedPath(stagedConfig)):
    writeFile(extendedPath(stagedConfig),
      "include \"" & upstreamConfig.replace('\\', '/') & "\"\n")
    didStageConfig = true

  let nimArgv = profileCompileArgv(nimExe, profileRoot, nimcacheDir,
    outBinary, repoRootAbs)
  if verbose:
    stderr.writeLine("repro profile compile: " & nimArgv.join(" "))

  try:
    # NimScript's relative path resolution from a config.nims runs in
    # the PROJECT (profile) directory's CWD — not nim's process CWD.
    # So even with ``workingDir = repoRoot`` (which sets the OS
    # cwd), the upstream config.nims's ``addPackagePath`` calls like
    #
    #   addPackagePath("NIMCRYPTO_SRC", [
    #     "libs" / "nimcrypto",
    #     ".." / "codetracer" / "libs" / "nimcrypto",
    #     ".." / "nimcrypto"], "nimcrypto" / "hash.nim")
    #
    # check ``fileExists(candidate / marker)`` relative to the profile
    # dir — where none of the candidates exist — and the package path
    # never gets added. The transitive ``import nimcrypto/sha2`` from
    # ``repro_project_dsl`` then fails.
    #
    # Pass the env-var-keyed paths the upstream config.nims expects
    # so its FIRST lookup (``getEnv(envName)``) hits before the
    # relative-path candidates run.
    var childEnv = newStringTable(modeStyleInsensitive)
    for k, v in envPairs():
      childEnv[k] = v
    # Mirrors the addPackagePath calls in reprobuild's config.nims —
    # absolute paths pointing at the operator's existing sibling
    # checkouts under <repoRoot>'s parent. (install-reprobuild.ps1
    # clones every sibling under <LOCALAPPDATA>/dev-deps/reprobuild/,
    # so they are siblings of ``src/``.)
    proc setPackageEnv(envName: string; candidates: openArray[string];
                       marker: string) =
      if getEnv(envName).len > 0:
        return
      for candidate in candidates:
        if fileExists(candidate / marker):
          childEnv[envName] = candidate
          return

    let dd = repoRootAbs.parentDir  # <dev-deps>/reprobuild
    setPackageEnv("NIMCRYPTO_SRC", [
      repoRootAbs / "libs" / "nimcrypto",
      dd / "codetracer" / "libs" / "nimcrypto",
      dd / "nimcrypto",
    ], "nimcrypto" / "hash.nim")
    setPackageEnv("BEARSSL_SRC", [
      dd / "nim-bearssl",
      repoRootAbs / "libs" / "nim-bearssl",
    ], "bearssl.nim")
    # ``repro_local_store`` imports ``shm_gset`` from the ``nim-shm-gset``
    # sibling (the action cache's Tier-2 index), and io-mon pulls
    # ``shm_queue/...`` from ``nim-shm-queue``. Neither package lives under
    # ``libs/*/src``, so ``profileNimPaths`` cannot supply them.
    # config.nims resolves both through ``$SHM_QUEUE_SRC`` / ``$SHM_GSET_SRC``
    # first, then a relative sibling probe, then a nix-devshell fallback —
    # but the relative probe runs from the PROFILE directory (see the
    # NimScript note above), and the devshell fallback is compiled out on
    # Windows (``when defined(windows): ""``). Without the env pin the
    # profile compile therefore fails on Windows with
    # ``cannot open file: shm_queue/segment``; on Linux the devshell
    # fallback happens to mask it. Pin the env vars like every other
    # sibling package.
    setPackageEnv("SHM_QUEUE_SRC", [
      dd / "nim-shm-queue" / "src",
    ], "shm_queue.nim")
    setPackageEnv("SHM_GSET_SRC", [
      dd / "nim-shm-gset" / "src",
    ], "shm_gset.nim")
    if dirExists(dd / "io-mon" / "src"):
      if getEnv("IO_MON_SRC").len == 0:
        childEnv["IO_MON_SRC"] = dd / "io-mon" / "src"
    if dirExists(dd / "runquota"):
      if getEnv("RUNQUOTA_SRC").len == 0:
        childEnv["RUNQUOTA_SRC"] = dd / "runquota"
    if dirExists(dd / "nim-stackable-hooks" / "src"):
      if getEnv("STACKABLE_HOOKS_SRC").len == 0:
        childEnv["STACKABLE_HOOKS_SRC"] = dd / "nim-stackable-hooks" / "src"
    if dirExists(dd / "codetracer" / "src" / "ct_test"):
      if getEnv("CODETRACER_CT_TEST_SRC").len == 0:
        childEnv["CODETRACER_CT_TEST_SRC"] = dd / "codetracer" / "src" / "ct_test"
    if dirExists(dd / "codetracer" / "src"):
      if getEnv("CODETRACER_SRC").len == 0:
        childEnv["CODETRACER_SRC"] = dd / "codetracer" / "src"
    if dirExists(dd / "codetracer-trace-format-nim" / "src"):
      if getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC").len == 0:
        childEnv["CODETRACER_TRACE_FORMAT_NIM_SRC"] = dd / "codetracer-trace-format-nim" / "src"
    if dirExists(dd / "reprobuild-ct-test-runner"):
      if getEnv("REPRO_CT_TEST_RUNNER_SRC").len == 0:
        childEnv["REPRO_CT_TEST_RUNNER_SRC"] = dd / "reprobuild-ct-test-runner"
    if dirExists(dd / "reprobuild-test-adapters" / "src"):
      if getEnv("REPRO_TEST_ADAPTERS_SRC").len == 0:
        childEnv["REPRO_TEST_ADAPTERS_SRC"] = dd / "reprobuild-test-adapters" / "src"

    var p = startProcess(nimArgv[0], workingDir = repoRootAbs,
                         args = nimArgv[1 .. ^1],
                         env = childEnv,
                         options = {poUsePath, poStdErrToStdOut})
    # N51: a `nim c` transcript is the single most short-read-prone capture
    # in this tree — the compiler writes progress chatter in many small
    # bursts, and `readAll` ends at the first burst under 1 KiB. `err.stderrText`
    # below is the ONLY thing a user sees when a profile fails to compile.
    let output = drainStream(p.outputStream)
    let exitCode = p.waitForExit()
    p.close()
    let compileRes = (output: output, exitCode: exitCode)
    if compileRes.exitCode != 0:
      var err = new CompileFailure
      err.msg = "nim compile failed for " & profileRoot &
        " (exit " & $compileRes.exitCode & ")"
      err.stderrText = compileRes.output
      raise err

    # Run the profile binary directly, not through a shell, for the same
    # reason the compile is an argv: the binary sits under the nimcache, so
    # its path carries any space the state directory has. stderr is merged
    # into the captured output as `execCmdEx` did before, so a profile that
    # fails keeps reporting its diagnostics.
    var runProc = startProcess(outBinary, args = [],
                               options = {poStdErrToStdOut})
    let runOutput = drainStream(runProc.outputStream)
    let runExit = runProc.waitForExit()
    runProc.close()
    let runRes = (output: runOutput, exitCode: runExit)
    if runRes.exitCode != 0:
      var err = new CompileFailure
      err.msg = "compiled profile binary exited " & $runRes.exitCode &
        " for " & profileRoot
      err.stderrText = runRes.output
      raise err
    result.jsonOutput = runRes.output
    result.stderrText = compileRes.output
  finally:
    if didStageConfig:
      try: removeFile(extendedPath(stagedConfig))
      except OSError: discard

proc rbpiBytesFromJson*(jsonText: string): seq[byte] =
  ## Parse the JSON ProfileIntent emitted by the compiled profile and
  ## re-encode it through the Phase B RBPI envelope. The JSON ->
  ## ProfileIntent -> RBPI round-trip is lossless.
  ##
  ## A profile binary that ran to exit 0 and printed NOTHING gets its own
  ## diagnostic rather than the JSON parser's. `parseJson("")` reports
  ## `input(1, 0) Error: { expected`, which names a position in a document
  ## that does not exist and sends the reader looking for a syntax error in
  ## their profile. The real cause is upstream and structural — the module
  ## never reached the `ProfileIntent` emitter (an empty or comment-only
  ## profile, a `main` that returns early, output swallowed by a redirect) —
  ## so say that instead. NOT silently encoded as an empty intent: an
  ## emitter that never ran is a broken profile, and inventing a
  ## zero-resource intent for it would apply "converge to nothing" to a host
  ## and report success.
  let trimmed = jsonText.strip()
  if trimmed.len == 0:
    raise newException(ValueError,
      "the compiled profile exited 0 but printed no ProfileIntent JSON on " &
      "stdout. The profile module never reached the intent emitter — an " &
      "empty or comment-only profile does exactly this.")
  let p = parseProfileIntentJson(trimmed)
  encodeRbpi(p)

# ---------------------------------------------------------------------------
# Atomic envelope publishing.
# ---------------------------------------------------------------------------

proc writeBytesAtomic*(path: string; bytes: seq[byte]) =
  ## Write `bytes` to `path` via a `<path>.tmp` rename. The parent
  ## directory is created lazily.
  let tmpPath = path & ".tmp"
  createDir(extendedPath(path.parentDir))
  let f = open(extendedPath(tmpPath), fmWrite)
  if bytes.len > 0:
    discard f.writeBuffer(unsafeAddr bytes[0], bytes.len)
  f.close()
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmpPath), extendedPath(path))

proc readBytes*(path: string): seq[byte] =
  let s = readFile(extendedPath(path))
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ord(ch))

proc cachedArtifactIsValid*(path: string): bool =
  ## Cheap structural sanity-check: read the file and confirm it parses
  ## as an RBPI envelope. Avoids returning a half-written or corrupted
  ## artifact on cache lookup.
  if not fileExists(extendedPath(path)):
    return false
  try:
    let raw = readFile(extendedPath(path))
    var bytes = newSeq[byte](raw.len)
    for i, ch in raw:
      bytes[i] = byte(ord(ch))
    discard readEnvelope(bytes)
    true
  except CatchableError:
    false
