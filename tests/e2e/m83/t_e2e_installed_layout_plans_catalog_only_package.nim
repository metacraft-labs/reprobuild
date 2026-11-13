## An installed reprobuild plans a home profile's catalog-only package from
## the catalog its release ships (POSIX layout).
##
## reprobuild-specs/Provisioning-Contributions.md §Profile Package References,
## step 2, and §Lookup step 4: for an installed reprobuild the catalog is the
## one at `<prefix>/share/repro/reprobuild-packages`, and a defined package
## with no realization is a missing realization, never an unknown package
## (§Resolution, step 5).
##
## The defect (reprobuild-pm issue 2026-10-27-installed-repro-profile-package-
## lookup-never-reaches-the-shipped-catalog): the planner's catalog lookup ran
## inside the engine image and took the reprobuild tree from
## `currentSourcePath()`, the checkout the engine was COMPILED in. A released
## engine therefore never looked under its own prefix, and every catalog-only
## profile package was "unknown". Measured 2026-10-27 on home-pc: the released
## `reprobuild-0.2.17-linux-x86_64.tar.gz`, extracted, plans this test's
## profile with `bfg-repo-cleaner` as `unknown-package` and no
## `catalog-projection`.
##
## How the layout is produced: the release job's POSIX packaging steps
## (`.github/workflows/release.yml`, "Package release assets (POSIX)") run on
## this checkout's `build/bin` and `build/lib`: copy into `<pkg>/bin` and
## `<pkg>/lib`, `scripts/release/stage_release_sources.sh` (which stages
## `share/repro/source`, `share/repro/src` and, through
## `stage_release_catalog.sh`, the PINNED catalog at
## `share/repro/reprobuild-packages`), and on Linux
## `scripts/relocate_release_posix.sh`, so the engine runs through the bundled
## loader exactly as an extracted tarball does. Deviations: the binaries are
## `bash scripts/build_apps.sh` output rather than `repro build .#release`; no
## RunQuota daemon is staged (a plan takes no lease); no tarball round trip --
## the tree is staged directly under a directory whose path has a space. On
## macOS the relocation is not run (it re-signs with `codesign`), so the
## Nix-linked images run in place.
##
## The engine compiled into `build/bin` names this checkout at compile time,
## and this checkout's workspace sibling `reprobuild-packages` (on a developer
## host) does define `bfg-repo-cleaner`. The copied engine must not reach it:
## the negative control proves it does not.
##
## Environment: every `REPROBUILD_*` and `*_SRC` variable is removed, with
## `REPRO_BOOTSTRAP_SOURCE_ENV`, `REPRO_PUBLIC_CLI_PATH` and
## `REPRO_NIM_COMPILER`; no `PATH` directory holding `repro`/`reprobuild` or
## lying in this workspace is kept (`nim` and a C compiler still come from
## `PATH`). HOME, the state, store and profile directories are scratch, and
## the working directory is outside any reprobuild tree.
##
## Vacuity guard: `just` (a stdlib package) is planned for `realize` in the
## same run, so the profile compiled and the planner ran.
##
## Negative control: the same layout with `share/repro/reprobuild-packages`
## deleted plans `bfg-repo-cleaner` as `unknown-package` and creates no
## `catalog-projection` -- the shipped catalog, not this checkout's sibling,
## supplied the definition.
##
## Mocks: none. The release staging scripts, the real thin client and engine,
## the real profile compile, interface extraction and planner.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath
from repro_core/process_streams import drainStream

import repro_test_support/reasoned_skip

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
const WorkspaceRoot = ProjectRoot.parentDir()

const CatalogOnlyPackage = "bfg-repo-cleaner"
  ## Defined by the pinned catalog (`packages/interfaces/bfg-repo-cleaner`)
  ## and by no linked definition, with no realization for this host.

const ProfileBody = """
import repro_profile

profile "shippedCatalog":
  activity default:
    `bfg-repo-cleaner`
    just
"""

type RunResult = tuple[exitCode: int; output: string]

proc run(exe: string; args: openArray[string]; cwd: string;
         env: StringTableRef = nil): RunResult =
  let p = startProcess(exe, workingDir = cwd, args = @args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc isUnder(path, root: string): bool =
  let r = root.strip(leading = false, chars = {'/'})
  path == r or path.startsWith(r & "/")

when defined(windows):
  suite "installed layout plans a catalog-only package (POSIX)":
    test "the POSIX installed layout reaches its shipped catalog":
      skip("[platform N/A] Windows runs the same check on the extracted " &
        "release zip: t_e2e_windows_bundle_compiles_profile")
else:
  proc stageLayout(scratch: string): string =
    ## The release job's POSIX packaging of this checkout, under a spaced
    ## directory. Returns the package directory.
    for image in ["repro", "reprobuild"]:
      doAssert fileExists(ProjectRoot / "build" / "bin" / image),
        image & " not found in build/bin; run `just build` first"
    result = scratch / "x b" / "reprobuild-test-posix"
    createDir(result / "bin")
    createDir(result / "lib")
    for kind, path in walkDir(ProjectRoot / "build" / "bin"):
      if kind in {pcFile, pcLinkToFile}:
        copyFileWithPermissions(path, result / "bin" / path.extractFilename)
    for kind, path in walkDir(ProjectRoot / "build" / "lib"):
      if kind in {pcFile, pcLinkToFile}:
        copyFileWithPermissions(path, result / "lib" / path.extractFilename)
    let stage = run("bash", ["scripts/release/stage_release_sources.sh",
      result], ProjectRoot)
    doAssert stage.exitCode == 0, "stage_release_sources failed:\n" &
      stage.output
    when defined(linux):
      let relocate = run("bash", ["scripts/relocate_release_posix.sh", result],
        ProjectRoot)
      doAssert relocate.exitCode == 0, "relocation failed:\n" &
        relocate.output
    for rel in ["share/repro/source/config.nims",
                "share/repro/source/libs/repro_profile/src/repro_profile.nim",
                "share/repro/reprobuild-packages/catalog-revision",
                "share/repro/reprobuild-packages/packages/interfaces/" &
                  CatalogOnlyPackage & "/repro.nim"]:
      doAssert fileExists(result / rel), "staged layout lacks " & rel

  proc scrubbedEnv(root: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      let name = k.toUpperAscii()
      if name.startsWith("REPROBUILD_") or name.endsWith("_SRC"):
        continue
      if name in ["REPRO_BOOTSTRAP_SOURCE_ENV", "REPRO_PUBLIC_CLI_PATH",
                  "REPRO_NIM_COMPILER", "REPRO_HOME_STATE_DIR",
                  "REPRO_HOME_GENERATION_DIR", "REPRO_HOME_PROFILE_DIR",
                  "REPRO_STORE_ROOT", "REPRO_HOST"]:
        continue
      result[k] = v
    var kept: seq[string]
    for dir in getEnv("PATH").split(PathSep):
      if dir.len == 0 or isUnder(dir, WorkspaceRoot):
        continue
      if fileExists(dir / "repro") or fileExists(dir / "reprobuild"):
        continue
      kept.add dir
    result["PATH"] = kept.join($PathSep)
    result["HOME"] = root / "home"
    result["XDG_STATE_HOME"] = root / "xdg-state"
    result["REPRO_HOME_PROFILE_DIR"] = root / "profile"
    result["REPRO_HOME_STATE_DIR"] = root / "state"
    result["REPRO_STORE_ROOT"] = root / "store"
    result["REPRO_HOST"] = "installed-shipped-catalog"

  type Scenario = object
    root, stateDir: string
    res: RunResult

  proc plan(bundle, label: string): Scenario =
    result.root = createTempDir("repro-shipped-catalog-" & label & "-", "")
    doAssert not isUnder(result.root, WorkspaceRoot)
    for dir in ["home", "xdg-state", "profile", "state", "store", "cwd"]:
      createDir(extendedPath(result.root / dir))
    writeFile(result.root / "profile" / "home.nim", ProfileBody)
    result.stateDir = result.root / "state"
    let env = scrubbedEnv(result.root)
    for k, v in env.pairs:
      doAssert not k.toUpperAscii().startsWith("REPROBUILD_"),
        "child env keeps " & k
    doAssert findExe("nim").len > 0, "no nim on PATH; run in the dev shell"
    result.res = run(bundle / "bin" / "repro",
      ["home", "apply", "--plan", "--allow-drift"], result.root / "cwd", env)

  proc packageLine(output, packageId: string): string =
    for line in output.splitLines():
      let t = line.strip()
      for action in ["realize  ", "cache-hit  ", "missing  "]:
        if t.startsWith(action & packageId & "  "):
          return t
    ""

  suite "installed layout plans a catalog-only package (POSIX)":
    let scratch = createTempDir("repro-shipped-catalog-pkg-", "")
    doAssert not isUnder(scratch, WorkspaceRoot)
    let bundle = stageLayout(scratch)
    let shipped = bundle / "share" / "repro" / "reprobuild-packages"

    test "the installed layout reaches the catalog it ships":
      let s = plan(bundle, "shipped")
      defer:
        try: removeDir(s.root) except OSError: discard
      checkpoint(s.res.output)
      check s.res.exitCode == 0
      # Vacuity: the profile compiled and the planner resolved a stdlib
      # package in the same run.
      check packageLine(s.res.output, "just").startsWith("realize  just  ")
      let line = packageLine(s.res.output, CatalogOnlyPackage)
      checkpoint(line)
      check line.len > 0
      # Defined by the shipped catalog: resolved or a missing realization,
      # never an unknown package.
      check "unknown-package" notin line
      check line.startsWith("realize  ") or "missing-realization" in line
      # The projection was built, and its recorded inputs name the shipped
      # catalog as the catalog root -- not this checkout's sibling.
      let projection = s.stateDir / "catalog-projection"
      check dirExists(projection)
      var fromShipped, fromWorkspace = false
      if dirExists(projection):
        for path in walkDirRec(projection):
          let text = readFile(path)
          if shipped in text:
            fromShipped = true
          if WorkspaceRoot / "reprobuild-packages" in text:
            fromWorkspace = true
      check fromShipped
      check not fromWorkspace

    test "negative control: without the shipped catalog the name is unknown":
      removeDir(shipped)
      doAssert not dirExists(shipped)
      let s = plan(bundle, "nocatalog")
      defer:
        try: removeDir(s.root) except OSError: discard
      checkpoint(s.res.output)
      check s.res.exitCode == 0
      check packageLine(s.res.output, "just").startsWith("realize  just  ")
      let line = packageLine(s.res.output, CatalogOnlyPackage)
      checkpoint(line)
      check line.startsWith("missing  " & CatalogOnlyPackage &
        "  (unknown-package: ")
      check not dirExists(s.stateDir / "catalog-projection")

    try: removeDir(scratch) except OSError: discard
