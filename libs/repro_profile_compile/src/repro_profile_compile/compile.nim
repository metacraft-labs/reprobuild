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

import std/[os, osproc, parseutils, streams, strtabs, strutils]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent

import ./sources

# ---------------------------------------------------------------------------
# Errors.
# ---------------------------------------------------------------------------

type
  CompileFailure* = object of CatchableError
    stderrText*: string

proc requireNimOnPath*(): string =
  ## Locate the `nim` binary. Fails closed with a diagnostic pointing at
  ## the vendored-Nim follow-up phase if Nim is absent.
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    raise newException(CompileFailure,
      "repro profile compile: `nim` not found on PATH. The current " &
      "release requires Nim from PATH; vendored-Nim auto-bootstrap is " &
      "deferred to a later phase. Install Nim >= 2.0 " &
      "(https://nim-lang.org/install.html) and retry.")
  nimExe

# ---------------------------------------------------------------------------
# Direct Nim invocation (two-phase: `nim c` then run the binary).
# ---------------------------------------------------------------------------

proc compileProfileBinary*(profileRoot, nimcacheDir, outBinary: string;
                           repoRoot: string;
                           verbose: bool = false): tuple[
    jsonOutput: string; stderrText: string] =
  ## Two-phase invocation: `nim c` (no `-r`) emits the binary, then we
  ## run it directly via `execCmdEx`. The split keeps Nim's diagnostic
  ## chatter on stderr and the profile binary's stdout JSON on stdout.
  ## Raises `CompileFailure` if either step exits non-zero.
  let nimExe = requireNimOnPath()
  let repoRootAbs = absolutePath(repoRoot)
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

  var compileCmd = quoteShell(nimExe) & " c --hints:off --warnings:off" &
    " --nimcache:" & quoteShell(nimcacheDir) &
    " --out:" & quoteShell(outBinary)
  for path in profileNimPaths(repoRootAbs):
    compileCmd.add " --path:" & quoteShell(path)
  # The repo ROOT, which `profileNimPaths` deliberately does not return — it
  # enumerates `libs/*/src`. Root-level modules are nonetheless part of the
  # import graph a profile drags in: `repro_core/convention_attribution.nim`
  # imports `lints/ambient_execution`, which lives at the root.
  #
  # An ordinary build gets the root from `config.nims`'s `switch("path", ".")`.
  # A profile compile does not, and this is the same NimScript rule the note
  # below is about, hit from the other side: the config is evaluated with the
  # PROJECT directory as cwd, so `.` resolves to the profile's own directory.
  # Measured — a marker `echo` in `config.nims` during a profile compile prints
  # `thisDir=…\machines\server\_win-ci-bare-001`, i.e. the profile's directory
  # and not this repo. `thisDir()` is therefore NOT a fix; only an absolute
  # path known to the CALLER is, and `repoRootAbs` is exactly that.
  #
  # Symptom when this is missing: every COLD profile compile fails with
  # `cannot open file: lints/ambient_execution`, taking `repro infra
  # plan/apply` and the deploy agent with it, while `nim c` over the tree keeps
  # working. A warm profile cache hides it completely, so it surfaces as "the
  # box converged for weeks and then stopped accepting new desired state".
  compileCmd.add " --path:" & quoteShell(repoRootAbs)
  compileCmd.add " " & quoteShell(profileRoot)
  if verbose:
    stderr.writeLine("repro profile compile: " & compileCmd)

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
    # ``repro_local_store`` imports ``repro_shm_index``, whose ``layout.nim``
    # / ``ring.nim`` import ``shm_queue/...`` from the ``nim-shm-queue``
    # sibling (and ``shm_gset`` from ``nim-shm-gset``). Neither package
    # lives under ``libs/*/src``, so ``profileNimPaths`` cannot supply them.
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

    let nimArgv = parseCmdLine(compileCmd)
    var p = startProcess(nimArgv[0], workingDir = repoRootAbs,
                         args = nimArgv[1 .. ^1],
                         env = childEnv,
                         options = {poUsePath, poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    p.close()
    let compileRes = (output: output, exitCode: exitCode)
    if compileRes.exitCode != 0:
      var err = new CompileFailure
      err.msg = "nim compile failed for " & profileRoot &
        " (exit " & $compileRes.exitCode & ")"
      err.stderrText = compileRes.output
      raise err

    let runRes = execCmdEx(quoteShell(outBinary))
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
  let trimmed = jsonText.strip()
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
