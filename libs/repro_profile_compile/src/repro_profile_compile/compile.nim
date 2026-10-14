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
from repro_core/source_root import installedLayoutPrefixOfSourceRoot,
  installedLayoutPackageTrees
from repro_core/ambient_execution import uncontrolledFindExe
from repro_core/c_compiler import CCompilerUnusableError, explicitCCompiler,
  fallbackCCompiler, nimCCompilerFlags

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

const NimDefaultCCompilerExe* =
  when defined(macosx): "clang" else: "gcc"
  ## The C compiler executable Nim runs when told none (its default `cc`
  ## family on this platform), looked up through `PATH`.

proc resolveProfileCCompiler*(): string =
  ## The C compiler the profile compile names to Nim, or "" to let Nim use
  ## its default. Built from the recipe compile's selection
  ## (`repro_core/c_compiler`):
  ##
  ## 1. an explicit choice -- `$REPRO_BOOTSTRAP_CC`, an absolute `$CC`
  ##    (`explicitCCompiler`); a `$REPRO_BOOTSTRAP_CC` naming no file is
  ##    refused, as the recipe compile refuses it;
  ## 2. otherwise "" when Nim's default compiler (`NimDefaultCCompilerExe`)
  ##    is on `PATH`: the compile then runs exactly as it always has;
  ## 3. otherwise `cc` on `PATH`, then the compiler `repro` was built with
  ##    (`fallbackCCompiler`).
  ##
  ## Why arm 3 exists: the compile used to name no compiler at all, and the
  ## Nix package's wrapper names its Nim but no C compiler, so from the
  ## installed package in a clean environment every profile compile failed
  ## with `gcc: command not found` -- although the package carries its build
  ## compiler (Gradual-Nix-To-Reprobuild-Migration GM1l).
  ##
  ## Why arm 2 sits before the recipe compile's `cc`-on-`PATH` arm: in
  ## reprobuild's own Linux dev shell `cc` is a clang and `gcc` is gcc.
  ## Measured 2026-10-14 (home-pc, x86_64-linux): naming that `cc` left the
  ## edge's FIRST run unpublished (`reasons=unblessed-entropy`: clang calls
  ## `arc4random` to name the temporary file it renames onto its `-o`
  ## output, and this edge carries no entropy blessing, see `edge.nim`); only
  ## the determinism probe admits the second identical run, so an unchanged
  ## profile hit on run 3 instead of run 2 and every cache-hit gate failed.
  ## `-fno-temp-file` removes the draw (reprobuild-pm issue
  ## 2026-10-14-clang-profile-compile-is-not-published-on-its-first-run).
  ## The recipe compile blesses compiler entropy and is unaffected. A host with
  ## Nim's default compiler keeps it; only a host without it -- where the
  ## compile could not run at all -- gets one picked.
  try:
    result = explicitCCompiler()
  except CCompilerUnusableError as err:
    raise newException(CompileFailure, "repro profile compile: " & err.msg)
  if result.len > 0:
    return
  if uncontrolledFindExe(NimDefaultCCompilerExe).len > 0:
    return ""
  result = fallbackCCompiler()

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
  # The compile resolves every source-only input (nimcrypto, bearssl,
  # io-mon, ...) through this file, which `compileProfileBinary` includes
  # from a wrapper beside the profile. A tree without it -- a release
  # archive staged before it shipped one -- would otherwise fail many
  # modules later with `cannot open file: nimcrypto/sha2`.
  if not fileExists(extendedPath(repoRoot / "config.nims")):
    raise newException(CompileFailure,
      "repro profile compile: the reprobuild sources at " & repoRoot &
      " have no config.nims, which the profile compile includes to resolve " &
      "reprobuild's source-only inputs. Reinstall repro from a release " &
      "that ships share/repro/source/config.nims, or point " &
      "$REPROBUILD_SOURCE_ROOT at a reprobuild source tree.")

const ProfileCompileDefines*: seq[string] = @[]
  ## The `-d:` symbols the profile compile passes to `nim c` beyond the ones
  ## Nim sets for the target platform. `profileCompileArgv` emits exactly
  ## these, and `repro home export` reports them as the compile-time
  ## definitions the intent was evaluated under -- one list, so the record
  ## cannot disagree with the command. Empty today: a profile sees the
  ## target's platform symbols (`linux`, `macosx`, `windows`, `amd64`, …)
  ## plus whatever its own `config.nims` defines.

proc profileCompileArgv*(nimExe, profileRoot, nimcacheDir, outBinary,
                         repoRoot: string; cCompiler = ""): seq[string] =
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
  ##
  ## `cCompiler` (from `resolveProfileCCompiler`) becomes the compiler and
  ## linker Nim uses (`nimCCompilerFlags`); "" leaves Nim's default.
  result = @[nimExe, "c", "--hints:off", "--warnings:off",
    "--nimcache:" & nimcacheDir,
    "--out:" & outBinary]
  result.add nimCCompilerFlags(cCompiler)
  for define in ProfileCompileDefines:
    result.add "-d:" & define
  for path in profileNimPaths(repoRoot):
    result.add "--path:" & path
  result.add profileRoot

proc profileCompileChildEnv*(repoRoot: string): StringTableRef =
  ## The environment the profile compile hands `nim c`: this process's own,
  ## plus the `*_SRC` source roots reprobuild's config.nims resolves its
  ## source-only inputs from, filled in only where unset. Pure apart from
  ## existence checks, so the probing is testable on a fixture tree.
  let repoRootAbs = absolutePath(repoRoot)
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
  # A local, not `result`: the probing helpers below are closures, and a
  # closure cannot capture `result`.
  var env = newStringTable(modeStyleInsensitive)
  for k, v in envPairs():
    env[k] = v
  # A value already in the child's environment -- the caller's, or one a
  # line below has filled -- is never replaced.
  proc unsetInChild(envName: string): bool =
    not env.hasKey(envName) or env[envName].len == 0

  # An INSTALLED layout first: when the source root is
  # `<prefix>/share/repro/source` (a release archive, a .deb/.rpm), the
  # source-only inputs ship beside it under `<prefix>/share/repro/src/<rel>`,
  # named by the one table both this compile and the interface/provider
  # compiles use (`repro_core/source_root.InstalledSourcePackageTrees`).
  # They are derived from the root this compile was handed, not from where
  # the running image lives, so the libs and their inputs always come from
  # the same tree. Without them a Windows release bundle's profile compile
  # had no `$BEARSSL_SRC`, `$IO_MON_SRC`, ... for config.nims to resolve
  # (Gradual-Nix-To-Reprobuild-Migration GM1w).
  let installedPrefix = installedLayoutPrefixOfSourceRoot(repoRootAbs)
  for (envName, dir) in installedLayoutPackageTrees(installedPrefix):
    if unsetInChild(envName):
      env[envName] = dir

  # Then mirror the addPackagePath calls in reprobuild's config.nims —
  # absolute paths pointing at the operator's existing sibling
  # checkouts under <repoRoot>'s parent. (install-reprobuild.ps1
  # clones every sibling under <LOCALAPPDATA>/dev-deps/reprobuild/,
  # so they are siblings of ``src/``.)
  proc setPackageEnv(envName: string; candidates: openArray[string];
                     marker: string) =
    if not unsetInChild(envName):
      return
    for candidate in candidates:
      if fileExists(candidate / marker):
        env[envName] = candidate
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
    if unsetInChild("IO_MON_SRC"):
      env["IO_MON_SRC"] = dd / "io-mon" / "src"
  if dirExists(dd / "runquota"):
    if unsetInChild("RUNQUOTA_SRC"):
      env["RUNQUOTA_SRC"] = dd / "runquota"
  if dirExists(dd / "nim-stackable-hooks" / "src"):
    if unsetInChild("STACKABLE_HOOKS_SRC"):
      env["STACKABLE_HOOKS_SRC"] = dd / "nim-stackable-hooks" / "src"
  if dirExists(dd / "codetracer" / "src" / "ct_test"):
    if unsetInChild("CODETRACER_CT_TEST_SRC"):
      env["CODETRACER_CT_TEST_SRC"] = dd / "codetracer" / "src" / "ct_test"
  if dirExists(dd / "codetracer" / "src"):
    if unsetInChild("CODETRACER_SRC"):
      env["CODETRACER_SRC"] = dd / "codetracer" / "src"
  if dirExists(dd / "codetracer-trace-format-nim" / "src"):
    if unsetInChild("CODETRACER_TRACE_FORMAT_NIM_SRC"):
      env["CODETRACER_TRACE_FORMAT_NIM_SRC"] = dd / "codetracer-trace-format-nim" / "src"
  if dirExists(dd / "reprobuild-ct-test-runner"):
    if unsetInChild("REPRO_CT_TEST_RUNNER_SRC"):
      env["REPRO_CT_TEST_RUNNER_SRC"] = dd / "reprobuild-ct-test-runner"
  if dirExists(dd / "reprobuild-test-adapters" / "src"):
    if unsetInChild("REPRO_TEST_ADAPTERS_SRC"):
      env["REPRO_TEST_ADAPTERS_SRC"] = dd / "reprobuild-test-adapters" / "src"
  env

# ---------------------------------------------------------------------------
# What every Nim invocation over a profile needs: the profile directory's
# staged `config.nims` and the child environment. Shared by the compile
# (`compileProfileBinary`) and the platform probe (`platforms.nim`), so the
# probe checks the profile in exactly the configuration it is compiled in.
# ---------------------------------------------------------------------------

proc stageProfileConfig*(profileRoot, repoRootAbs: string): string =
  ## Stage a wrapper config.nims next to the profile so nim's parent-walk
  ## picks it up and pulls in reprobuild's config.nims (which resolves
  ## sibling-repo paths from env vars: NIMCRYPTO_SRC, BEARSSL_SRC, IO_MON_SRC,
  ## etc.). Without this, a profile at e.g. C:\Users\admin\reprobuild-source\
  ## never sees reprobuild's config.nims, and transitive imports of
  ## repro_project_dsl -> nimcrypto/sha2 fail with "cannot open file".
  ##
  ## Returns the path it staged (the caller removes it with
  ## `unstageProfileConfig`), or "" when the profile directory already has a
  ## `config.nims` of its own or reprobuild has none.
  let profileDir = profileRoot.parentDir
  let stagedConfig = profileDir / "config.nims"
  let upstreamConfig = repoRootAbs / "config.nims"
  if fileExists(extendedPath(upstreamConfig)) and
     not fileExists(extendedPath(stagedConfig)):
    writeFile(extendedPath(stagedConfig),
      "include \"" & upstreamConfig.replace('\\', '/') & "\"\n")
    return stagedConfig
  ""

proc unstageProfileConfig*(staged: string) =
  if staged.len > 0:
    try: removeFile(extendedPath(staged))
    except OSError: discard

proc startProfileNim*(argv: seq[string]; repoRootAbs: string;
                      env: StringTableRef): Process =
  ## Start one `nim` invocation over a profile -- the compile's `nim c`, the
  ## platform probe's `nim dump` / `nim check` -- with stderr merged into
  ## stdout, from the reprobuild root, in `env`
  ## (`profileCompileChildEnv`). `argv[0]` is the compiler
  ## `resolveProfileNimCompiler` chose. The one place a profile's compiler is
  ## launched; finish it with `finishProfileNim`.
  startProcess(argv[0], workingDir = repoRootAbs, args = argv[1 .. ^1],
    env = env, options = {poUsePath, poStdErrToStdOut})

proc finishProfileNim*(p: Process): tuple[output: string; exitCode: int] =
  ## Drain a `startProfileNim` process, wait for it and release it.
  ##
  ## N51: a `nim c` transcript is the single most short-read-prone capture
  ## in this tree -- the compiler writes progress chatter in many small
  ## bursts, and `readAll` ends at the first burst under 1 KiB -- so the
  ## stream is drained, not read once.
  let output = drainStream(p.outputStream)
  let exitCode = p.waitForExit()
  p.close()
  (output: output, exitCode: exitCode)

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
  let cCompiler = resolveProfileCCompiler()
  let repoRootAbs = absolutePath(repoRoot)
  requireReprobuildSources(repoRootAbs)
  createDir(extendedPath(nimcacheDir))
  createDir(extendedPath(outBinary.parentDir))

  let stagedConfig = stageProfileConfig(profileRoot, repoRootAbs)
  let nimArgv = profileCompileArgv(nimExe, profileRoot, nimcacheDir,
    outBinary, repoRootAbs, cCompiler)
  if verbose:
    stderr.writeLine("repro profile compile: " & nimArgv.join(" "))

  try:
    let childEnv = profileCompileChildEnv(repoRootAbs)
    # `err.stderrText` below is the ONLY thing a user sees when a profile
    # fails to compile; `finishProfileNim` drains the whole transcript.
    let compileRes = finishProfileNim(
      startProfileNim(nimArgv, repoRootAbs, childEnv))
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
    unstageProfileConfig(stagedConfig)

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

proc rbpiEnvelopeIsValid*(path: string): bool =
  ## Structural sanity-check of a published envelope: the file exists and
  ## parses as an RBPI envelope of the current schema. Used AFTER the
  ## profile-compile edge has run, to refuse a half-written or corrupt
  ## artifact.
  ##
  ## NOT A CACHE LOOKUP. This proc used to be `cachedArtifactIsValid`, and it
  ## answered "may I skip the compile?" for an envelope named after an
  ## import-scan digest — which served the previous intent whenever a profile
  ## read something no `import` mentions. Validity of the bytes says nothing
  ## about whether they describe the profile as it stands now; only the
  ## action cache's monitored evidence does.
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
