## The Windows loader-library list is a CONTRACT, not a note.
##
## Distribution-And-Packaging M1's N26. `stageInstallTree` gates the
## runtime-closure walk, the RPATH rewrite and the ELF-interpreter rewrite on
## `toLinux`; there is no PE equivalent. `RuntimeContract.dlopenLeafNames` is
## a CHECKED POST-CONDITION on Linux -- `require_dlopen` fails the build when
## a declared name will not resolve into the vendored closure -- and on
## Windows there was, in review's words, "neither a case over
## `reprobuildWindowsLoaderLibraries` nor a build-graph assertion over the
## staged tree". Three reviews passed a package whose service could never
## start, because the developer `%PATH%` that built it supplied the
## difference.
##
## WHAT THIS FILE CAN AND CANNOT CLOSE, stated up front because the
## distinction is the whole of N26. These cases are a GRAPH property: the
## list and the staged tree are ONE list, every name lands where the loader
## will look, and the payload the recipe stages from actually contains each
## file. They run on any host. What they CANNOT do is notice that
## `repro.exe` learned to load something nobody put in the list -- a curated
## list closes over the names somebody scanned for, and no reading of it
## finds the name that is missing.
##
## That half is `scripts/check_windows_scrubbed_launch.ps1`, which launches
## the SHIPPED BYTES with the environment rebuilt from empty. It is the
## check that found `libwinpthread-1.dll` missing from a package the
## previous pass had declared verified -- a static import of
## `libgcc_s_seh-1.dll`, which is itself a static import of
## `librepro_project_dsl_runtime.dll`, so the DSL runtime every `repro build`
## loads failed `LoadLibrary` with ERROR_MOD_NOT_FOUND off a developer host.
## The last case here is that finding turned into a rule.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

const Quote = $chr(39)

const
  FixtureRel = "tests/fixtures/packaging/reprobuild-dist"
  StagingScriptRel = "scripts/stage_payload_windows.sh"
  LinuxStagingScriptRel = "scripts/stage_payload_linux.sh"
  ScriptListVars = ["LOADER_LIBS_FROM_BUILD_BIN",
                    "LOADER_LIBS_FROM_MSYS2_MINGW64",
                    "LOADER_LIBS_FROM_GCC",
                    # M1's N32: the Visual C++ runtime, vendored app-local
                    # from the Visual Studio redist directory.
                    "LOADER_LIBS_FROM_VC_REDIST"]

const OwnSharedLibraries = ["librepro_monitor_shim.dll",
                            "librepro_project_dsl_runtime.dll"]
  ## reprobuild's OWN shared libraries. They are in the payload and they
  ## are not loader libraries -- the recipe stages them by name, and
  ## `reprobuildWindowsLoaderLibraries` is about third-party ones.

proc payloadLibDir(): string =
  repoRootFromTest() & "/" & FixtureRel & "/prebuilt/lib"

proc scriptStagedDlls(): seq[string] =
  ## Every third-party DLL `scripts/stage_payload_windows.sh` copies into
  ## `prebuilt/lib`, PARSED OUT OF THE SCRIPT.
  ##
  ## THIS IS THE INDEPENDENT SIDE, and it is a FILE rather than a directory
  ## for a reason that took a rewrite to see: `prebuilt/` is GITIGNORED, so
  ## a case that enumerated the staged directory could only say anything on
  ## a machine that had already staged it, and would answer "no DLLs, every
  ## assertion vacuously true" in CI and in a fresh clone. The staging
  ## script is checked in, so this comparison is checked-in against
  ## checked-in and runs everywhere.
  ##
  ## Why not derive it from the Nim list: that is the defect this campaign
  ## already made once -- a totality case whose two sides both came from
  ## one list agreed by construction and passed a twenty-second variable
  ## injected into it.
  let path = repoRootFromTest() & "/" & StagingScriptRel
  doAssert fileExists(path), "staging script not found at " & path
  var found = 0
  for line in readFile(path).splitLines():
    let stripped = line.strip()
    for v in ScriptListVars:
      if not stripped.startsWith(v & "="):
        continue
      found.inc
      var value = stripped[(v.len + 1) .. ^1].strip()
      doAssert value.len >= 2 and value.startsWith(Quote) and
          value.endsWith(Quote),
        v & " is not a single-quoted word list: " & value
      value = value[1 .. ^2]
      for name in value.split(' '):
        let leaf = name.strip()
        if leaf.len > 0:
          result.add(leaf & ".dll")
  doAssert found == ScriptListVars.len,
    "the staging script no longer declares all of " & $ScriptListVars &
      " (found " & $found & "): either it was rewritten or this parser " &
      "stopped working, and a parser that reads nothing must not report " &
      "an empty set as agreement"

proc payloadRoot(): string =
  ## A real directory tree on disk. `stageInstallTree` ENUMERATES a
  ## `crSourceTree` component's files from the filesystem and refuses a
  ## component that stages empty, so the sample needs a payload rather than
  ## a promise of one -- the same reason `t_packaging_shipped_payload` has
  ## this helper.
  result = "build/test-tmp/win-loader-closure"
  removeDir(result)
  createDir(result)

proc windowsSample(): Distribution =
  ## The Windows CLI distribution, staged the way the recipe stages it.
  result = newReprobuildDistribution("0.1.3", toWindows, prefix = "")
  result.components = @[
    executableComponent("prebuilt/bin/repro.exe"),
    component(crHelperExecutable, "prebuilt/bin/repro-standard-provider.exe"),
  ]
  for leaf in OwnSharedLibraries:
    result.components.add(runtimeLibraryComponent("prebuilt/lib/" & leaf))
  for leaf in scriptStagedDlls():
    result.components.add(runtimeLibraryComponent("prebuilt/lib/" & leaf))
  # The bundled compiler and the source trees. Not decoration: staging
  # runs `requireEnvDefaultPayload`, which refuses a tree whose wrapper
  # names a prefix-relative path nothing installs -- so a sample that
  # carried only the libraries could not be staged at all, and the
  # loader-library assertions below would have had nothing to read.
  let root = payloadRoot()
  result.components.add(component(crHelperExecutable,
    root & "/" & reprobuildNimToolchainPrefixRel(result) & "/bin/nim.exe",
    subdir = ReprobuildNimToolchainSubdir & "/bin"))
  for rel in reprobuildShippedTreeDirs(result):
    createDir(root & "/" & rel)
    writeFile(root & "/" & rel & "/payload.nim", "discard")
  result.components.add(reprobuildShippedTreeComponents(result, root))

proc stagedLeafNames(dist: Distribution): seq[string] =
  ## Every file the MSI tree stages, by BASENAME. Derived from the staging
  ## result rather than from the component list it was built from: a
  ## component that staged nowhere must not be able to satisfy this.
  for f in stageInstallTree(dist, "msi").files:
    result.add(f.rootRelPath.extractFilename)

proc stagedRootRel(dist: Distribution; leaf: string): string =
  for f in stageInstallTree(dist, "msi").files:
    if f.rootRelPath.extractFilename == leaf:
      return f.rootRelPath
  ""

proc sourceFilterExtensions(scriptRel: string): seq[string] =
  ## The `-name '*.X'` operands of a staging script's source-tree `find`.
  ##
  ## M1's N10: the payload's source trees are FILTERED BY EXTENSION, which
  ## is a rule and not a proof. This does not make it a proof. What it does
  ## is stop the two rules from drifting apart -- the Windows payload
  ## already diverged from the Linux one once, and a package that compiles
  ## on one target and not the other because a file type reached one tree
  ## and not the other is the expensive shape of that.
  let path = repoRootFromTest() & "/" & scriptRel
  doAssert fileExists(path), "staging script not found at " & path
  let text = readFile(path)
  var i = 0
  const Needle = "-name " & Quote & "*."
  while true:
    let at = text.find(Needle, i)
    if at < 0: break
    let start = at + Needle.len
    let stop = text.find(Quote, start)
    doAssert stop > start, "unterminated -name operand in " & scriptRel
    let ext = text[start ..< stop]
    if ext notin result:
      result.add(ext)
    i = stop + 1

suite "packaging: the Windows loader-library list is checked":

  test "the list is non-empty on both arms":
    # VACUITY FIRST. Every other case here is a statement about members of
    # this list, so an empty list would make all of them pass while the
    # package shipped nothing.
    doAssert reprobuildWindowsLoaderLibraries(includeCli = true).len >= 6
    doAssert reprobuildWindowsLoaderLibraries(includeCli = false).len >= 3

  test "every name is a bare DLL leaf, not a path and not a pattern":
    for includeCli in [true, false]:
      for leaf in reprobuildWindowsLoaderLibraries(includeCli):
        doAssert leaf.endsWith(".dll"), leaf
        doAssert '/' notin leaf and '\\' notin leaf, leaf
        doAssert '*' notin leaf and '(' notin leaf and '|' notin leaf, leaf
        for c in leaf:
          doAssert c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '+', '-'},
            "loader library name has a character staging cannot quote: " & leaf

  test "the cache arm is a strict subset of the CLI arm":
    let cli = reprobuildWindowsLoaderLibraries(includeCli = true)
    let cache = reprobuildWindowsLoaderLibraries(includeCli = false)
    for leaf in cache:
      doAssert leaf in cli, "cache-only loader library: " & leaf
    doAssert cache.len < cli.len,
      "the two arms are the same list; `includeCli` decides nothing"
    # The CLI-only names, named so that moving one into the cache arm is a
    # decision somebody has to make here rather than a silent widening.
    for leaf in ["libzstd.dll", "clingo.dll", "libgcc_s_seh-1.dll",
                 "libwinpthread-1.dll"]:
      doAssert leaf in cli, leaf
      doAssert leaf notin cache, "cache package does not link " & leaf

  test "every listed library is STAGED, and into bin/":
    # THE POST-CONDITION `dlopenLeafNames` gives Linux, given to Windows:
    # a name in the list that does not reach the tree is a failure here
    # rather than a missing file on somebody else's machine.
    let dist = windowsSample()
    let staged = stagedLeafNames(dist)
    for leaf in reprobuildWindowsLoaderLibraries(includeCli = true):
      doAssert leaf in staged,
        "declared by reprobuildWindowsLoaderLibraries and staged nowhere: " &
          leaf
      # `bin/`, and this is not cosmetic: `msiServiceRows` registers the
      # REAL executable rather than the `.cmd` wrapper, so the service
      # process inherits none of the wrapper's environment and the only
      # directory it searches is the one its image sits in.
      doAssert stagedRootRel(dist, leaf) == "bin/" & leaf,
        leaf & " staged at " & stagedRootRel(dist, leaf) & ", not bin/"

  test "the staging script and the list name the SAME set, both ways":
    # N2's cost, made checkable. `prebuilt/` is gitignored and filled by
    # `scripts/stage_payload_windows.sh`; that script and
    # `reprobuildWindowsLoaderLibraries` are two independent statements of
    # one set, and either drifting from the other is a package that stages
    # a file nothing installs, or names a file nothing staged -- the
    # second of which is exactly what shipped for three passes.
    let cli = reprobuildWindowsLoaderLibraries(includeCli = true)
    let script = scriptStagedDlls()
    doAssert script.len > 0
    for leaf in cli:
      doAssert leaf in script,
        "reprobuildWindowsLoaderLibraries names " & leaf &
          " and scripts/stage_payload_windows.sh does not stage it"
    for leaf in script:
      doAssert leaf notin OwnSharedLibraries, leaf
      doAssert leaf in cli,
        "scripts/stage_payload_windows.sh stages " & leaf &
          " and reprobuildWindowsLoaderLibraries does not name it"
    doAssert script.len == cli.len,
      "script stages " & $script.len & ", the list names " & $cli.len

  test "...and, where the payload IS staged, it agrees with both":
    # The ON-DISK arm. It cannot be the primary one -- `prebuilt/` is
    # gitignored, so in CI and in a fresh clone there is nothing to read --
    # but where a developer HAS staged the payload it is the only arm that
    # sees the bytes, and a run that skipped it SAYS SO rather than
    # counting itself as agreement.
    #
    # AND IT ONLY APPLIES TO A WINDOWS PAYLOAD. One `prebuilt/` directory
    # serves both targets and holds whichever was staged last: on the Linux
    # clone it is `.so` files and the three linker aliases, which this list
    # has nothing to say about. `prebuilt/bin/repro.exe` is the unambiguous
    # marker, and the skip is announced rather than silent.
    let windowsPayload = fileExists(
      repoRootFromTest() & "/" & FixtureRel & "/prebuilt/bin/repro.exe")
    if not dirExists(payloadLibDir()) or not windowsPayload:
      echo "  [no WINDOWS payload staged at ", payloadLibDir(),
        "; the script-vs-list arm above still ran]"
    else:
      var onDisk: seq[string] = @[]
      for kind, path in walkDir(payloadLibDir()):
        if kind == pcFile and path.toLowerAscii.endsWith(".dll"):
          onDisk.add(path.extractFilename)
      doAssert onDisk.len > 0, "prebuilt/lib exists and holds no DLL"
      for leaf in reprobuildWindowsLoaderLibraries(includeCli = true):
        doAssert leaf in onDisk,
          "listed loader library is not in the staged payload: " & leaf
      for leaf in onDisk:
        if leaf in OwnSharedLibraries: continue
        doAssert leaf in reprobuildWindowsLoaderLibraries(includeCli = true),
          "prebuilt/lib ships " & leaf & " and the list does not name it"

  test "both staging scripts filter source trees by the SAME extensions":
    # N10, narrowed rather than closed. The filter is still a RULE -- these
    # cases cannot show that everything a Nim compile can open is kept --
    # but the two payloads can no longer be filtered differently, and the
    # rule is no longer written twice in two scratch directories.
    let win = sourceFilterExtensions(StagingScriptRel)
    let lin = sourceFilterExtensions(LinuxStagingScriptRel)
    doAssert win.len >= 10,
      "parsed " & $win.len & " extensions out of " & StagingScriptRel &
        "; a parser that reads almost nothing must not report agreement"
    doAssert lin.len == win.len, $lin & " vs " & $win
    for ext in win:
      doAssert ext in lin,
        StagingScriptRel & " keeps *." & ext & " and " &
          LinuxStagingScriptRel & " drops it"
    for ext in lin:
      doAssert ext in win,
        LinuxStagingScriptRel & " keeps *." & ext & " and " &
          StagingScriptRel & " drops it"
    # The ones a Nim compile reaches directly, named so that dropping one
    # is a decision somebody makes here.
    for ext in ["nim", "nims", "nimble", "cfg", "h", "c"]:
      doAssert ext in win, "the payload no longer keeps *." & ext

  test "a static import of a listed library is listed too":
    # THE RULE THE SCRUBBED CHECK EARNED. `libgcc_s_seh-1.dll` was added to
    # the list because a PE scan of the EXECUTABLES found it. Nobody scanned
    # the library itself, which imports `libwinpthread-1.dll`, so the
    # package shipped an unwinder that could not load and a
    # `librepro_project_dsl_runtime.dll` that could not load behind it.
    #
    # The general form of this is the PE walk N26 still asks for. The
    # specific pairs measured so far are pinned here, so that dropping one
    # half of a known pair is a red suite rather than a Windows-only
    # discovery.
    let cli = reprobuildWindowsLoaderLibraries(includeCli = true)
    const KnownStaticImports = {
      "libgcc_s_seh-1.dll": "libwinpthread-1.dll",
    }
    for (importer, imported) in KnownStaticImports.items:
      if importer in cli:
        doAssert imported in cli,
          importer & " is staged but its static import " & imported &
            " is not; `LoadLibrary` on the importer answers 126 and the " &
            "process that needed it dies before main"
