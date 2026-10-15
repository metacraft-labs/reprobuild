## Gradual-Nix-To-Reprobuild-Migration GM1l gate:
## `e2e_nix_package_compiles_profile_linux`.
##
## The INSTALLED Nix package — `nix build` of this very checkout — plans a
## minimal home profile in a CLEAN environment: the child process gets
## `HOME`, `XDG_STATE_HOME`, the profile and store directories, a host name,
## and a `PATH` naming one empty directory, and nothing else (`env -i`
## style). No `REPROBUILD_*` variable, none of the wrapper's variables, no
## `nim`, no C compiler and no shell utilities are inherited from the
## developer shell running the test, so whatever the compile needs, the
## package has to supply. The profile directory and the state directory both
## contain a space.
##
## The failure this pins down
## --------------------------
## Measured 2026-10-14 on home-pc (NixOS x86_64-linux), Nix package of
## reprobuild `a6491129` under exactly this environment:
##
##   /bin/sh: line 1: gcc: command not found
##   Error: execution of an external compiler program 'gcc -c ...' failed
##
## The package's wrapper names the Nim it was built with
## (`$REPRO_NIM_COMPILER`), but the profile compile named no C compiler, so
## Nim ran its default `gcc` through `PATH`. The recipe (provider) compile
## never had that problem: it names its compiler explicitly, and its last
## fallback is the compiler `repro` was built with, which the package's
## closure carries. Where Nim's default compiler is not on `PATH`, the profile
## compile now takes that same fallback
## (`repro_profile_compile.resolveProfileCCompiler`,
## `repro_core/c_compiler.fallbackCCompiler`).
##
## GM1's `t_e2e_nix_package_compiles_profile.nim` could not see this: it
## removes only `nim` from `PATH`, so the dev shell's `gcc` stayed reachable.
##
## What is asserted
## ----------------
## * The plan is exact: the profile's two `fs.userFile` resources, each
##   `create`, and nothing else (vacuity: the set is non-empty and equal to
##   the expected set, not merely containing it). Exactly one `.rbpi` is
##   published, under the spaced state directory; no planned file is written.
## * The compile used the package's own pieces, read from nim's record of it
##   (`<nimcache>/profile-build.json`): `currentDir` is the wrapper's
##   `$REPROBUILD_SOURCE_ROOT`, the compiler configuration it read
##   (`configFiles[0]`) belongs to the wrapper's `$REPRO_NIM_COMPILER`, and
##   every C compile and the link ran ONE absolute
##   compiler that lies inside the package's runtime closure
##   (`nix path-info --recursive`) and not on the child's `PATH`.
##
## Negative controls
## -----------------
## * The package's UNWRAPPED engine (`bin/.reprobuild-wrapped`) in the same
##   environment has none of the wrapper's defaults, so it has no sources to
##   compile against and must refuse with the resolver's diagnostic (every
##   place it looked, `$REPROBUILD_SOURCE_ROOT: unset`) — never reach Nim,
##   never publish an envelope. This shows the green run above is the
##   wrapper's doing, not something the environment leaked.
## * `$REPRO_BOOTSTRAP_CC` naming a file that does not exist is refused by
##   the profile compile with a diagnostic naming the variable, as the recipe
##   compile refuses it. This shows the profile compile consults the shared
##   C compiler selection rather than Nim's default.
##
## Hosts: every POSIX host with Nix (Linux; macOS is recorded for m1 under
## GM0m). Windows has no Nix package; the release bundle's equivalent is
## GM1w's `t_e2e_windows_bundle_compiles_profile.nim`, run on eli-pc.
##
## Mocks: none. A real `nix build`, the real wrapped package, the real build
## engine and io-mon monitor, a real `nim c`, a real C compiler and the real
## planner.

import std/[algorithm, json, os, sets, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_test_support/reasoned_skip

import ./nix_package_support

const AlphaName = "gm1l-alpha.txt"
const BravoName = "gm1l-bravo.txt"
const ProfileBody = """
import repro_profile

profile "gm1lCleanEnv":
  resources:
    fsUserFile(hostFile = "~/""" & AlphaName & """",
      content = "alpha, planned by the installed package\n")
    fsUserFile(hostFile = "~/""" & BravoName & """",
      content = "bravo, planned by the installed package\n")
"""

type
  Sandbox = object
    root, homeDir, spacedBase, profileDir, storeRoot, emptyBin: string

  CompileRecord = object
    ## What nim recorded about the compile, and what was published.
    rbpiCount: int
    currentDir: string
    compilerConfig: string
      ## The first configuration file nim read: its own `nim.cfg`.
    cCommands: seq[string]
      ## Every C compile command, then the link command.

  PlanRun = object
    res: RunResult
    stateDir: string
    rec: CompileRecord
    childEnv: StringTableRef

proc newSandbox(): Sandbox =
  # Every directory the run names carries a space, the root included.
  result.root = createTempDir("repro-gm1l-", " clean env")
  result.homeDir = result.root / "home dir"
  result.spacedBase = result.root / "state home"
  result.profileDir = result.root / "profile dir"
  result.storeRoot = result.root / "store root"
  result.emptyBin = result.root / "empty bin"
  for dir in [result.homeDir, result.spacedBase, result.profileDir,
              result.storeRoot, result.emptyBin]:
    createDir(extendedPath(dir))
  writeFile(extendedPath(result.profileDir / "home.nim"), ProfileBody)

proc cleanEnv(box: Sandbox): StringTableRef =
  ## The child's WHOLE environment. Nothing is copied from this process.
  result = newStringTable(modeCaseSensitive)
  result["HOME"] = box.homeDir
  result["XDG_STATE_HOME"] = box.spacedBase
  result["REPRO_HOME_PROFILE_DIR"] = box.profileDir
  result["REPRO_STORE_ROOT"] = box.storeRoot
  result["REPRO_HOST"] = "gm1l-clean-env"
  result["PATH"] = box.emptyBin

proc defaultStateDir(box: Sandbox): string =
  when defined(macosx):
    box.homeDir / "Library" / "Application Support" / "repro" / "home"
  else:
    box.spacedBase / "repro" / "home"

proc compileRecord(stateDir: string): CompileRecord =
  let cacheDir = stateDir / "profile-cache"
  if not dirExists(extendedPath(cacheDir)):
    return
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.endsWith(".rbpi"):
      inc result.rbpiCount
  if not dirExists(extendedPath(cacheDir / "nimcache")):
    return
  for path in walkDirRec(cacheDir / "nimcache"):
    if path.extractFilename == "profile-build.json":
      let doc = parseFile(path)
      result.currentDir = doc["currentDir"].getStr()
      if doc["configFiles"].len > 0:
        result.compilerConfig = doc["configFiles"][0].getStr()
      for entry in doc["compile"]:
        result.cCommands.add entry[1].getStr()
      result.cCommands.add doc["linkcmd"].getStr()

proc commandExe(cmd: string): string =
  ## The executable a nim-recorded C command starts with. The compiler is
  ## an unquoted store path; nim quotes only arguments that need it.
  let space = cmd.find(' ')
  if space < 0: cmd else: cmd[0 ..< space]

proc plannedResources(output: string): seq[string] =
  ## `<op> <address>` for every resource line of a `--plan` preview, sorted:
  ##   create  fs.userFile:~/gm1l-alpha.txt  (create ...)
  for line in output.splitLines:
    let fields = line.strip().splitWhitespace()
    if fields.len >= 2 and
        fields[0] in ["create", "update", "delete", "replace", "remove"] and
        ':' in fields[1]:
      result.add fields[0] & " " & fields[1]
  result.sort()

proc planClean(exe: string; box: Sandbox;
               extra: openArray[(string, string)] = []): PlanRun =
  result.childEnv = cleanEnv(box)
  for (k, v) in extra:
    result.childEnv[k] = v
  result.stateDir = defaultStateDir(box)
  result.res = run(exe, ["home", "apply", "--plan"], box.root,
    result.childEnv)
  result.rec = compileRecord(result.stateDir)
  doAssert not fileExists(box.homeDir / AlphaName), "a plan wrote a file"
  doAssert not fileExists(box.homeDir / BravoName), "a plan wrote a file"

proc removeSandbox(box: Sandbox) =
  try: removeDir(box.root) except OSError: discard

when defined(windows):
  suite "GM1l: e2e_nix_package_compiles_profile_linux":
    test "e2e_nix_package_compiles_profile_linux":
      skip("[platform N/A] there is no Nix package on Windows; the release " &
        "bundle's equivalent is GM1w's e2e_windows_bundle_compiles_profile, " &
        "run on eli-pc")
else:
  suite "GM1l: e2e_nix_package_compiles_profile_linux":

    test "e2e_nix_package_compiles_profile_linux: the installed package " &
        "plans a profile in a clean environment, from directories with spaces":
      let pkg = buildNixPackage()
      let repro = pkg / "bin" / "repro"
      let sourceRoot = wrapperDefault(repro, "REPROBUILD_SOURCE_ROOT")
      let nimCompiler = wrapperDefault(repro, "REPRO_NIM_COMPILER")
      check sourceRoot.startsWith("/nix/store/")
      check nimCompiler.startsWith("/nix/store/")
      let closure = packageClosure(pkg)

      let box = newSandbox()
      defer: removeSandbox(box)
      let plan = planClean(repro, box)
      checkpoint(plan.res.output)
      # The environment really is clean: nothing beyond what cleanEnv names.
      var names: seq[string]
      for k, _ in plan.childEnv:
        names.add k
      names.sort()
      check names == @["HOME", "PATH", "REPRO_HOME_PROFILE_DIR", "REPRO_HOST",
        "REPRO_STORE_ROOT", "XDG_STATE_HOME"]
      check ' ' in box.profileDir
      check ' ' in plan.stateDir

      check plan.res.exitCode == 0
      check not plan.res.output.contains("profile compilation failed")
      # The plan is exactly the profile's two resources.
      check plannedResources(plan.res.output) == @[
        "create fs.userFile:~/" & AlphaName,
        "create fs.userFile:~/" & BravoName]
      check plan.res.output.contains("2 operation(s) previewed, 0 drift(s)")
      check plan.rec.rbpiCount == 1

      # The compile ran against the package's sources, with its Nim ...
      check plan.rec.currentDir == sourceRoot
      check plan.rec.compilerConfig.startsWith(
        nimCompiler.parentDir.parentDir & "/")
      # ... and one C compiler the package carries, found without PATH.
      check plan.rec.cCommands.len >= 2
      var compilers = initHashSet[string]()
      for cmd in plan.rec.cCommands:
        compilers.incl commandExe(cmd)
      checkpoint("C compilers used: " & $compilers)
      check compilers.len == 1
      for cc in compilers:
        check cc.isAbsolute
        check storePathOf(cc) in closure
        check cc.parentDir != box.emptyBin
        check fileExists(cc)

      # The compile the package picked is CACHEABLE: an unchanged profile in
      # the same environment is answered from the action cache. A compiler
      # whose randomness the unblessed edge cannot carry (clang drawing
      # `arc4random` for its temporary object name) would leave the edge
      # unpublished, and every plan would recompile. Evidence that nim did
      # not run: nim's record of the compile (`profile-build.json`, inside
      # the per-profile nimcache the edge ignores as scratch) is removed
      # first and is not written again. Only that file is removed: the
      # nimcache's PARENT directory is observed by the edge, so removing the
      # whole tree is itself a (correct) cache miss.
      var removed = 0
      for path in walkDirRec(plan.stateDir / "profile-cache" / "nimcache"):
        if path.extractFilename == "profile-build.json":
          removeFile(extendedPath(path))
          inc removed
      check removed == 1
      let again = planClean(repro, box)
      checkpoint(again.res.output)
      check again.res.exitCode == 0
      check plannedResources(again.res.output) ==
        plannedResources(plan.res.output)
      check again.rec.rbpiCount == 1
      # Packaged replacements preserve Nim shell children on macOS too.
      check again.rec.cCommands.len == 0

      # A cache hit must still depend on the profile source. Change it after
      # the unchanged hit and require a fresh compile and the same plan.
      writeFile(extendedPath(box.profileDir / "home.nim"),
        ProfileBody & "\n# source changed after the unchanged cache hit\n")
      let changed = planClean(repro, box)
      checkpoint(changed.res.output)
      check changed.res.exitCode == 0
      check changed.rec.cCommands.len > 0
      check plannedResources(changed.res.output) ==
        plannedResources(plan.res.output)

    test "e2e_nix_package_compiles_profile_linux: negative control - the " &
        "unwrapped engine in the same environment has no sources and refuses":
      let pkg = buildNixPackage()
      let engine = pkg / "bin" / ".reprobuild-wrapped"
      doAssert fileExists(engine), "the package has no unwrapped engine at " &
        engine & "; makeWrapper's hidden-name convention changed"
      let box = newSandbox()
      defer: removeSandbox(box)
      let plan = planClean(engine, box)
      checkpoint(plan.res.output)
      check plan.res.exitCode != 0
      check plan.res.output.contains("profile compilation failed")
      check plan.res.output.contains("no reprobuild sources")
      check plan.res.output.contains("$REPROBUILD_SOURCE_ROOT: unset")
      # Refused before any compile: nim never ran, nothing was published.
      check not plan.res.output.contains("cannot open file")
      check plan.rec.rbpiCount == 0
      check plan.rec.cCommands.len == 0
      check plannedResources(plan.res.output).len == 0

    test "e2e_nix_package_compiles_profile_linux: negative control - a " &
        "REPRO_BOOTSTRAP_CC naming no file is refused by the profile compile":
      let pkg = buildNixPackage()
      let repro = pkg / "bin" / "repro"
      let box = newSandbox()
      defer: removeSandbox(box)
      let bogus = box.root / "no such cc"
      let plan = planClean(repro, box, [("REPRO_BOOTSTRAP_CC", bogus)])
      checkpoint(plan.res.output)
      check plan.res.exitCode != 0
      check plan.res.output.contains("profile compilation failed")
      check plan.res.output.contains("REPRO_BOOTSTRAP_CC=" & bogus &
        " does not name an existing file")
      check plan.rec.rbpiCount == 0
      check plan.rec.cCommands.len == 0
      check plannedResources(plan.res.output).len == 0
