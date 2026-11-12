## A record-store CHECKOUT at its conventional location is a route
## declaration, so `repro workspace lock` must not tell that workspace it is
## public-only or send it to `repro locking adopt-manifest`.
##
## Unified-Locking-And-Hooks.md §10, "What counts as declaring the route":
##
##   > Either of two things, and nothing else:
##   >   1. a configuration layer that names the store, or
##   >   2. the record store existing as a checkout at its conventional
##   >      location (`.repro/records/`).
##
## The legacy `.repro/manifests` location is still accepted for the store
## (Workspace-Manifests.md, `recordStoreCandidates`), and `workspace lock`
## writes into a checkout at either location.
##
## The defect: `maybeWarnLegacyManifestWithoutTeamRoute` suppressed its
## one-time migration warning only for a configured route. A workspace whose
## store is a plain `git clone` at `.repro/records/` was told, by the very run
## that wrote its lock into that store, that it "is PUBLIC-ONLY and will stop
## writing its team manifest lock", and the advice named `.repro/manifests`, a
## directory the workspace does not have.
##
## Asserts:
##   1. `.repro/records/` is a git checkout, no route configured: the lock is
##      written into the store, and no migration warning is printed or
##      throttled (no sentinel).
##   2. The same with the store checkout at the legacy `.repro/manifests/`.
##   3. The mutation guard: `.repro/records/` exists but is NOT a checkout, so
##      nothing declares a route and the workspace really is public-only. The
##      warning still fires, and it names the directory that exists
##      (`.repro/records`) rather than a hard-coded `.repro/manifests`, and
##      its first remedy is to make that directory a checkout. A fix that
##      silenced the warning everywhere fails here.
##   4. A plain `.repro/records/` beside a `.repro/manifests/` checkout (mid-
##      migration): no warning, and `repro locking adopt-manifest` routes the
##      team tier to the CHECKOUT, so the next `workspace lock` still writes
##      the record there. Routing to the plain directory, which is first in
##      preference order, would stop the team lock.
##
## Falsifiability / pre-fix behavior: (1) and (2) fail on the
## "NO team route" / `adopt-manifest` text and on the sentinel; (3) fails on
## the warning naming `.repro/manifests`; (4) fails if `adopt-manifest` picks
## the first existing directory instead of the checkout.
##
## Mocks: NONE. Real git repositories, the real `repro` binary.
##
## Hermetic: fresh tempdir; configuration layers 2, 3 and 5 are silenced via
## the `REPROBUILD_*_CONFIG` overrides so no layer declares a route.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check`: this helper runs outside any `test` body, where
  ## `unittest.check` cannot see the injected `testStatusIMPL` and would report
  ## `[OK]` after printing "Check failed".
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Record Store Tester\"")

proc seedBare(gitBin, scratch, name, fileName: string): string =
  ## A bare origin at `<scratch>/<name>.git` with one commit on `main`.
  ## Returns the bare repository's path.
  result = scratch / (name & ".git")
  let seed = scratch / ("seed-" & name)
  discard requireGit(q(gitBin) & " init --bare -b main " & q(result))
  discard requireGit(q(gitBin) & " init -b main " & q(seed))
  configIdentity(gitBin, seed)
  writeFile(seed / fileName, name & " fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add " & q(fileName))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
    q(result))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin main")

type StoreShape = enum
  ssRecordsCheckout   ## `.repro/records/` is a clone of the record repo
  ssLegacyCheckout    ## `.repro/manifests/` is a clone of the record repo
  ssRecordsPlainDir   ## `.repro/records/` exists but is not a checkout
  ssPlainRecordsBesideLegacyCheckout
    ## a plain `.repro/records/` directory next to a `.repro/manifests/`
    ## checkout: a workspace mid-migration

proc buildWorkspace(gitBin, scratch: string; shape: StoreShape):
    tuple[ws, appSha, storeDir: string] =
  ## One project `p` with one repo `app`; metadata at the workspace root; the
  ## record store per ``shape``. No configuration layer declares a route.
  let appOrigin = seedBare(gitBin, scratch, "app", "README.md")
  let ws = scratch / "workspace"
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / "projects" / "p.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p\"\n\n" &
    "[[remote]]\nname = \"app-origin\"\nfetch = \"" & fileUrl(appOrigin) &
    "\"\n\n" &
    "includes = [\n  \"repos/app.toml\",\n]\n")
  writeFile(ws / "repos" / "app.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"app\"\npath = \"app\"\n" &
    "remote = \"app-origin\"\nmainline = \"main\"\n")
  writeWorkspaceBranch(ws, project = "p", branch = "main")
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(appOrigin)) & " " &
    q(ws / "app"))
  let appSha = requireGit(q(gitBin) & " -C " & q(ws / "app") &
    " rev-parse HEAD").strip()

  let storeDir =
    case shape
    of ssRecordsCheckout, ssRecordsPlainDir: ws / ".repro" / "records"
    of ssLegacyCheckout, ssPlainRecordsBesideLegacyCheckout:
      ws / ".repro" / "manifests"
  case shape
  of ssRecordsCheckout, ssLegacyCheckout, ssPlainRecordsBesideLegacyCheckout:
    let recordsOrigin = seedBare(gitBin, scratch, "records", ".gitkeep")
    createDir(storeDir.parentDir)
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(recordsOrigin)) &
      " " & q(storeDir))
    configIdentity(gitBin, storeDir)
    if shape == ssPlainRecordsBesideLegacyCheckout:
      createDir(ws / ".repro" / "records")
  of ssRecordsPlainDir:
    createDir(storeDir)
  (ws: ws, appSha: appSha, storeDir: storeDir)

proc sentinelPath(ws: string): string =
  ws / ".repro" / "workspace" / "legacy-manifest-migration.warned"

template withSilencedLayers(scratch: string; body: untyped) =
  putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
  try:
    body
  finally:
    delEnv("REPROBUILD_SYSTEM_CONFIG")
    delEnv("REPROBUILD_USER_CONFIG")
    delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

proc checkStoreCheckoutIsADeclaration(shape: StoreShape) =
  ## Shared body of cases (1) and (2).
  let gitBin = findExe("git")
  doAssert gitBin.len > 0
  let scratch = createTempDir("repro-record-store-route-", "")
  defer: removeDir(scratch)
  let reproBin = reproBinary()
  let fixture = buildWorkspace(gitBin, scratch, shape)
  withSilencedLayers(scratch):
    let res = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
      q(fixture.ws))
    checkpoint("workspace lock output: " & res.output)
    check res.code == 0

    # The store checkout declared the route, so the lock went into it.
    check fileExists(fixture.storeDir / "locks" / "p" / "app" /
      (fixture.appSha & ".toml"))

    # ...and nothing tells this workspace otherwise.
    check "NO team route" notin res.output
    check "PUBLIC-ONLY" notin res.output
    check "adopt-manifest" notin res.output
    # Nor is the warning merely deferred: no throttle sentinel was dropped.
    check not fileExists(sentinelPath(fixture.ws))

suite "a record-store checkout declares the route; no migration warning":

  test "t_records_checkout_without_configured_route_is_not_warned":
    if findExe("git").len == 0:
      skip("git is not on PATH — the fixture is real git repositories and " &
        "the claim is about a real git checkout, which has no substitute")
    else:
      checkStoreCheckoutIsADeclaration(ssRecordsCheckout)

  test "t_legacy_manifests_checkout_without_configured_route_is_not_warned":
    if findExe("git").len == 0:
      skip("git is not on PATH — the fixture is real git repositories and " &
        "the claim is about a real git checkout, which has no substitute")
    else:
      checkStoreCheckoutIsADeclaration(ssLegacyCheckout)

  test "t_records_dir_that_is_not_a_checkout_is_warned_by_its_own_name":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the fixture is real git repositories, " &
        "which have no substitute")
    else:
      let scratch = createTempDir("repro-record-store-route-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let fixture = buildWorkspace(gitBin, scratch, ssRecordsPlainDir)
      withSilencedLayers(scratch):
        let res = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
          q(fixture.ws))
        checkpoint("workspace lock output: " & res.output)
        check res.code == 0

        # Nothing declares a route: the warning is TRUE here and still fires.
        check "NO team route" in res.output
        check "adopt-manifest" in res.output
        check fileExists(sentinelPath(fixture.ws))
        # It names the directory the workspace actually has.
        check "`.repro/records`" in res.output
        check ".repro/manifests" notin res.output
        # Its first remedy is the one a declaration needs: make the directory
        # a checkout (an explicit route to a non-checkout records nothing).
        check "is itself the route declaration" in res.output

  test "t_adopt_manifest_routes_to_the_checkout_not_a_plain_dir_beside_it":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the fixture is real git repositories, " &
        "which have no substitute")
    else:
      let scratch = createTempDir("repro-record-store-route-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let fixture = buildWorkspace(gitBin, scratch,
        ssPlainRecordsBesideLegacyCheckout)
      withSilencedLayers(scratch):
        let first = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
          q(fixture.ws))
        checkpoint("workspace lock output: " & first.output)
        check first.code == 0
        # The `.repro/manifests` checkout declares the route.
        check "NO team route" notin first.output
        check not fileExists(sentinelPath(fixture.ws))

        let adopted = runCmd(q(reproBin) & " locking adopt-manifest" &
          " --workspace-root=" & q(fixture.ws))
        checkpoint("locking adopt-manifest output: " & adopted.output)
        check adopted.code == 0
        let cfg = scratch / "no-vcs.toml"
        check fileExists(cfg)
        if fileExists(cfg):
          let body = readFile(cfg)
          check "path = \".repro/manifests\"" in body
          check ".repro/records" notin body

        # The scaffolded route is a WORKING team route: the next lock still
        # writes its record into the checkout, with no backend refusal.
        let lockPath = fixture.storeDir / "locks" / "p" / "app" /
          (fixture.appSha & ".toml")
        removeFile(lockPath)
        let second = runCmd(q(reproBin) & " workspace lock --workspace-root=" &
          q(fixture.ws))
        checkpoint("workspace lock (routed) output: " & second.output)
        check second.code == 0
        check "is not a git checkout" notin second.output
        check fileExists(lockPath)
