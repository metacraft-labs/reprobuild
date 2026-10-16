## M83 Phase C smoke tests for `libs/repro_profile_compile/`.
##
## Covers the pure, fast-to-test surface of the new library:
##
##   - Profile-root resolution.
##   - JSON->RBPI round-trip from a known `ProfileIntent`.
##   - Cache-layout helpers (paths nest under
##     `<state-dir>/profile-cache/`, named by profile path, not content).
##   - `compileProfileToRbpi` does NOT serve a valid `.rbpi` that is
##     already present without scheduling the edge (the retired
##     structural fast path).
##   - `profileCompileBuildAction` shape: argv, declared inputs/outputs,
##     dependency policy, fingerprint binding.
##
## The source-discovery and source-digest cases that used to open this file
## were removed with the procs they tested (`parseSiblingImports`,
## `discoverProfileSources`, `computeProfileDigest`). Those were the profile
## compile's freshness key, and an `import` text scan cannot see `staticRead`,
## `include`, macros or run-time reads. The property they stood for — editing
## any file the profile depends on recompiles it — is now asserted against
## the monitored edge itself, in `tests/e2e/m83/t_e2e_profile_modules.nim`
## (sibling modules), `t_e2e_profile_compile_staticread_payload_change.nim`
## and `t_e2e_profile_compile_runtime_read_tracked.nim`.
##
## The fingerprint-binding case asserted `act.weakFingerprint == weak` until
## reprobuild `dev` `6e1173440` (NLF-M7, #91) made Named-Lock-Files §7's keying
## effective in `action()` itself. That is the milestone at which pass-through
## stopped being the contract: §7.2 requires the governing lock identity to be
## mixed in "by construction rather than by convention", precisely so a caller
## that supplies its own fingerprint cannot opt out. The case now asserts the
## composition rather than the pass-through — see the comment at the check.
##
## The unit-level coverage uses an in-process flow; the real
## library-API end-to-end test (driving `repro.exe` from a tempdir as
## the helper subprocess) lives at
## `tests/e2e/m83/t_e2e_repro_profile_compile_via_action.nim`.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
from repro_core/paths import extendedPath
from repro_core/source_root import InstalledSourceRootSubdir,
  InstalledSourceTreesSubdir
from repro_core/c_compiler import BuiltCCompilerPath, cCompilerFamily,
  cCompilerAcceptsFlag, clangNoTempFileCFlags, clangNoTempFileFlag

import repro_core
import repro_build_engine
import repro_profile
import repro_profile_intent
import repro_profile_compile

# ---------------------------------------------------------------------------
# Test helpers.
# ---------------------------------------------------------------------------

proc writeProfileFile(dir, name, body: string): string =
  result = dir / name
  let parent = result.parentDir
  if not dirExists(extendedPath(parent)):
    createDir(extendedPath(parent))
  writeFile(extendedPath(result), body)

const RootProfileBody = """
import repro_profile
import ./sibling_helpers

profile "smokeBasic":
  activity default:
    neovim
    tmux
"""

const SiblingBody = """
import std/tables

import repro_profile

template extraResources*(targetResources: var seq[ResourceIntent]) =
  envUserVariable(targetResources, name = "FOO", value = "bar")
"""

# ---------------------------------------------------------------------------
# Profile-root resolution.
# ---------------------------------------------------------------------------

const nullDevice = when defined(windows): "NUL" else: "/dev/null"

suite "M83 Phase C: profile-root resolution":

  test "resolveProfileRoot prefers explicit path over directory probes":
    let dir = createTempDir("repro-profile-resolve-", "")
    defer: removeDir(dir)
    let explicit = writeProfileFile(dir, "custom.nim", RootProfileBody)
    let resolved = resolveProfileRoot(dir, explicit)
    check resolved.endsWith("custom.nim")
    check fileExists(extendedPath(resolved))

  test "resolveProfileRoot probes home.nim then system.nim":
    let dir = createTempDir("repro-profile-resolve-probe-", "")
    defer: removeDir(dir)
    # Empty directory: nothing to find.
    check resolveProfileRoot(dir).len == 0
    discard writeProfileFile(dir, "system.nim", RootProfileBody)
    check resolveProfileRoot(dir).endsWith("system.nim")
    discard writeProfileFile(dir, "home.nim", RootProfileBody)
    check resolveProfileRoot(dir).endsWith("home.nim")

# ---------------------------------------------------------------------------
# RBPI bytes-from-JSON round-trip (the JSON->RBPI bridge used by the
# helper subcommand).
# ---------------------------------------------------------------------------

suite "M83 Phase C: RBPI emission":

  test "rbpiBytesFromJson round-trips a known ProfileIntent":
    var p: ProfileIntent
    p.name = "smokeRoundTrip"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "neovim")])
    let js = emitProfileIntentJson(p)
    let rbpi = rbpiBytesFromJson(js)
    let recovered = decodeRbpi(rbpi)
    check recovered.name == "smokeRoundTrip"
    check recovered.activities.len == 1
    check recovered.activities[0].body[0].pkgName == "neovim"

  test "rbpiBytesFromJson is deterministic":
    var p: ProfileIntent
    p.name = "det"
    p.activities.add ActivityIntent(name: "default", body: @[
      ActivityElement(kind: aekPackageRef, pkgName: "tmux")])
    let js = emitProfileIntentJson(p)
    let a = rbpiBytesFromJson(js)
    let b = rbpiBytesFromJson(js)
    check a == b

# ---------------------------------------------------------------------------
# Cache-layout helpers.
# ---------------------------------------------------------------------------

suite "M83 Phase C: cache layout":

  test "cache paths nest under <state-dir>/profile-cache":
    let stateDir = "/tmp/repro-fake-state".replace('/', DirSep)
    let key = "abcdef1234"
    let rbpi = cachedRbpiPath(stateDir, key)
    let nimcache = cachedNimcacheDir(stateDir, key)
    check rbpi.endsWith(key & ".rbpi")
    check nimcache.endsWith(key)
    check "profile-cache" in rbpi
    check "profile-cache" in nimcache

  test "the output name follows the profile path, never its content":
    # The declared output must not move when the profile's content does: an
    # output name keyed on content is a hand-written cache key in front of
    # the action cache, which is the defect the edge was rebuilt to remove.
    let dir = createTempDir("repro-profile-key-", "")
    defer: removeDir(dir)
    let root = writeProfileFile(dir, "home.nim", RootProfileBody)
    let before = profileCompileKey(root)
    writeFile(extendedPath(root), RootProfileBody & "\n# edited\n")
    check profileCompileKey(root) == before
    check before.len == 64
    # Two different profiles never share an output.
    let other = writeProfileFile(dir / "other", "home.nim", RootProfileBody)
    check profileCompileKey(other) != before

# ---------------------------------------------------------------------------
# BuildAction shape.
# ---------------------------------------------------------------------------

suite "M83 Phase C: profileCompileBuildAction":

  test "argv includes the internal helper subcommand + flag pairs":
    let weak = weakFingerprintFromText("smoke.weak")
    let act = profileCompileBuildAction(
      profileRoot = "/profile/home.nim",
      rbpiPath = "/cache/abc.rbpi",
      nimcacheDir = "/cache/nimcache/abc",
      publicCliPath = "/bin/repro",
      workDir = "/profile",
      repoRoot = "/repo",
      weak = weak,
      verbose = false)
    check act.id == "__repro_profile_compile"
    check act.id == ProfileCompileActionId
    check act.kind == bakProcess
    check act.cacheable
    # The caller's `weak` is the SEED of the edge's fingerprint, not the
    # fingerprint. `action()` keys whatever it is handed on the governing lock
    # identity, and Named-Lock-Files §7.2 is explicit that a caller must not be
    # able to opt out of that by supplying its own value: "Every action
    # fingerprint MUST include the identity of its governing lock file, and
    # this MUST be enforced by construction rather than by convention", because
    # under design A "a single edge whose fingerprint forgets the governing
    # lock identity is a silent poisoning vector — it serves one lock file's
    # artifacts to another and reports success."
    #
    # So `act.weakFingerprint == weak` would be the assertion that this edge
    # HAS that hole. It is asserted the other way round, against the same
    # composition `action()` performs, with the identity this edge names in its
    # own source: `lockIdentityOutsideSolvedGraph`, "the governing lock identity
    # of an edge that no solved graph reaches". §7.2 itself names three
    # mechanisms — a non-optional field, a whole-graph fingerprint audit, and a
    # release gate — and not that helper; the greppability argument for naming
    # it at the call site rather than defaulting it is made in the helper's own
    # doc comment in `repro_lock/identity.nim`, which is where to read it.
    #
    # The inequality below keeps this from passing vacuously against a
    # constructor that went back to passing the seed through.
    #
    # The edge also names `REPRO_NIM_COMPILER` (the helper compiles with it
    # when set, GM1) and the temp-directory variables (scratch placement
    # only; keyed by value they missed in every new `nix develop` shell) as
    # environment passthrough, and `action()` mixes the declared environment
    # in INSIDE the lock mix -- so the expectation composes the two in that
    # order.
    check act.weakFingerprint ==
      keyedOnGoverningLock(
        keyedOnActionEnvironment(weak, [], ProfileCompileEnvPassthrough),
        lockIdentityOutsideSolvedGraph())
    check act.envPassthrough == @[ProfileNimCompilerEnvVar, "TMPDIR", "TMP",
      "TEMP", "TEMPDIR"]
    check act.weakFingerprint != weak
    check act.argv[0] == "/bin/repro"
    check act.argv[1] == "__repro-compile-profile"
    check "--profile" in act.argv
    check "--rbpi" in act.argv
    check "--nimcache" in act.argv
    check "--repo-root" in act.argv
    check "/profile/home.nim" in act.argv
    check "/cache/abc.rbpi" in act.argv
    # The dependency record is the monitor's, and only the monitor's: no
    # hand-written depfile, no source manifest, no declared source list.
    check "--depfile" notin act.argv
    check "--manifest" notin act.argv
    check act.depfile.len == 0
    check act.inputs.len == 0
    check act.outputs == @["/cache/abc.rbpi"]
    check act.dependencyPolicy.kind == dgAutomaticMonitor
    check act.dependencyPolicy.recognizedReports.len == 0
    # The nimcache is derived state the compile reads back; it must not key
    # the edge.
    check act.dependencyPolicy.ignoredInputPrefixes ==
      @[absolutePath("/cache/nimcache/abc")]

  test "weak fingerprint names compiler and output identity, not sources":
    # Reduced to what monitoring cannot supply. Each of the four identities
    # moves it; nothing about a profile's sources is an argument at all, so
    # no source edit can (or needs to) reach it.
    let base = profileCompileWeakFingerprint("/nix/a/bin/nim", "/bin/repro",
      "/s/profile-cache/k.rbpi")
    check base == profileCompileWeakFingerprint("/nix/a/bin/nim",
      "/bin/repro", "/s/profile-cache/k.rbpi")
    check base != profileCompileWeakFingerprint("/nix/b/bin/nim",
      "/bin/repro", "/s/profile-cache/k.rbpi")
    check base != profileCompileWeakFingerprint("/nix/a/bin/nim",
      "/opt/repro", "/s/profile-cache/k.rbpi")
    check base != profileCompileWeakFingerprint("/nix/a/bin/nim",
      "/bin/repro", "/s/profile-cache/other.rbpi")
    # The C compiler is part of the compiler identity (GM1l).
    check base != profileCompileWeakFingerprint("/nix/a/bin/nim",
      "/bin/repro", "/s/profile-cache/k.rbpi", "/nix/cc/bin/cc")

  test "verbose=true adds --verbose argv element":
    let weak = weakFingerprintFromText("smoke.weak.v")
    let act = profileCompileBuildAction(
      profileRoot = "/p/home.nim",
      rbpiPath = "/c/a.rbpi",
      nimcacheDir = "/c/nc",
      publicCliPath = "/bin/repro",
      workDir = "",
      repoRoot = "/repo",
      weak = weak,
      verbose = true)
    check "--verbose" in act.argv

# ---------------------------------------------------------------------------
# The retired structural fast path. A valid `.rbpi` already sitting at the
# edge's output path used to be returned without the build engine ever being
# consulted; that is how a profile kept planning a stale intent. Here the
# helper binary does not exist, so the ONLY way to get the hand-rolled bytes
# back is a short-circuit in front of the edge. The e2e gates
# (`t_e2e_profile_compile_staticread_payload_change`) cover the same property
# against a real edge; this is the cheap tripwire.
# ---------------------------------------------------------------------------

suite "M83 Phase C: compileProfileToRbpi has no structural fast path":

  test "a valid envelope at the output path is not served without the edge":
    let stateDir = createTempDir("repro-profile-state-", "")
    defer: removeDir(stateDir)
    let profileSrcDir = createTempDir("repro-profile-src-", "")
    defer: removeDir(profileSrcDir)
    discard writeProfileFile(profileSrcDir, "home.nim", RootProfileBody)
    discard writeProfileFile(profileSrcDir, "sibling_helpers.nim",
      SiblingBody)
    let root = profileSrcDir / "home.nim"

    # Hand-roll an RBPI envelope exactly where the edge publishes.
    var p: ProfileIntent
    p.name = "smokeFastPath"
    let bytes = encodeRbpi(p)
    createDir(extendedPath(profileCacheDir(stateDir)))
    let rbpiPath = cachedRbpiPath(stateDir, profileCompileKey(root))
    writeBytesAtomic(rbpiPath, bytes)
    check rbpiEnvelopeIsValid(rbpiPath)

    let opts = ProfileCompileOptions(
      stateDir: stateDir,
      publicCliPath: "/nonexistent/repro",  # The edge cannot succeed.
      repoRoot: reprobuildRepoRoot())
    # Precondition: `nim` resolves, so the raise below comes from the edge
    # (whose helper does not exist), not from the missing-compiler check that
    # runs before any edge is scheduled.
    require findExe("nim").len > 0
    var served = false
    var raisedMsg = ""
    try:
      let artifact = compileProfileToRbpi(root, opts)
      served = artifact.rbpiBytes == bytes
    except ProfileCompileError as err:
      raisedMsg = err.msg
    checkpoint("raised: " & raisedMsg)
    check not served
    check raisedMsg.len > 0
    check "__repro_profile_compile" in raisedMsg

  test "compileProfileToRbpi rejects missing profile root":
    let stateDir = createTempDir("repro-profile-state-missing-", "")
    defer: removeDir(stateDir)
    let opts = ProfileCompileOptions(
      stateDir: stateDir,
      publicCliPath: "/nonexistent/repro")
    expect ProfileCompileError:
      discard compileProfileToRbpi(stateDir / "does_not_exist.nim", opts)

  test "compileProfileToRbpi requires stateDir + publicCliPath":
    var opts = ProfileCompileOptions(publicCliPath: "/x/repro")
    expect ProfileCompileError:
      discard compileProfileToRbpi("/p/home.nim", opts)
    opts = ProfileCompileOptions(stateDir: "/state")
    expect ProfileCompileError:
      discard compileProfileToRbpi("/p/home.nim", opts)

# ---------------------------------------------------------------------------
# Source-root and compiler resolution for an installed `repro`.
#
# These pin the precedence `reprobuildRepoRoot()` shares with the provider
# compile (`repro_core/source_root`) and the `$REPRO_NIM_COMPILER` contract,
# without a process launch. The end-to-end proof against a real installed
# package is `tests/e2e/m83/t_e2e_nix_package_compiles_profile.nim`.
# ---------------------------------------------------------------------------

proc fakeReprobuildTree(root: string) =
  ## The two markers the resolver and the compile check for.
  createDir(extendedPath(root / "libs" / "repro_project_dsl" / "src"))
  createDir(extendedPath(root / "libs" / "repro_profile" / "src"))

template withEnv(name, value: string; body: untyped) =
  let hadOld = existsEnv(name)
  let old = getEnv(name)
  if value.len > 0: putEnv(name, value) else: delEnv(name)
  try:
    body
  finally:
    if hadOld: putEnv(name, old) else: delEnv(name)

suite "installed repro: profile compile source root and compiler":

  test "REPROBUILD_SOURCE_ROOT is honoured when no override is set":
    let tree = createTempDir("repro-src-root-", "")
    defer: removeDir(tree)
    fakeReprobuildTree(tree)
    withEnv("REPROBUILD_LIBS_DIR", ""):
      withEnv("REPROBUILD_REPO_ROOT", ""):
        withEnv("REPROBUILD_SOURCE_ROOT", tree):
          check reprobuildRepoRoot() == tree

  test "REPROBUILD_REPO_ROOT outranks REPROBUILD_SOURCE_ROOT, and a stale " &
      "one falls through":
    let a = createTempDir("repro-src-root-a-", "")
    let b = createTempDir("repro-src-root-b-", "")
    defer:
      removeDir(a)
      removeDir(b)
    fakeReprobuildTree(a)
    fakeReprobuildTree(b)
    withEnv("REPROBUILD_LIBS_DIR", ""):
      withEnv("REPROBUILD_SOURCE_ROOT", b):
        withEnv("REPROBUILD_REPO_ROOT", a):
          check reprobuildRepoRoot() == a
        # An override naming a directory without reprobuild's libs is
        # skipped, not obeyed.
        withEnv("REPROBUILD_REPO_ROOT", a / "missing"):
          check reprobuildRepoRoot() == b

  test "a source root without reprobuild's libs is refused by name":
    let empty = createTempDir("repro-src-root-empty-", "")
    defer: removeDir(empty)
    try:
      requireReprobuildSources(empty)
      check false
    except CompileFailure as err:
      check empty in err.msg
      check "REPROBUILD_SOURCE_ROOT" in err.msg

  test "REPRO_NIM_COMPILER is used when set and refused when it names no file":
    let dir = createTempDir("repro-nim-compiler-", "")
    defer: removeDir(dir)
    let fakeNim = dir / addFileExt("my nim", ExeExt)
    writeFile(extendedPath(fakeNim), "")
    withEnv(ProfileNimCompilerEnvVar, fakeNim):
      check resolveProfileNimCompiler() == fakeNim
    withEnv(ProfileNimCompilerEnvVar, dir / "no-such-nim"):
      expect CompileFailure:
        discard resolveProfileNimCompiler()

  # The C compiler: the recipe compile's selection
  # (`repro_core/c_compiler.resolveConfiguredCCompiler`), handed to nim as an
  # explicit compiler and linker (Gradual-Nix-To-Reprobuild-Migration GM1l).
  # The end-to-end proof against the installed Nix package in a clean
  # environment is `tests/e2e/m83/t_e2e_nix_package_compiles_profile_clean_env.nim`.

  test "REPRO_BOOTSTRAP_CC names the profile compile's C compiler":
    let dir = createTempDir("repro-profile-cc-", " dir")
    defer: removeDir(dir)
    let fakeCC = dir / addFileExt("my cc", ExeExt)
    writeFile(extendedPath(fakeCC), "")
    withEnv("REPRO_BOOTSTRAP_CC", fakeCC):
      check resolveProfileCCompiler() == fakeCC
      let argv = profileCompileArgv("/n/bin/nim", "/p/home.nim", "/c/nc",
        "/c/out", "/r", resolveProfileCCompiler())
      for flag in ["--gcc.exe:", "--gcc.linkerexe:", "--clang.exe:",
                   "--clang.linkerexe:"]:
        check (flag & fakeCC) in argv
      var families = 0
      for arg in argv:
        if arg.startsWith("--cc:"):
          inc families
      check families == 1
      # Flags come before the profile, which stays the last argument.
      check argv[^1] == "/p/home.nim"

  test "a REPRO_BOOTSTRAP_CC naming no file is refused by name":
    let dir = createTempDir("repro-profile-cc-missing-", "")
    defer: removeDir(dir)
    withEnv("REPRO_BOOTSTRAP_CC", dir / "no-such-cc"):
      try:
        discard resolveProfileCCompiler()
        check false
      except CompileFailure as err:
        check ("REPRO_BOOTSTRAP_CC=" & dir / "no-such-cc") in err.msg

  test "no C compiler in the environment falls back to the build compiler":
    # What an installed package meets in a clean environment: no variable
    # and no `cc` on PATH. The compiler `repro` was built with is the answer
    # wherever it still exists (always, for a Nix package: the binary's
    # reference keeps it in the closure).
    when defined(windows):
      check BuiltCCompilerPath.len == 0
    else:
      let emptyBin = createTempDir("repro-profile-cc-path-", "")
      defer: removeDir(emptyBin)
      check BuiltCCompilerPath.len > 0
      withEnv("REPRO_BOOTSTRAP_CC", ""):
        withEnv("CC", ""):
          withEnv("PATH", emptyBin):
            check resolveProfileCCompiler() == BuiltCCompilerPath

  test "nim's default C compiler on PATH is left to nim":
    # The recipe compile would take `cc` from PATH; the profile compile keeps
    # Nim's default where it is available (see `resolveProfileCCompiler` for
    # the measured reason: a `cc` that is clang left the edge's first run
    # unpublished).
    let bin = createTempDir("repro-profile-cc-default-", "")
    defer: removeDir(bin)
    for name in [NimDefaultCCompilerExe, "cc"]:
      let exe = bin / addFileExt(name, ExeExt)
      writeFile(extendedPath(exe), "")
      setFilePermissions(extendedPath(exe), {fpUserRead, fpUserWrite,
        fpUserExec})
    withEnv("REPRO_BOOTSTRAP_CC", ""):
      withEnv("CC", ""):
        withEnv("PATH", bin):
          check resolveProfileCCompiler() == ""

  test "an empty C compiler leaves nim's default in place":
    let argv = profileCompileArgv("/n/bin/nim", "/p/home.nim", "/c/nc",
      "/c/out", "/r")
    for arg in argv:
      check not arg.startsWith("--cc:")
      check not arg.startsWith("--gcc.exe:")
      check not arg.startsWith("--passC:")

  # clang's `-fno-temp-file` (reprobuild-pm issue
  # 2026-10-14-clang-profile-compile-is-not-published-on-its-first-run). The
  # end-to-end proof that it makes a clang-driven compile publish on its
  # first run is `tests/e2e/m83/t_e2e_profile_compile_clang_first_run_published.nim`.

  test "executed profiles force C compilation rather than reuse opaque Nim objects":
    let argv = profileCompileArgv("/n/bin/nim", "/p/home.nim", "/c/nc",
      "/c/out", "/r")
    check "--forceBuild:on" in argv

  test "C flags reach nim as --passC, before the profile":
    let argv = profileCompileArgv("/n/bin/nim", "/p/home.nim", "/c/nc",
      "/c/out", "/r", "/cc/bin/clang", [clangNoTempFileFlag])
    check ("--passC:" & clangNoTempFileFlag) in argv
    check argv[^1] == "/p/home.nim"

  test "-fno-temp-file is probed by a real compile and is clang-only":
    # Real compilers, no fakes: the probe's job is to ask THIS binary, so a
    # stand-in would only test the stand-in. gcc rejects the flag, which is
    # the fail-safe arm measured on a real compiler; an invented flag is the
    # same arm on clang. Linux's dev shell has both compilers (`cc` is clang,
    # `gcc` is gcc); elsewhere each family present is checked.
    let scratch = createTempDir("repro-cc-flag-probe-", " dir")
    defer: removeDir(scratch)
    var clangExe, gccExe = ""
    for name in ["clang", "cc", "gcc"]:
      let exe = findExe(name)
      if exe.len == 0:
        continue
      if cCompilerFamily(exe) == "clang":
        if clangExe.len == 0: clangExe = exe
      elif gccExe.len == 0:
        gccExe = exe
    when defined(linux):
      doAssert clangExe.len > 0 and gccExe.len > 0,
        "needs clang and gcc on PATH (enter reprobuild's dev shell)"
    doAssert clangExe.len > 0 or gccExe.len > 0,
      "needs a C compiler on PATH (enter reprobuild's dev shell)"
    if clangExe.len > 0:
      checkpoint("clang: " & clangExe)
      check cCompilerAcceptsFlag(clangExe, clangNoTempFileFlag, scratch)
      check clangNoTempFileCFlags(clangExe, scratch) == @[clangNoTempFileFlag]
      check profileCompileCFlags(clangExe, scratch) ==
        @[clangNoTempFileFlag, "-MD -MT " & ProfileDepfileTarget &
          " -Xclang -dependency-file -Xclang " & nullDevice]
      check not cCompilerAcceptsFlag(clangExe, "-fno-repro-no-such-flag",
        scratch)
    if gccExe.len > 0:
      checkpoint("gcc: " & gccExe)
      check not cCompilerAcceptsFlag(gccExe, clangNoTempFileFlag, scratch)
      check clangNoTempFileCFlags(gccExe, scratch).len == 0
      check profileCompileCFlags(gccExe, scratch).len == 0
      # Positive control: the probe can say yes to gcc, so the no above is
      # gcc rejecting the flag and not a probe that never succeeds.
      check cCompilerAcceptsFlag(gccExe, "-O1", scratch)
    # A compiler that does not exist is a no, never an exception.
    check not cCompilerAcceptsFlag(scratch / "no-such-cc",
      clangNoTempFileFlag, scratch)
    check clangNoTempFileCFlags("", scratch).len == 0
    # The probe cleans up after itself.
    check not dirExists(scratch / "cc-flag-probe")

  test "the clang profile flags compile whatever dependency flags Nim adds":
    # Nim hands `--passC` to the C compiler split on spaces, beside its own
    # options. reprobuild's Nim fork (dev shell, Nix package) adds
    # `-MD -MF <file>.d`; the official 2.2.10 archive the recipe bootstrap
    # provisions adds neither, and cc1 refuses `-dependency-file` without a
    # target, so the profile compile failed outright under that Nim
    # (measured on m1, 2026-10-15, with Apple and Nix clang alike). Each
    # shape must compile and must write no `.d`: the report goes to the null
    # device. Real compilers, as in the probe test above.
    var clangExe = ""
    for name in ["clang", "cc"]:
      let exe = findExe(name)
      if exe.len > 0 and cCompilerFamily(exe) == "clang":
        clangExe = exe
        break
    if clangExe.len == 0:
      skip("no clang on PATH; the dependency-report flags are clang-only")
    else:
      checkpoint("clang: " & clangExe)
      let scratch = createTempDir("repro-profile-cflags-", " dir")
      defer: removeDir(scratch)
      let flags = profileCompileCFlags(clangExe, scratch)
      var passC: seq[string] = @[]
      for flag in flags:
        passC.add flag.splitWhitespace()
      check "-dependency-file" in passC
      let source = scratch / "unit.c"
      let objectFile = scratch / "unit.o"
      writeFile(source, "int repro_unit(void) { return 0; }\n")
      let forkDeps = @["-MD", "-MF", scratch / "unit.d"]
      for (shape, options) in [("official Nim", passC),
                               ("fork, its -MD first", forkDeps & passC),
                               ("fork, its -MD last", passC & forkDeps)]:
        checkpoint(shape)
        if fileExists(objectFile): removeFile(objectFile)
        let p = startProcess(clangExe, args = @["-c"] & options &
          @[source, "-o", objectFile], options = {poStdErrToStdOut})
        let output = p.outputStream.readAll()
        let code = p.waitForExit()
        p.close()
        checkpoint(output)
        check code == 0
        check fileExists(objectFile)
        for path in walkDir(scratch):
          check not path.path.endsWith(".d")

# ---------------------------------------------------------------------------
# An installed layout's source-only inputs (Gradual-Nix-To-Reprobuild-Migration
# GM1w).
#
# A release archive ships reprobuild's libs under `<prefix>/share/repro/source`
# and the inputs config.nims resolves through `*_SRC` under
# `<prefix>/share/repro/src/<rel>`. The compile derives them from the source
# root it was handed. The end-to-end proof against a real extracted Windows
# bundle is `tests/e2e/m83/t_e2e_windows_bundle_compiles_profile.nim`.
# ---------------------------------------------------------------------------

proc fakeInstalledPrefix(prefix: string; trees: openArray[string]) =
  let root = prefix / InstalledSourceRootSubdir
  fakeReprobuildTree(root)
  writeFile(extendedPath(root / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim"), "")
  writeFile(extendedPath(root / "config.nims"), "")
  for rel in trees:
    createDir(extendedPath(prefix / InstalledSourceTreesSubdir / rel))

suite "installed repro: the profile compile's source-only inputs":

  test "an installed source root brings the input trees shipped beside it":
    let prefix = createTempDir("repro installed prefix ", "")
    defer: removeDir(prefix)
    fakeInstalledPrefix(prefix, ["io-mon/src", "bearssl",
      "reprobuild-test-adapters/src"])
    let root = prefix / InstalledSourceRootSubdir
    withEnv("IO_MON_SRC", ""):
      withEnv("BEARSSL_SRC", ""):
        withEnv("REPRO_TEST_ADAPTERS_SRC", ""):
          withEnv("SHM_GSET_SRC", ""):
            let env = profileCompileChildEnv(root)
            check env["IO_MON_SRC"] ==
              prefix / InstalledSourceTreesSubdir / "io-mon/src"
            check env["BEARSSL_SRC"] ==
              prefix / InstalledSourceTreesSubdir / "bearssl"
            check env["REPRO_TEST_ADAPTERS_SRC"] ==
              prefix / InstalledSourceTreesSubdir /
                "reprobuild-test-adapters/src"
            # Not shipped in this prefix, so not invented.
            check not env.hasKey("SHM_GSET_SRC") or
              env["SHM_GSET_SRC"].len == 0

  test "an explicit caller value outranks the installed tree":
    let prefix = createTempDir("repro-installed-explicit-", "")
    defer: removeDir(prefix)
    fakeInstalledPrefix(prefix, ["io-mon/src"])
    withEnv("IO_MON_SRC", "/caller/io-mon/src"):
      let env = profileCompileChildEnv(prefix / InstalledSourceRootSubdir)
      check env["IO_MON_SRC"] == "/caller/io-mon/src"

  test "a source root that is not an installed layout takes nothing from " &
      "the table":
    # A checkout-shaped tree whose PARENT happens to hold a share/repro/src
    # must not be mistaken for an installed layout.
    let base = createTempDir("repro-not-installed-", "")
    defer: removeDir(base)
    let checkout = base / "reprobuild"
    fakeReprobuildTree(checkout)
    createDir(extendedPath(base / InstalledSourceTreesSubdir / "io-mon/src"))
    withEnv("IO_MON_SRC", ""):
      let env = profileCompileChildEnv(checkout)
      check not env.hasKey("IO_MON_SRC") or
        InstalledSourceTreesSubdir notin env["IO_MON_SRC"].replace("\\", "/")

  test "a source root without config.nims is refused by name":
    let prefix = createTempDir("repro-installed-no-config-", "")
    defer: removeDir(prefix)
    fakeInstalledPrefix(prefix, [])
    let root = prefix / InstalledSourceRootSubdir
    removeFile(extendedPath(root / "config.nims"))
    try:
      requireReprobuildSources(root)
      check false
    except CompileFailure as err:
      check "config.nims" in err.msg
      check root in err.msg

  test "the missing-sources diagnostic names the installed layout and the " &
      "variables":
    let msg = missingReprobuildSourcesMessage()
    check InstalledSourceRootSubdir in msg
    check "$REPROBUILD_SOURCE_ROOT" in msg
    check "$REPROBUILD_REPO_ROOT" in msg
