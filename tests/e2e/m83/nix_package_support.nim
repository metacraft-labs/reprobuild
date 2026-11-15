## Shared helpers for the gates that run the INSTALLED Nix package — the
## `nix build` of this very checkout — rather than the checkout's
## `build/bin` binaries: `t_e2e_nix_package_compiles_profile.nim` (GM1) and
## `t_e2e_nix_package_compiles_profile_clean_env.nim` (GM1l).
##
## Every process is spawned from an argv sequence, never through a shell.

import std/[algorithm, json, os, osproc, sequtils, sets, streams, strtabs,
  strutils]

const ProjectRoot* = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
  ## The reprobuild checkout these tests belong to.

type RunResult* = tuple[exitCode: int; output: string]

proc run*(exe: string; args: openArray[string]; cwd: string;
          env: StringTableRef = nil): RunResult =
  ## Run `exe` with `args` in `cwd`, stderr merged into stdout. `env`, when
  ## given, is the child's WHOLE environment.
  let p = startProcess(exe, workingDir = cwd, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc runRelayingOutput(exe: string; args: openArray[string];
                        cwd: string): RunResult =
  ## `run`, except every line the child prints is also written to this
  ## process's stdout as it arrives.
  ##
  ## WHY THE BUILD LOG IS RELAYED. The work of a `nix build` happens in the
  ## nix daemon's builder, which is not in this case's process group. The
  ## test runner decides liveness from output and from the group's CPU, so
  ## a build that is compiling steadily reads as a case that is doing
  ## nothing: run 33 killed this gate on its IDLE TIMEOUT after 1800 s with
  ## 9.8 s of group CPU while the builder had compiled two of the package's
  ## fifteen binaries under a load average of ~90. The builder's own log
  ## (`-L`) is the honest progress signal: it advances exactly as fast as
  ## the build does, and a wedged build stops producing it.
  let p = startProcess(exe, workingDir = cwd, args = @args,
    options = {poStdErrToStdOut, poUsePath})
  let stream = p.outputStream
  var output = ""
  var line = ""
  while stream.readLine(line):
    output.add(line)
    output.add('\n')
    stdout.writeLine("nix build: " & line)
    stdout.flushFile()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc buildNixPackage*(): string =
  ## `nix build` of this checkout's `#default`, returning the store path.
  ## The flake is a git tree, so nix builds the working tree's tracked (and
  ## staged) files — the code under test, not a pinned release.
  ##
  ## `--print-build-logs` and the relay: see `runRelayingOutput`.
  let res = runRelayingOutput("nix", ["build", "--no-link",
    "--print-out-paths", "--print-build-logs", ProjectRoot & "#default"],
    ProjectRoot)
  doAssert res.exitCode == 0, "nix build failed:\n" & res.output
  for line in res.output.splitLines:
    if line.strip().startsWith("/nix/store/"):
      result = line.strip()
  doAssert result.len > 0, "nix build printed no store path:\n" & res.output

const
  NixPackageFixture* = ProjectRoot / "build" / "test-fixtures" /
    "nix-package" / "out-path"
    ## Written by the build-graph edge `reprobuild.test_fixtures.nix_package`
    ## (`scripts/build_nix_package_fixture.sh`): the store path of
    ## `nix build <ProjectRoot>#default`. Path kept in step with
    ## `nixPackageOutPathFixture` in `repro.nim`.
  NixPackageFixtureEdge = "reprobuild.test_fixtures.nix_package"

proc evalNixPackageOutPath(): string =
  ## The output path `<ProjectRoot>#default` evaluates to now — what a
  ## `nix build` of this tree would produce — without building it.
  ## The path is read from stdout alone: `--raw` prints it with no newline,
  ## so with stderr merged an evaluation warning could land on its line.
  let p = startProcess("nix", workingDir = ProjectRoot,
    args = ["eval", "--raw", ProjectRoot & "#default.outPath"],
    options = {poUsePath})
  let output = p.outputStream.readAll()
  let errors = p.errorStream.readAll()
  let code = p.waitForExit()
  p.close()
  result = output.strip()
  doAssert code == 0 and result.startsWith("/nix/store/") and
    ' ' notin result, "nix eval of the package failed (exit " & $code &
    "):\n" & output & "\n" & errors

proc nixPackageUnderTest*(): string =
  ## The installed package of THIS tree, as a store path.
  ##
  ## Normally the fixture edge's (`NixPackageFixture`): the suite builds it
  ## once, before the test phase, so the cases do not each run — and, run
  ## concurrently, wait silently on the nix daemon for — the same build. The
  ## recorded path is used only when it is what this tree evaluates to NOW and
  ## is present in the store: a fixture from an earlier tree, or one whose
  ## store path was collected, is not this tree's package. Otherwise (no
  ## fixture: the test binary run directly, or a failed edge) the case builds
  ## the package itself, as it always did, with the build log relayed.
  let expected = evalNixPackageOutPath()
  if fileExists(NixPackageFixture):
    let recorded = readFile(NixPackageFixture).strip()
    if recorded == expected and fileExists(recorded / "bin" / "repro"):
      echo "nix package: using ", recorded, " from fixture edge ",
        NixPackageFixtureEdge
      return recorded
    echo "nix package: fixture ", NixPackageFixture, " records ", recorded,
      ", but this tree evaluates to ", expected,
      (if recorded == expected: " (not in the store)" else: ""),
      "; building it here"
  else:
    echo "nix package: no fixture at ", NixPackageFixture, " (edge ",
      NixPackageFixtureEdge, "); building it here"
  stdout.flushFile()
  result = buildNixPackage()
  doAssert result == expected, "nix build produced " & result &
    ", but this tree evaluates to " & expected

proc packageClosure*(storePath: string): HashSet[string] =
  ## Every store path in `storePath`'s runtime closure
  ## (`nix path-info --recursive`).
  let res = run("nix", ["path-info", "--recursive", storePath], ProjectRoot)
  doAssert res.exitCode == 0, "nix path-info failed:\n" & res.output
  for line in res.output.splitLines:
    if line.strip().startsWith("/nix/store/"):
      result.incl line.strip()
  doAssert storePath in result, "closure of " & storePath & " lacks itself"

proc storePathOf*(path: string): string =
  ## The `/nix/store/<hash>-<name>` prefix of a path inside the store, or ""
  ## for a path outside it.
  const store = "/nix/store/"
  if not path.startsWith(store):
    return ""
  let rest = path[store.len .. ^1]
  let slash = rest.find('/')
  store & (if slash < 0: rest else: rest[0 ..< slash])

proc wrapperDefault*(wrapper, name: string): string =
  ## The value a makeWrapper `--set-default` line gives `name`:
  ##   export NAME=${NAME-'value'}
  let prefix = "export " & name & "=${" & name & "-'"
  for line in readFile(wrapper).splitLines:
    if line.startsWith(prefix) and line.endsWith("'}"):
      return line[prefix.len ..< line.len - 2]
  doAssert false, wrapper & " sets no default for " & name

# ---------------------------------------------------------------------------
# Which sources a profile compile read
# ---------------------------------------------------------------------------

const
  ReproLibMarker = "/libs/repro_"
    ## Reprobuild's own libraries live at `<source root>/libs/repro_*/src/`.
  ProfileLibMarker = "/libs/repro_profile/src/"
    ## Every profile imports `repro_profile`, so every compile reads modules
    ## from `<source root>/libs/repro_profile/src/`.

type ProfileCompileSources* = object
  ## Which reprobuild sources a profile compile read, from nim's own records
  ## in the compile's nimcache.
  ##
  ## WHY NOT `currentDir`. `profile-build.json`'s `currentDir` is the
  ## directory nim ran in. That used to be the resolved source root, and the
  ## gates compared it with the root they expected. Since 478890f088
  ## ("fix(profile-compile): run nim in the compile's nimcache") the compile
  ## runs in its private nimcache, so the working directory names no source
  ## root at all; the gates now check that it IS the nimcache.
  ##
  ## The root is read instead from the module paths the generated C embeds.
  ## A profile compile is a debug build (stack traces on), so every
  ## `<nimcache>/*.nim.c` names the absolute path of the Nim module it was
  ## generated from in its frame records (`nimfr_("name", "/abs/x.nim")`,
  ## `nimlf_(line, "/abs/x.nim")`), and `--forceBuild:on` regenerates all of
  ## them for every compile. The vendored `-I` flags that `config.nims`
  ## anchors on its own directory are not usable here: the Nix package
  ## compiles with `REPROBUILD_USE_SYSTEM_HASH_LIBS=1`, which emits none.
  ##
  ## The paths are read as they appear between the quotes of a C string
  ## literal. Nim escapes `"`, `\` and non-ASCII bytes there, so a source
  ## root containing one of them reads as a different path and the
  ## comparison fails rather than passes.
  nimcacheDir*: string
    ## The directory holding `profile-build.json`, symlinks resolved.
  currentDir*: string
    ## nim's working directory, symlinks resolved.
  reproLibModules*: seq[string]
    ## Every absolute `.../libs/repro_*/....nim` path embedded in the
    ## generated C: every module of reprobuild's own libraries the compile
    ## read. Sorted and de-duplicated.
  profileModules*: seq[string]
    ## The `.../libs/repro_profile/src/....nim` subset of `reproLibModules`.

proc embeddedReproLibModules(cText: string): seq[string] =
  ## The C string literals in `cText` that name a module of one of
  ## reprobuild's own libraries.
  var at = cText.find(ReproLibMarker)
  while at >= 0:
    let open = cText.rfind('"', last = at)
    let close = cText.find('"', at)
    if open >= 0 and close > at:
      let literal = cText[open + 1 ..< close]
      if literal.endsWith(".nim") and '\n' notin literal:
        result.add literal
    at = cText.find(ReproLibMarker, max(at + 1, close))

proc profileCompileSources*(nimcacheDir: string): ProfileCompileSources =
  ## Read `nimcacheDir`, the directory of a `profile-build.json`.
  result.nimcacheDir = expandFilename(nimcacheDir)
  let doc = parseFile(nimcacheDir / "profile-build.json")
  let cwd = doc["currentDir"].getStr()
  result.currentDir =
    if dirExists(cwd): expandFilename(cwd) else: cwd
  var found = initHashSet[string]()
  for kind, path in walkDir(nimcacheDir):
    if kind == pcFile and path.endsWith(".nim.c"):
      for module in embeddedReproLibModules(readFile(path)):
        found.incl module
  for module in found:
    result.reproLibModules.add module
  result.reproLibModules.sort()
  result.profileModules =
    result.reproLibModules.filterIt(ProfileLibMarker in it)

proc ranInItsNimcache*(src: ProfileCompileSources): bool =
  ## The compile ran in its own nimcache (478890f088), not a source root.
  src.nimcacheDir.len > 0 and src.currentDir == src.nimcacheDir

proc compiledAgainst*(src: ProfileCompileSources; root: string): bool =
  ## The compile read reprobuild's libraries from `root`, and from nowhere
  ## else: at least one `repro_profile` module lies under
  ## `<root>/libs/repro_profile/src/` (so the check cannot pass on an empty
  ## record), and every module of every `repro_*` library lies under
  ## `<root>/libs/`.
  let profilePrefix = root & ProfileLibMarker
  let libsPrefix = root & "/libs/"
  src.profileModules.len > 0 and
    src.profileModules.allIt(it.startsWith(profilePrefix)) and
    src.reproLibModules.allIt(it.startsWith(libsPrefix))
