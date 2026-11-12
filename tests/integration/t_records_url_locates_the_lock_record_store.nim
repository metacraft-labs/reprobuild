## `[records] url` in `repro-workspace.toml` decides where lock records are
## written: into the record-store checkout at `<workspace>/.repro/records`, and
## never into the root repository or another composed manifest layer.
##
## Workspace-Settings-Files.md §3 gives `[records]` "the record store
## (generated lock records)", and §8 step 2 maps the old manifest url onto it:
## the record store is a SEPARATE repository, checked out at
## `<workspace>/.repro/records` (legacy `.repro/manifests` still accepted).
## Workspace-Manifests.md §"Metadata and records are separate repositories"
## says the same, and makes the root repository the store only when no
## `[records]` store is declared. Unified-Locking-And-Hooks.md §10 ("What
## counts as declaring the route") is why an absent checkout must not be
## replaced by a guess: the route goes nowhere rather than somewhere else.
##
## The defect this pins (reprobuild-pm
## issues/2026-10-30-records-url-does-not-locate-the-lock-record-store.md):
## `pickRecordStoreRoot` never read `[records]`. Once the settings files
## declare ANY `[[manifest]]` layer, the root repository is composed as the
## base layer FIRST (§3, `withSettingsLayers`), and the first composed layer
## won. A workspace that declared a separate record store therefore wrote —
## and, with `publish_locks`, published — its lock records into the root
## repository, with no diagnostic.
##
## Fixture (hermetic, local git only, real `repro` binary): a root-metadata
## workspace (`projects/` + `repos/` at the root, `.repro/` gitignored,
## `.repro/workspace-state.toml` naming the project), one participating repo
## cloned from a local bare origin (which gives the gate a lock to write), and
## one personal `[[manifest]]` layer in `repro-workspace.local.toml` — an empty
## directory outside the workspace that declares no project — whose only role
## is to make the root base layer the first composed layer, the shape the
## defect needs. `repro-workspace.toml` declares `[records] url` + `branch`
## naming a local bare record-store repository.
##
## Cases:
##   a) the record-store checkout exists at `.repro/records`: the gate's lock
##      record lands there, and nothing lands in the root's `locks/`.
##   b) no checkout exists: nothing lands in the root's `locks/` either, the
##      gate still exits 0, and stderr names the declared url, the missing
##      `.repro/records` checkout, and the clone that fixes it.
##   c) control: `[records]` WITHOUT a url keeps the root base layer as the
##      store, so the lock lands in the root's `locks/` — proving that the
##      difference in (a) is the url and not the fixture.
##
## No mocks: every git operation is real and local, and the binary under test
## is the built `repro`.
##
## Falsifiability: run against reprobuild 7170673ed (unfixed), case (a) fails
## because the lock record is written under the root's `locks/` and none under
## `.repro/records/locks/`, and case (b) fails on the same root `locks/` write
## and on the missing notice. Case (c) passes there too, as a control must.

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

proc buildFixture(gitBin, scratch: string; declareUrl: bool): Fixture =
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
  writeFile(workspaceRoot / "repro-workspace.local.toml",
    "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
    "[[manifest]]\nlocal_path = \"" & tomlBasicString(personalLayer) &
    "\"\nvisibility = \"private\"\n")
  # Publication stays off (`publish_locks` absent): the gate still writes the
  # lock record into the store and passes, and WHERE it writes is the whole
  # subject. A `[records]` table is present in both shapes, so the control
  # differs from the subject by the url alone.
  let records =
    if declareUrl:
      "[records]\nurl = \"" & tomlBasicString(result.recordStoreUrl) &
        "\"\nbranch = \"records\"\npublish_locks = false\n"
    else:
      "[records]\npublish_locks = false\n"
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
      let fx = buildFixture(gitBin, scratch, declareUrl = true)
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
      let fx = buildFixture(gitBin, scratch, declareUrl = true)

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

  test "c: control - [records] without a url keeps the root base layer":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real local repositories")
    else:
      let scratch = createTempDir("repro-records-url-c-", "")
      defer: removeDir(scratch)
      let fx = buildFixture(gitBin, scratch, declareUrl = false)

      let res = runGate(fx)
      check res.code == 0
      check lockRecordsUnder(fx.workspaceRoot).len > 0
      check not res.output.contains("no checkout of it exists")
