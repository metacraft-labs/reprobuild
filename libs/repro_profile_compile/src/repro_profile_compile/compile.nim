## Direct Nim-invocation + JSON->RBPI bridge for the M83 profile-compile
## path.
##
## This module is the "interior" of the compile step — the bit that
## actually runs `nim c` against the user's profile source and converts
## the emitted JSON `ProfileIntent` into the RBPI binary envelope. The
## internal `__repro-compile-profile` helper (the compile edge's body) calls
## `compileProfileExecutable`; `edge.nim` encodes the run edge's intent
## document with `rbpiBytesFromJson`; tests call `compileProfileBinary`,
## which compiles and runs in this process.
##
## DEVIATION from a literal "binary emit" pipeline: the Phase A
## `repro_profile` library emits JSON on stdout. We deliberately do NOT
## change that surface (it would risk regressing every Phase A gate);
## instead we capture the JSON, parse it via `parseProfileIntentJson`,
## and re-encode through `encodeRbpi` (Phase B). The JSON ->
## ProfileIntent -> RBPI round-trip is lossless by construction.

import std/[os, osproc, streams, strtabs, strutils]
from repro_core/paths import extendedPath
from repro_core/process_streams import drainStream, drainStdoutAndStderr
from repro_core/source_root import installedLayoutPrefixOfSourceRoot,
  installedLayoutPackageTrees
from repro_core/ambient_execution import uncontrolledFindExe
from repro_core/c_compiler import CCompilerUnusableError, explicitCCompiler,
  fallbackCCompiler, nimCCompilerFlags, clangNoTempFileCFlags,
  cCompilerAcceptsFlags, cCompilerFamily

from repro_core/c_compiler_probe import CCompilerProbe, cCompilerProbeSource,
  cCompilerProbeArgv, cCompilerUnusableMessageFor

import repro_profile
import repro_profile_intent

import ./sources

const nullDevice = when defined(windows): "NUL" else: "/dev/null"
const ProfileDepfileTarget* = "repro-profile"
  ## The `-MT` target of the profile compile's dependency report, which goes
  ## to the null device (`profileCompileCFlags`); clang requires one.

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
  ## output, and the edge then carried no entropy blessing); only
  ## the determinism probe admits the second identical run, so an unchanged
  ## profile hit on run 3 instead of run 2 and every cache-hit gate failed.
  ## The compile now passes clang `-fno-temp-file`, which removes the draw
  ## (`profileCompileCFlags`), but only where the compiler accepts it; the
  ## order is kept so a clang that does not is never preferred. The recipe
  ## compile blesses compiler entropy and is unaffected; since the profile
  ## compile was split into a compile edge and a run edge, the compile edge
  ## carries that same blessing (`edge.nim`), so a clang draw would no
  ## longer cost a publication either -- the order and the flag stay because
  ## removing a draw is preferred to waiving it. A host with Nim's
  ## default compiler keeps it; only a host without it -- where the compile
  ## could not run at all -- gets one picked.
  try:
    result = explicitCCompiler()
  except CCompilerUnusableError as err:
    raise newException(CompileFailure, "repro profile compile: " & err.msg)
  if result.len > 0:
    return
  if uncontrolledFindExe(NimDefaultCCompilerExe).len > 0:
    return ""
  result = fallbackCCompiler()

proc profileCompileCFlags*(cCompiler, scratchDir: string): seq[string] =
  ## The flags the profile compile hands the C compiler through Nim's
  ## `--passC`, for the compiler that will actually run: `cCompiler` (from
  ## `resolveProfileCCompiler`), or Nim's default (`NimDefaultCCompilerExe`
  ## on `PATH`) when that is "".
  ##
  ## Clang's `-fno-temp-file`
  ## (`repro_core/c_compiler.clangNoTempFileCFlags`). Without it clang calls
  ## `arc4random` to name the temporary file it renames onto each `-o`
  ## object, io-mon reports the call, and the edge -- which then carried no
  ## entropy blessing -- had its first run's publish skipped: an unchanged
  ## profile hit on run 3 instead of run 2 (reprobuild-pm issue
  ## 2026-10-14-clang-profile-compile-is-not-published-on-its-first-run).
  ## The compile edge now carries the provider compile's blessing
  ## (`edge.nim`), so the draw no longer withholds publication; the flag
  ## stays because a removed draw is better than a waived one
  ## (idiomatic-reprobuild.md §4.4), and its effect is now checked on the
  ## edge's entropy evidence rather than on its publication
  ## (`t_e2e_profile_compile_clang_first_run_published`).
  ## That is Nim's default on macOS, and the compiler any host gets from an
  ## explicit `$REPRO_BOOTSTRAP_CC` / `$CC` that is a clang. gcc gets
  ## nothing, and a clang that rejects the flag (probed with a real compile
  ## in `scratchDir`) compiles as before.
  ##
  ## Decided inside the edge, by the helper, rather than by the caller that
  ## schedules it: the decision is a function of the compiler binary and of
  ## this code, both of which the edge's monitored record already covers, and
  ## deciding it in the caller would spawn the compiler twice on every warm
  ## `repro home plan` to fingerprint a fact the record already holds. Pass a
  ## `scratchDir` the edge ignores as an input (the nimcache).
  let effective =
    if cCompiler.len > 0: cCompiler
    else: uncontrolledFindExe(NimDefaultCCompilerExe)
  result = clangNoTempFileCFlags(effective, scratchDir)
  # Apple clang uses a second random temporary for -MF, even when object
  # output is direct. Route the unused report to the null device instead,
  # which clang writes directly. Empty filenames are unsafe here: Nim and
  # compiler wrappers can drop an empty argument and make cc1 consume the
  # next option as a report path. The action's monitor owns header freshness.
  #
  # The flags carry their own `-MD -MT`: cc1 refuses `-dependency-file`
  # without a target ("-dependency-file requires at least one -MT or -MQ
  # option", upstream and Apple clang alike), and whether the driver supplies
  # one depends on the Nim that runs. The fork in reprobuild's dev shell and
  # Nix package passes `-MD -MF <file>.d`; the official 2.2.10 archive the
  # recipe bootstrap provisions passes neither, and with it every clang
  # profile compile failed (measured on m1, 2026-10-15). With the target here
  # the flags are self-contained: in either order against the fork's
  # `-MD -MF`, and without it, the compile succeeds and no `.d` is written.
  # The probe is the same shape, so it answers for exactly what is passed.
  if cCompilerFamily(effective) == "clang":
    let depsToNull = @["-MD", "-MT", ProfileDepfileTarget, "-Xclang",
      "-dependency-file", "-Xclang", nullDevice]
    # Direct object output is retained, so the probe itself does not
    # introduce the entropy the real compile is being changed to avoid.
    if cCompilerAcceptsFlags(effective, result & depsToNull, scratchDir):
      result.add depsToNull.join(" ")

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
                         repoRoot: string; cCompiler = "";
                         cFlags: openArray[string] = []): seq[string] =
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
  ## `cFlags` (from `profileCompileCFlags`) each become one `--passC:`,
  ## applied to every C compile and not to the link.
  # The action cache supplies the incremental boundary. On an executed
  # edge, force C compilation so headers are both current and observed,
  # including {.compile.} sources when no compiler depfile was produced.
  result = @[nimExe, "c", "--hints:off", "--warnings:off", "--forceBuild:on",
    "--nimcache:" & nimcacheDir,
    "--out:" & outBinary]
  result.add nimCCompilerFlags(cCompiler)
  for flag in cFlags:
    result.add "--passC:" & flag
  for define in ProfileCompileDefines:
    result.add "-d:" & define
  for path in profileNimPaths(repoRoot):
    result.add "--path:" & path
  result.add profileRoot

proc profileCompileEnvAdditions*(repoRoot: string): StringTableRef =
  ## What the profile compile ADDS to the environment `nim` inherits: the
  ## `*_SRC` source roots reprobuild's config.nims resolves its source-only
  ## inputs from, each only where this process's environment leaves it unset
  ## (or empty). ONLY the additions -- the rest of the environment is
  ## inherited by `startProfileNim`, never copied. Pure apart from existence
  ## checks, so the probing is testable on a fixture tree.
  ##
  ## WHY ADDITIONS AND NOT A COPY OF THE ENVIRONMENT. This used to return the
  ## whole environment plus the additions, built with `envPairs()`. On
  ## Windows `envPairs()` is `GetEnvironmentStringsW`, and io-mon's Windows
  ## shim records an enumeration of the environment block as a read of EVERY
  ## variable in it (a deliberate over-approximation: it cannot see which of
  ## them the caller goes on to use). So the profile compile edge was keyed
  ## on the value of every variable of the caller's environment -- 224 of
  ## them in one measured capture -- and a `repro home export` after a
  ## `repro home plan` that differed only in `$REPRO_HOST` recompiled the
  ## profile ("input metadata changed: REPRO_HOST"). On Linux and macOS
  ## `environ` is read without an observable call, so only the variables
  ## Nim and the C toolchain actually look up were inputs there. Now that is
  ## true on Windows as well, for the same reason: each variable this helper
  ## or the compiler reads is looked up BY NAME, and io-mon records exactly
  ## those. The edge stops depending on the others because nothing reads
  ## them any more, not because the engine is told to ignore a read.
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
  # A value already in the child's environment -- the caller's (looked up by
  # name: an observed read of that one variable), or one a line below has
  # filled -- is never replaced.
  proc unsetInChild(envName: string): bool =
    if env.hasKey(envName):
      return env[envName].len == 0
    getEnv(envName).len == 0

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
# What every Nim invocation over a profile needs: the files staged in the
# profile directory (`stageProfileFiles`) and the child environment. Shared
# by the compile (`compileProfileBinary`) and the platform probe
# (`platforms.nim`), so the probe checks the profile in exactly the
# configuration it is compiled in.
# ---------------------------------------------------------------------------

const StagedProfilePackageName* = "repro_staged_profile"
  ## The package name the staged `.nimble` gives a profile directory that has
  ## none (`stageProfilePackageFile`). Nim takes a package's name from its
  ## `.nimble` file NAME, and uses it to keep module names unique per package
  ## and in symbol mangling, so it must not be the name of a package a
  ## profile can import: not `repro_profile` (the library every profile
  ## imports) nor any other reprobuild library or Nimble package. The
  ## `repro_staged_` prefix is reserved for exactly this file.

const StagedProfilePackageFile* = StagedProfilePackageName & ".nimble"

proc stageProfileConfig(profileDir, repoRootAbs: string): string =
  ## Stage a wrapper config.nims next to the profile so nim's parent-walk
  ## picks it up and pulls in reprobuild's config.nims (which resolves
  ## sibling-repo paths from env vars: NIMCRYPTO_SRC, BEARSSL_SRC, IO_MON_SRC,
  ## etc.). Without this, a profile at e.g. C:\Users\admin\reprobuild-source\
  ## never sees reprobuild's config.nims, and transitive imports of
  ## repro_project_dsl -> nimcrypto/sha2 fail with "cannot open file".
  ##
  ## Returns the path it staged, or "" when the profile directory already has
  ## a `config.nims` of its own or reprobuild has none.
  let stagedConfig = profileDir / "config.nims"
  let upstreamConfig = repoRootAbs / "config.nims"
  if fileExists(extendedPath(upstreamConfig)) and
     not fileExists(extendedPath(stagedConfig)):
    writeFile(extendedPath(stagedConfig),
      "include \"" & upstreamConfig.replace('\\', '/') & "\"\n")
    return stagedConfig
  ""

const StagedProfilePackageBody = """
# Staged by reprobuild while it runs Nim over this profile, and removed when
# Nim is done. If you can see it while no repro command is running, a compile
# was interrupted; it is then safe to delete.
#
# Nim never reads this file's contents, only its name: it looks for a
# `*.nimble` in each directory above a module it compiles, stopping at the
# first directory that holds one (`getNimbleFile`,
# https://github.com/nim-lang/Nim/blob/devel/compiler/packagehandling.nim).
# Without this file that search lists every directory above your profile up
# to `/`, and reprobuild records what each listing returned, so creating any
# file in your home directory would recompile your profile.
"""

proc stageProfilePackageFile(profileDir: string): string =
  ## Stage `StagedProfilePackageFile` in a profile directory that holds no
  ## `*.nimble`, so Nim's package lookup ends there.
  ##
  ## WHY. Nim looks for a `.nimble` in every ancestor of each module it
  ## compiles (`compiler/packagehandling.nim`, `getNimbleFile`:
  ## `walkFiles(dir / "*.nimble")` up the parent chain until one matches).
  ## For a profile directory that holds none, the walk lists `$HOME`,
  ## `/private/tmp`, `/` and everything between. On macOS the monitor records
  ## each glob as a directory enumeration, and the action cache keys the edge
  ## on every listed directory's FULL membership: any new file in the user's
  ## home directory recompiled the profile (reprobuild-pm issue
  ## 2026-10-14-macos-profile-compile-is-keyed-on-the-membership-of-every-ancestor-directory).
  ## On Linux the listings are real reads the shim does not see (glibc's
  ## `glob` uses calls it does not interpose); this ends them there too.
  ##
  ## WHY THIS IS NOT AN EXEMPTION. The ancestors stop being inputs because
  ## Nim no longer reads them, not because the engine is told to ignore what
  ## it read. Whether a file is staged is decided here, from the profile
  ## directory's own listing -- which the monitor records, so the profile
  ## directory's membership stays an input -- and from this code, which the
  ## helper binary in the edge's weak fingerprint carries. Do not replace
  ## this with an ignored-prefix or declared-dependency rule for the
  ## ancestor directories (`docs/user-guide/idiomatic-reprobuild.md`).
  ##
  ## WHEN NOT. A directory that already holds a `*.nimble` is left alone: the
  ## user's file ends the walk already, and a second one would make Nim's
  ## answer (the first glob match) depend on directory order. A file of
  ## OUR name and no other is the leftover of an interrupted run; it is
  ## rewritten and removed like a fresh one, so it does not stay behind for
  ## good. The glob below is Nim's own pattern, so "holds a `.nimble`" means
  ## exactly what it means to Nim.
  ##
  ## Nim reads only the file's NAME (the package name), never its contents
  ## during `nim c` / `nim check` / `nim dump`, so the body is an
  ## explanation for a user who finds a leftover.
  ##
  ## Returns the path it staged, or "". Failing to write it is not fatal: the
  ## walk then continues upward as it did before, which costs cache answers
  ## and never correctness, since every listing it makes is recorded.
  ##
  ## Covers modules under the profile directory. A profile module imported
  ## from OUTSIDE it (`import ../shared/x`) still has its own ancestors
  ## walked: the walk starts at each module's directory.
  var matches: seq[string]
  for path in walkFiles(profileDir / "*.nimble"):
    matches.add path.extractFilename
  if matches.len > 0 and matches != @[StagedProfilePackageFile]:
    return ""
  let staged = profileDir / StagedProfilePackageFile
  try:
    writeFile(extendedPath(staged), StagedProfilePackageBody)
  except IOError, OSError:
    return ""
  staged

proc unstageProfileFiles*(staged: openArray[string]) =
  ## Remove what `stageProfileFiles` staged. Never raises: it runs in
  ## `finally` blocks, where an error would replace the real one.
  for path in staged:
    if path.len > 0:
      try: removeFile(extendedPath(path))
      except OSError: discard

proc stageProfileFiles*(profileRoot, repoRootAbs: string): seq[string] =
  ## Stage, in the directory of the profile root `profileRoot`, the files
  ## every Nim invocation over a profile needs -- the `config.nims` wrapper
  ## (`stageProfileConfig`) and the package-lookup stop
  ## (`stageProfilePackageFile`) -- and return the paths staged. The caller
  ## removes them with `unstageProfileFiles` on EVERY path out, exceptions
  ## included, as `compileProfileBinary` and `runProfilePlatformProbes` do in
  ## a `finally`. The files are created and deleted inside the monitored
  ## edge, so the engine sees them as transient writes, not inputs or
  ## outputs.
  let profileDir = profileRoot.parentDir
  try:
    let config = stageProfileConfig(profileDir, repoRootAbs)
    if config.len > 0:
      result.add config
    let package = stageProfilePackageFile(profileDir)
    if package.len > 0:
      result.add package
  except CatchableError:
    # Nothing is returned on a raise, so remove what was staged before it.
    unstageProfileFiles(result)
    raise

proc startProfileNim*(argv: seq[string]; repoRootAbs: string;
                      additions: StringTableRef;
                      unset: openArray[string] = []): Process =
  ## Start one `nim` invocation over a profile -- the compile's `nim c`, the
  ## platform probe's `nim dump` / `nim check` -- with stderr merged into
  ## stdout, from the reprobuild root. `nim` INHERITS this process's
  ## environment with `additions` (`profileCompileEnvAdditions`) laid over
  ## it. `argv[0]` is the compiler `resolveProfileNimCompiler` chose. The one
  ## place a profile's compiler is launched; finish it with
  ## `finishProfileNim`. The Windows profile C capability probe reuses this
  ## same argv/capture executor before Nim. Each name in `unset` is removed
  ## from the environment for the spawn the same way, and restored after.
  ##
  ## The additions are set in this process's environment only for the
  ## duration of the spawn and restored as they were before it returns (the
  ## child has its own copy by then), because the alternative -- handing
  ## `startProcess` a full environment table -- means enumerating the
  ## environment, which on Windows io-mon records as a read of every
  ## variable (see `profileCompileEnvAdditions`). Not thread-safe with
  ## respect to other environment writers in this process; the callers (the
  ## internal helpers and the tests) spawn from one thread.
  var restore: seq[tuple[name: string; existed: bool; value: string]]
  for name in unset:
    restore.add((name: name, existed: existsEnv(name), value: getEnv(name)))
    delEnv(name)
  if additions != nil:
    for name, value in additions:
      restore.add((name: name, existed: existsEnv(name), value: getEnv(name)))
      putEnv(name, value)
  try:
    result = startProcess(argv[0], workingDir = repoRootAbs,
      args = argv[1 .. ^1], env = nil, options = {poUsePath, poStdErrToStdOut})
  finally:
    for i in countdown(restore.high, 0):
      let saved = restore[i]
      if saved.existed:
        putEnv(saved.name, saved.value)
      else:
        delEnv(saved.name)

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
# Direct Nim invocation. The compile (`compileProfileExecutable`) and the run
# (`runProfileBinary`) are separate steps because production runs them as
# separate edges; `compileProfileBinary` chains them for the tests.
# ---------------------------------------------------------------------------

proc runProfileBinary*(outBinary: string): tuple[
    output, stderrText: string; exitCode: int] =
  ## Run a compiled profile binary and capture its stdout (the intent JSON)
  ## and its stderr (diagnostics) separately, draining both at once so a
  ## profile whose diagnostics outgrow a pipe buffer cannot block before it
  ## emits its intent. Exported for the regression tests in
  ## `tests/t_profile_runtime_stderr.nim`.
  ##
  ## The concurrent drain is `drainStdoutAndStderr`, whose reader thread
  ## keeps what it reads off its own heap. This proc used to fill a Nim
  ## string on its own reader thread and free it here after the thread had
  ## exited, which wrote into the dead thread's allocator region and crashed
  ## the profile compile on Windows (see that helper's header comment).
  let p = startProcess(outBinary, args = [], options = {})
  try:
    let captured = drainStdoutAndStderr(p)
    result.output = captured.output
    result.stderrText = captured.errorOutput
    result.exitCode = p.waitForExit()
  finally:
    p.close()

when defined(windows):
  proc requireProfileCCompiler(cc, nimcacheDir, repoRootAbs: string): string =
    ## Resolve the implicit default once, then probe and pass that same image
    ## to Nim. Presence alone admits old or wrong-target GCC installations.
    ## This runs inside the monitored profile edge, in its existing scratch.
    result = if cc.len > 0: cc else: uncontrolledFindExe("gcc")
    if result.len > 0:
      result = absolutePath(result)
    let origin = if cc.len > 0: "configured profile C compiler"
                 else: "first gcc.exe on PATH"
    var probe = CCompilerProbe(compiler: result)
    if result.len == 0 or not fileExists(extendedPath(result)):
      probe.detail = "no such file"
    else:
      let scratch = absolutePath(nimcacheDir) / "cc-capability-probe"
      let source = scratch / "probe.c"
      let output = scratch / "probe.o"
      try:
        createDir(extendedPath(scratch))
        writeFile(extendedPath(source), cCompilerProbeSource)
        # The probe sees the compile's additions with the toolchain search
        # variables removed for the spawn only: removing them by name keeps
        # the environment un-enumerated (`startProfileNim`).
        let res = finishProfileNim(startProfileNim(
          cCompilerProbeArgv(result, source, output), repoRootAbs,
          profileCompileEnvAdditions(repoRootAbs),
          unset = ["SDKROOT", "DEVELOPER_DIR", "CPATH", "C_INCLUDE_PATH",
                   "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "INCLUDE",
                   "LIBRARY_PATH", "LIB"]))
        probe.usable = res.exitCode == 0
        if not probe.usable:
          probe.detail = "exit status " & $res.exitCode &
            (if res.output.strip().len > 0: ":\n" & res.output.strip() else: "")
      except CatchableError, OSError:
        probe.detail = "could not run it: " & getCurrentExceptionMsg()
      finally:
        for path in [output, source]:
          try: removeFile(extendedPath(path))
          except CatchableError, OSError: discard
        try: removeDir(extendedPath(scratch))
        except CatchableError, OSError: discard
    if not probe.usable:
      let message = cCompilerUnusableMessageFor(probe, origin, "profile")
      var err = newException(CompileFailure, message)
      err.stderrText = message
      raise err

proc compileProfileExecutable*(profileRoot, nimcacheDir, outBinary: string;
                               repoRoot: string;
                               verbose: bool = false): string =
  ## The COMPILE half of a profile compile: `nim c` (no `-r`) over
  ## `profileRoot`, linking `outBinary`. Returns Nim's transcript (its
  ## diagnostics) and raises `CompileFailure` carrying that transcript when
  ## the compile fails. Does NOT run the binary.
  ##
  ## This is the whole body of the compile edge (`__repro_profile_compile`,
  ## through `runProfileCompileHelper`), and "does not run the binary" is the
  ## property that edge's entropy blessing rests on: the edge's process tree
  ## is nim and the C toolchain, never the produced program
  ## (reprobuild-pm `spec/Profile-Compilation-Model.md` §2.1). The run is a
  ## separate, unblessed edge. Do not add a run here.
  let nimExe = resolveProfileNimCompiler()
  var cCompiler = resolveProfileCCompiler()
  let repoRootAbs = absolutePath(repoRoot)
  requireReprobuildSources(repoRootAbs)
  createDir(extendedPath(nimcacheDir))
  createDir(extendedPath(outBinary.parentDir))
  when defined(windows):
    cCompiler = requireProfileCCompiler(cCompiler, nimcacheDir, repoRootAbs)

  # The probe compile runs in the nimcache: the edge ignores it as an input.
  let cFlags = profileCompileCFlags(cCompiler, nimcacheDir)
  let nimArgv = profileCompileArgv(nimExe, profileRoot, nimcacheDir,
    outBinary, repoRootAbs, cCompiler, cFlags)
  if verbose:
    stderr.writeLine("repro profile compile: " & nimArgv.join(" "))

  let staged = stageProfileFiles(profileRoot, repoRootAbs)
  try:
    let childEnv = profileCompileEnvAdditions(repoRootAbs)
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
    compileRes.output
  finally:
    unstageProfileFiles(staged)

proc compileProfileBinary*(profileRoot, nimcacheDir, outBinary: string;
                           repoRoot: string;
                           verbose: bool = false): tuple[
    jsonOutput: string; stderrText: string] =
  ## Compile AND run a profile in this process, unmonitored:
  ## `compileProfileExecutable`, then `runProfileBinary` with no arguments,
  ## so the binary prints its intent on stdout. Raises `CompileFailure` if
  ## either step exits non-zero.
  ##
  ## NOT the production path. `compileProfileToRbpi` schedules the compile
  ## and the run as two monitored edges and never calls this; it exists for
  ## the tests (and callers) that need a profile's intent without a build
  ## engine. Only stdout is intent JSON; diagnostics come back in
  ## `stderrText`.
  let transcript = compileProfileExecutable(profileRoot, nimcacheDir,
    outBinary, repoRoot, verbose)
  # Run the profile binary directly, not through a shell, for the same
  # reason the compile is an argv: the binary's path carries any space the
  # state directory has. Drain stderr concurrently so diagnostics larger than
  # a pipe buffer cannot block the profile before it emits its intent.
  let runRes = runProfileBinary(outBinary)
  if runRes.exitCode != 0:
    var err = new CompileFailure
    err.msg = "compiled profile binary exited " & $runRes.exitCode &
      " for " & profileRoot
    err.stderrText = transcript & runRes.stderrText & runRes.output
    raise err
  result.jsonOutput = runRes.output
  result.stderrText = transcript & runRes.stderrText

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
