## `[records] url` in `repro-workspace.toml` decides where lock records are
## written: into the record-store checkout at `<workspace>/.repro/records`, and
## never into the root repository or another composed manifest layer. Without
## a url, no store is synthesized at all: the root and every layer are
## metadata, and the workspace is committed-lock-only unless a store checkout
## sits at its conventional location.
##
## Workspace-Settings-Files.md §3 gives `[records]` "the record store
## (generated lock records)", and §8 step 2 maps the old manifest url onto it:
## the record store is a SEPARATE repository, checked out at
## `<workspace>/.repro/records` (legacy `.repro/manifests` still accepted).
## §3 also says "No `[records] url` means no store is synthesized": the root
## repository and every `[[manifest]]` layer are metadata, and metadata is
## never the record store (Workspace-Manifests.md §"Metadata and records are
## separate repositories"; Unified-Locking-And-Hooks.md §5, and §14.1: a
## record store is "never the default and never inferred"). §8 says the same
## of a workspace whose old state file carried layers: after `health --fix`
## moves them, the root is the base layer but NOT the store.
## Unified-Locking-And-Hooks.md §10 ("What counts as declaring the route") is
## why an absent checkout must not be replaced by a guess: the route goes
## nowhere rather than somewhere else.
##
## The defects this pins:
##   * reprobuild-pm issues/2026-10-30-records-url-does-not-locate-the-lock-
##     record-store.md: `pickRecordStoreRoot` never read `[records]`. Once the
##     settings files declare ANY `[[manifest]]` layer, the root repository is
##     composed as the base layer FIRST (§3, `withSettingsLayers`), and the
##     first composed layer won, so a declared separate store was bypassed.
##   * reprobuild-pm issues/2026-11-16-repro-falls-back-to-the-root-or-origin-
##     as-the-lock-record-store-when-records-names-no-url.md: with NO
##     `[records] url` the first composed layer — the root — still became the
##     store, and `health --fix` told the operator so.
##
## Fixture (hermetic, local git only, real `repro` binary): a root-metadata
## workspace (`projects/` + `repos/` at the root, `.repro/` gitignored,
## `.repro/workspace-state.toml` naming the project), one participating repo
## cloned from a local bare origin (which gives the gate a lock to write), and
## one personal `[[manifest]]` layer in `repro-workspace.local.toml` — an empty
## directory outside the workspace that declares no project — whose only role
## is to make the root base layer the first composed layer, the shape the
## defects need. `repro-workspace.toml` declares `[records] url` + `branch`
## naming a local bare record-store repository, or `[records]` without a url.
##
## Cases:
##   a) the record-store checkout exists at `.repro/records`: the gate's lock
##      record lands there, and nothing lands in the root's `locks/`.
##   b) no checkout exists: nothing lands in the root's `locks/` either, the
##      gate still exits 0, and stderr names the declared url, the missing
##      `.repro/records` checkout, and the clone that fixes it.
##   c) `[records]` WITHOUT a url (only `publish_locks`) and no store checkout:
##      the gate passes and no lock record lands in the root, in the personal
##      layer, or under `.repro/` — the workspace is committed-lock-only.
##   d) the same with no `[records]` table at all.
##   e) the positive side of (c): no url, but a store checkout at
##      `.repro/records` — presence is the route declaration (§10), so the
##      record lands THERE and not in the root. This proves (c) records
##      nothing because no store is declared, not because the fixture cannot
##      produce a lock.
##   f) `migrated_layers_do_not_make_the_root_the_record_store` (§9): an old
##      state file whose first layer held `locks/`, no `[records]`, no store
##      checkout. `health --fix` moves the layers and names `[records] url` as
##      the remedy; a following lock write adds nothing under `locks/` in the
##      root, the moved layers, or the old store.
##
## No mocks: every git operation is real and local, and the binary under test
## is the built `repro`.
##
## Falsifiability: run against reprobuild 7170673ed (unfixed for the first
## issue), cases (a) and (b) fail because the lock record is written under the
## root's `locks/`. Run against d957b394f (unfixed for the second issue),
## cases (c) to (f) fail: the lock record is written under the root's
## `locks/` — in (e) even with a real store checkout at `.repro/records`,
## which the root base layer outranked — and `health --fix` says the root is
## "the lock record store unless repro-workspace.toml declares `[records]`".
## Cases (a) and (b) pass there, as the controls for the url-declared shape.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc lockRecordsUnder(dir: string): seq[string] =
  ## Every `.toml` under `dir/locks`, the subtree a lock record is written to.
  let locks = dir / "locks"
  if not dirExists(locks): return @[]
  for path in walkDirRec(locks):
    if path.endsWith(".toml"): result.add(path)

type Fixture = object
  scratch, workspaceRoot, recordStoreUrl: string

proc seedRepo(gitBin, bare, seed, branch, file: string) =
  ## A bare repository whose `branch` carries one commit, pushed from `seed`.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(seed))
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seed) &
    " config user.name \"Store Tester\"")
  writeFile(seed / file, "records url fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " add " & q(file))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seed) & " remote add origin " &
    q(bare))
  discard requireGit(q(gitBin) & " -C " & q(seed) & " push origin " & branch)

type RecordsShape = enum
  rsUrl         ## `[records]` with `url` + `branch`
  rsNoUrl       ## `[records]` with `publish_locks` only
  rsNoTable     ## no `[records]` table at all

proc buildFixture(gitBin, scratch: string; shape: RecordsShape;
                  oldStateLayer = ""): Fixture =
  ## ``oldStateLayer`` non-empty: instead of the current state file and the
  ## personal layer, write the state file under its RETIRED name with that
  ## directory as its FIRST `[[manifest]]` layer — the pre-settings-file shape
  ## in which the first layer was the lock record store (§8).
  result.scratch = scratch

  # ---- a participating repo with a local bare origin ----------------------
  let origin = scratch / "origin-lib.git"
  seedRepo(gitBin, origin, scratch / "seed-lib", "main", "README.md")

  # ---- the separate record-store repository --------------------------------
  let recordStore = scratch / "records.git"
  seedRepo(gitBin, recordStore, scratch / "seed-records", "records",
    "README.md")
  result.recordStoreUrl = fileUrl(recordStore)

  # ---- the workspace root: metadata at the root, `.repro/` ignored --------
  let workspaceRoot = scratch / "workspace"
  result.workspaceRoot = workspaceRoot
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  createDir(workspaceRoot / ".repro")
  writeFile(workspaceRoot / "repos" / "lib.toml",
    "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
    "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
    "mainline = \"main\"\n")
  writeFile(workspaceRoot / "projects" / "demo.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"demo\"\n" &
    "\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & fileUrl(scratch) &
    "\"\n\nincludes = [\n  \"repos/lib.toml\",\n]\n")
  if oldStateLayer.len > 0:
    writeFile(workspaceRoot / ".repro" / "workspace.toml",
      "schema = \"reprobuild.workspace.local.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\n\n" &
      "[[manifest]]\nlocal_path = \"" & tomlBasicString(oldStateLayer) &
      "\"\nvisibility = \"public\"\n")
  else:
    writeFile(workspaceRoot / ".repro" / "workspace-state.toml",
      "schema = \"reprobuild.workspace.state.v1\"\n\n" &
      "[workspace]\nproject = \"demo\"\n")
  # One personal layer beside the root's own. With it the settings files
  # declare a `[[manifest]]` layer, so the root repository is composed as the
  # base layer FIRST — the shape in which the unfixed resolver handed the
  # records to the root. It lies outside the workspace (§4 forbids a
  # `local_path` under `.repro/`) and declares no project, so it adds no repo
  # to `demo`.
  let personalLayer = scratch / "personal-manifests"
  createDir(personalLayer / "projects")
  if oldStateLayer.len == 0:
    writeFile(workspaceRoot / "repro-workspace.local.toml",
      "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
      "[[manifest]]\nlocal_path = \"" & tomlBasicString(personalLayer) &
      "\"\nvisibility = \"private\"\n")
  # Publication stays off (`publish_locks` absent): the gate still writes the
  # lock record into the store and passes, and WHERE it writes is the whole
  # subject. A `[records]` table is present in both shapes, so the control
  # differs from the subject by the url alone.
  let records =
    case shape
    of rsUrl:
      "[records]\nurl = \"" & tomlBasicString(result.recordStoreUrl) &
        "\"\nbranch = \"records\"\npublish_locks = false\n"
    of rsNoUrl:
      "[records]\npublish_locks = false\n"
    of rsNoTable:
      ""
  writeFile(workspaceRoot / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n" & records)
  writeFile(workspaceRoot / ".gitignore",
    ".repro/\nrepro-workspace.local.toml\n")
  writeFile(workspaceRoot / "README.md", "records url workspace\n")

  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.name \"Store Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m workspace")

  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
    q(workspaceRoot / "lib"))

proc runGate(fx: Fixture): CmdResult =
  ## The pre-push gate for a push from the participating repo. A push from
  ## the membership repo writes no lock record (it belongs to no partition,
  ## Unified-Locking-And-Hooks.md §6 Decision 1), so the gate has to be run
  ## from `lib` for there to be a record whose destination can be observed.
  result = runShell(shellCommand(@[reproBinary(), "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & (fx.workspaceRoot / "lib")]))
  checkpoint("check exit=" & $result.code & " output:\n" & result.output)

suite "[records] url locates the lock record store":

  test "a: the record-store checkout receives the lock, the root none":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-a-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, shape = rsUrl)
      let checkout = fx.workspaceRoot / ".repro" / "records"
      discard requireGit(q(gitBin) & " clone -b records " &
        q(fx.recordStoreUrl) & " " & q(checkout))

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(checkout).len > 0
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "manifests").len == 0
      # The checkout exists, so there is nothing to tell the user.
      check not res.output.contains("no checkout of it exists")

  test "b: no record-store checkout writes no lock into the root":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-b-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, shape = rsUrl)

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "records").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "manifests").len == 0
      # The notice names the declared store, where its checkout belongs, and
      # the clone that puts it there.
      check res.output.contains(fx.recordStoreUrl)
      check res.output.contains(fx.workspaceRoot / ".repro" / "records")
      check res.output.contains("no checkout of it exists")
      check res.output.contains("git clone -b records")
      # ...and says it once, however many seams resolve the store.
      check res.output.count("no checkout of it exists") == 1

  test "c: [records] without a url synthesizes no store":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-c-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, shape = rsNoUrl)

      let res = runGate(fx)
      check res.code == 0
      # PRIMARY: the root base layer is metadata, never the store.
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(fx.scratch / "personal-manifests").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "records").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "manifests").len == 0
      check not dirExists(fx.workspaceRoot / ".repro" / "records")
      check not res.output.contains("no checkout of it exists")

  test "d: no [records] table synthesizes no store":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-d-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, shape = rsNoTable)

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(fx.scratch / "personal-manifests").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "records").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "manifests").len == 0

  test "e: control - no url, but a store checkout at .repro/records":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-e-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, shape = rsNoUrl)
      let checkout = fx.workspaceRoot / ".repro" / "records"
      discard requireGit(q(gitBin) & " clone -b records " &
        q(fx.recordStoreUrl) & " " & q(checkout))

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(checkout).len > 0
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(fx.scratch / "personal-manifests").len == 0

  test "f: migrated_layers_do_not_make_the_root_the_record_store":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-f-", "")
      defer: removeDir(scratch)
      # The old store: the first layer of the old state file, which held
      # `locks/` when the first layer was where records went.
      let oldStore = scratch / "old-store"
      createDir(oldStore / "projects")
      createDir(oldStore / "locks" / "demo" / "lib")
      writeFile(oldStore / "locks" / "demo" / "lib" / "earlier.toml",
        "# a record written before the migration\n")
      let fx = buildFixture(gitBin, scratch, shape = rsNoTable,
        oldStateLayer = oldStore)

      let fixed = runShell(shellCommand(@[reproBinary(), "health", "--fix",
        "--offline", "--workspace-root=" & fx.workspaceRoot]))
      checkpoint("health --fix exit=" & $fixed.code & " output:\n" &
        fixed.output)
      check "moved manifest layer" in fixed.output
      require not fileExists(fx.workspaceRoot / ".repro" / "workspace.toml")
      # The output says the root is NOT the store and names the remedy.
      check "not the lock record store" in fixed.output
      check "committed-lock-only" in fixed.output
      check "`[records] url`" in fixed.output
      check "and so the lock record store" notin fixed.output

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(fx.workspaceRoot).len == 0
      check lockRecordsUnder(oldStore) ==
        @[oldStore / "locks" / "demo" / "lib" / "earlier.toml"]
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "records").len == 0
      check lockRecordsUnder(fx.workspaceRoot / ".repro" / "manifests").len == 0
