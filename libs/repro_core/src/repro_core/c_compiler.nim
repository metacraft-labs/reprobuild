## Choosing the C compiler for a compile reprobuild runs on its own behalf.
##
## Two edges compile Nim code against reprobuild's own libraries after the
## `repro` binary was installed: the recipe compile (interface extract and
## provider, `repro_interface_artifacts`) and the home/system profile compile
## (`repro_profile_compile`). Both hand the generated C to a C compiler, and
## they used to find it differently. The recipe compile named one explicitly
## (`--gcc.exe:<cc>`), chosen from `$REPRO_BOOTSTRAP_CC`, an absolute `$CC`,
## `cc` on `PATH`, and finally the compiler `repro` itself was built with.
## The profile compile named none, so Nim ran its default (`gcc` on Linux)
## through a shell's `PATH` lookup. From the installed Nix package in a clean
## environment -- no compiler on `PATH`, which is what an installed tool must
## survive -- every `repro home apply` then failed with
## `gcc: command not found`, although the package's closure carries the
## compiler it was built with (Gradual-Nix-To-Reprobuild-Migration GM1l).
##
## This module is that one selection. The recipe compile takes it whole
## (`resolveConfiguredCCompiler`). The profile compile takes its explicit
## arms, keeps Nim's default compiler when `PATH` has it, and only then takes
## the fallback arms (`repro_profile_compile.resolveProfileCCompiler` says
## why: a `cc` that is clang left that unblessed edge's first run
## unpublished). It lives
## in `repro_core` because
## `repro_profile_compile` sits below `repro_interface_artifacts` in the
## dependency graph, the same reason `source_root` lives here.
## `repro_interface_artifacts` re-exports the names it used to define.
##
## What stays in `repro_interface_artifacts`: the compiler PROBE
## (`probeCCompiler`), and the Windows last resort that takes the first
## `gcc.exe` on `PATH` with a warning. Windows has no build-time compiler
## constant (see `BuiltCCompilerPath`), so `resolveConfiguredCCompiler`
## returns "" there when neither variable names one, and each caller decides
## what that means.

import std/[os, strutils, tables]

import ./ambient_execution
from ./paths import extendedPath

type
  CCompilerUnusableError* = object of CatchableError
    ## The C compiler selected for compiling a recipe or a profile is missing
    ## or cannot compile a trivial C translation unit. The message names the
    ## compiler, where it was selected from, what failed, and how to point
    ## reprobuild at a different one.

const
  bootstrapCCompilerEnv* = "REPRO_BOOTSTRAP_CC"
    ## The one knob that names the C compiler for reprobuild's own compiles.
    ## Set by `repro_tool_profiles.ensureBootstrapToolchainEnv` to the pinned
    ## tool-store compiler, or by the user to override it.
  bootstrapSdkRootEnv* = "REPRO_BOOTSTRAP_SDKROOT"
    ## macOS only: the SDK the bootstrap's Xcode Command Line Tools clang
    ## compiles and links against. `ensureBootstrapToolchainEnv` sets it next
    ## to `REPRO_BOOTSTRAP_CC` when it chose that clang and `SDKROOT` was
    ## unset. It is passed to the compiler as `-isysroot` rather than exported
    ## as `SDKROOT`: the recipe compile's child actions inherit this process's
    ## environment, and an `SDKROOT` there would redirect every package
    ## action's compiler (a Nix clang wrapper included) to the Xcode SDK.

proc sanitizeStaticExec(val: string): string =
  ## The last non-empty line of a `staticExec` result, ignoring io-mon's own
  ## diagnostics (a build run under the monitor can interleave them).
  var cleanLines: seq[string] = @[]
  for line in val.splitLines:
    let s = line.strip()
    if s.len > 0 and not s.startsWith("io-mon:"):
      cleanLines.add(s)
  if cleanLines.len > 0: cleanLines[^1] else: ""

# The C compiler of the environment that BUILT `repro`, as an absolute path.
# Under Nix that is the stdenv compiler wrapper's store path; embedding it in
# the binary is what keeps that compiler in the installed package's runtime
# closure, so an installed `repro` always has a compiler to fall back on.
#
# Windows has none: `staticExec` runs no shell there, so `command` is not
# found and the last output line is an error message rather than a path.
# Windows gets its compiler from the bootstrap or from `REPRO_BOOTSTRAP_CC`.
when defined(windows):
  const BuiltCCompilerPath* = ""
else:
  const BuiltCCompilerPath* =
    sanitizeStaticExec(staticExec("command -v cc || command -v gcc || true"))

proc bootstrapSysrootArgs*(): seq[string] =
  ## The `-isysroot` pair for the recipe-compile C compiler, from
  ## `REPRO_BOOTSTRAP_SDKROOT`. Empty off macOS and when it is unset.
  when defined(macosx):
    let sdk = getEnv(bootstrapSdkRootEnv)
    if sdk.len > 0:
      result = @["-isysroot", sdk]

proc cCompilerOverrideRemedy*(): string =
  ## How to point reprobuild at a different C compiler for its own compiles.
  "Set " & bootstrapCCompilerEnv & " to the absolute path of a working " &
    (when defined(windows): "64-bit MinGW-w64 gcc.exe"
     else: "C compiler for this host") &
    ", or unset it to use the pinned bootstrap compiler reprobuild " &
    "provisions into its tool store."

when defined(macosx):
  # SIP prefixes, kept byte-identical to nim-stackable-hooks'
  # `propagation.sipProtectedPrefixes` (the population io-mon itself uses via
  # `isSipProtected` / `rewriteSipPath`) so the engine and the monitor agree
  # on what counts as SIP-protected. Defined locally rather than imported to
  # keep this foundational lib free of a new dependency edge; the values MUST
  # track the shared population.
  const macosSipCompilerPrefixes = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]

  proc isSipProtectedCompiler(path: string): bool =
    for prefix in macosSipCompilerPrefixes:
      if path.startsWith(prefix):
        return true
    false

  proc firstNonSipCCompilerOnPath(): string =
    ## macOS / Apple Silicon: the io-mon monitor shim
    ## (`librepro_monitor_shim.dylib`, injected via `DYLD_INSERT_LIBRARIES`)
    ## cannot be carried into a SIP-protected, arm64e *system* binary. `nim c`
    ## shells the C back-end out to the compiler resolved here, so when that
    ## compiler is one of the SIP binaries (`/usr/bin/cc`), the monitored
    ## compile spawns an unmonitorable arm64e child and dyld either refuses an
    ## arm64-only shim slice ("incompatible architecture ... need arm64e") or
    ## the arm64e interpose path crashes the child -- the compile then fails
    ## with an opaque "execution of an external program failed". A non-SIP
    ## compiler (the Nix / Homebrew clang wrapper that `nix develop` puts on
    ## `PATH`) takes the arm64 shim slice cleanly and is fully monitorable.
    ## Prefer it, mirroring the engine's `resolveNonSipShell` for the
    ## analogous `/bin/sh` case. Returns "" when only SIP compilers are on
    ## `PATH` (e.g. a bare login shell); the caller then falls back to the
    ## SIP compiler unchanged.
    let pathEnv = getEnv("PATH")
    for name in ["cc", "clang", "gcc"]:
      for dir in pathEnv.split(PathSep):
        if dir.len == 0:
          continue
        let candidate = dir / name
        if not fileExists(extendedPath(candidate)):
          continue
        if isSipProtectedCompiler(candidate):
          continue
        return candidate
    ""

  proc preferNonSipCompiler(candidate: string): string =
    ## When `candidate` is a SIP-protected compiler, substitute a non-SIP one
    ## if PATH offers it; otherwise keep `candidate` (best effort).
    if candidate.len == 0 or not isSipProtectedCompiler(candidate):
      return candidate
    let nonSip = firstNonSipCCompilerOnPath()
    if nonSip.len > 0: nonSip else: candidate

proc explicitCCompiler*(): string =
  ## The C compiler the environment names EXPLICITLY, or "":
  ##
  ## 1. `$REPRO_BOOTSTRAP_CC`: the bootstrap-resolved compiler published by
  ##    `ensureBootstrapToolchainEnv`, or the caller's explicit choice. It
  ##    outranks `$CC` because env.ps1 / inherited shells legitimately set
  ##    `$CC` to a bare basename like `gcc` for Makefiles and autotools. A SET
  ##    but unusable value raises `CCompilerUnusableError`: it is somebody's
  ##    explicit choice, and silently compiling with a different compiler is
  ##    how the wrong gcc went unnoticed.
  ## 2. `$CC`, when it is an absolute path (on macOS a SIP-protected one is
  ##    swapped for a non-SIP compiler on `PATH` when there is one,
  ##    `preferNonSipCompiler`).
  let bootstrapCC = getEnv(bootstrapCCompilerEnv)
  if bootstrapCC.len > 0:
    if isAbsolute(bootstrapCC) and fileExists(extendedPath(bootstrapCC)):
      return bootstrapCC
    raise newException(CCompilerUnusableError,
      bootstrapCCompilerEnv & "=" & bootstrapCC & " does not name an " &
      "existing file by absolute path. " & cCompilerOverrideRemedy())
  let ccEnv = getEnv("CC")
  if ccEnv.len > 0 and isAbsolute(ccEnv):
    when defined(macosx):
      return preferNonSipCompiler(ccEnv)
    else:
      return ccEnv
  ""

proc fallbackCCompiler*(): string =
  ## The C compiler when the environment names none explicitly, or "":
  ##
  ## 3. `cc` on `PATH` (POSIX only; Windows has no system `cc`; on macOS a
  ##    SIP-protected one is swapped as in `explicitCCompiler`).
  ## 4. `BuiltCCompilerPath`, the compiler `repro` was built with, when it
  ##    still exists (POSIX only). This is the arm an installed Nix package
  ##    reaches in a clean environment.
  when not defined(windows):
    let runtimeCC = uncontrolledFindExe("cc")
    if runtimeCC.len > 0 and isAbsolute(runtimeCC) and
        fileExists(extendedPath(runtimeCC)):
      when defined(macosx):
        return preferNonSipCompiler(runtimeCC)
      else:
        return runtimeCC
  if BuiltCCompilerPath.len > 0 and
      fileExists(extendedPath(BuiltCCompilerPath)):
    return BuiltCCompilerPath
  ""

proc resolveConfiguredCCompiler*(): string =
  ## The recipe compile's C compiler, as an absolute path: the explicit
  ## choice (`explicitCCompiler`), else `fallbackCCompiler`. Returns "" when
  ## nothing is found (only possible on Windows, or on a POSIX host whose
  ## build compiler is gone and that has no `cc`).
  result = explicitCCompiler()
  if result.len == 0:
    result = fallbackCCompiler()

var cachedCCompilerFamilies = initTable[string, string]()

proc cCompilerFamily*(cc: string): string =
  ## `"clang"` when `cc --version` says it is clang, `"gcc"` otherwise --
  ## the Nim compiler family whose always-on flags the binary accepts.
  ##
  ## Naming the compiler binary (`--gcc.exe`) without naming the family left
  ## Nim at its platform default (clang on macOS, gcc on Linux). When the
  ## binary is gcc (e.g. the Nix gcc-wrapper used by path-mode provisioning)
  ## but Nim still thinks it is clang, Nim emits clang-only flags such as
  ## `-ferror-limit=3` (from `clang.options.always`) and gcc rejects them.
  ## Memoised per compiler path.
  if cachedCCompilerFamilies.hasKey(cc):
    return cachedCCompilerFamilies[cc]
  result = "gcc"
  try:
    let (output, exitCode) = uncontrolledExecCmdEx(quoteShell(cc) &
      " --version")
    if exitCode == 0 and "clang" in output.toLowerAscii:
      result = "clang"
  except CatchableError, OSError:
    discard
  cachedCCompilerFamilies[cc] = result

proc nimCCompilerFlags*(cc: string): seq[string] =
  ## The `nim c` flags that make Nim compile and link with exactly `cc`:
  ## the matching family (`cCompilerFamily`) and `cc` as both families'
  ## compiler and linker. Empty for an empty `cc` (Nim keeps its default).
  ##
  ## macOS: when `cc` is the bootstrap's own choice (`$REPRO_BOOTSTRAP_CC`)
  ## and the bootstrap named an SDK for it (`bootstrapSysrootArgs`), the SDK
  ## is passed too. A compiler the caller named finds its SDK the way it
  ## always did.
  if cc.len == 0:
    return
  result.add("--cc:" & cCompilerFamily(cc))
  result.add("--gcc.exe:" & cc)
  result.add("--gcc.linkerexe:" & cc)
  result.add("--clang.exe:" & cc)
  result.add("--clang.linkerexe:" & cc)
  if cc == getEnv(bootstrapCCompilerEnv):
    let sysroot = bootstrapSysrootArgs()
    if sysroot.len == 2:
      let sdk =
        if ' ' in sysroot[1]: "\"" & sysroot[1] & "\""
        else: sysroot[1]
      result.add("--passC:-isysroot " & sdk)
      result.add("--passL:-isysroot " & sdk)
