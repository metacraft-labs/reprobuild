## DS-6 (CLI/develop.md §"Action axis") — **`--list` on the SET path**.
##
##   > `--list` is the query form of the rule at the top of this section: it
##   > answers "what does this workspace's lock set manage?" without touching
##   > the tree. Its output names, per repo: the repo name, its resolved
##   > **tier**, its **backend**, the **locked revision**, the intended
##   > **path**, and its current state (`absent` / `at-lock` / `drifted` /
##   > `develop` / `evidence-only`). Machine consumers should use `--json`.
##   >
##   > **`--list` requires no selector** and defaults to the whole lock set,
##   > because a query has no destructive edge.
##
## Why this is not cosmetic. Before this milestone `--list` never reached the
## set path at all: `looksLikeDevelopAllArgs` returned FALSE on sight of
## `--list`, so the flag routed to the pre-set single-project route, which
## printed the local develop-OVERRIDE map and required a `repro.nim` project in
## the cwd. In a lock-routed workspace — the shape this whole command exists
## for — `repro develop --list` therefore answered a different question and
## usually just failed:
##
##   repro develop: error: repro develop requires a current project containing
##   repro.nim (or legacy reprobuild.nim)
##
## There was consequently NO read-only way to ask which repos a workspace's
## lock set manages, at which revisions, from which backends. `--dry-run`
## answers a narrower question (what would be PLACED) and drops evidence-only
## repos, the per-backend inventory, and every repo already on disk at its
## lock.
##
## THE TWO MEANINGS OF `--list` COLLIDE, and this test pins the resolution:
## bare `--list` is the lock-set query the spec assigns it, and the pre-set
## route's override listing keeps its exact output under the explicit
## `--list-overrides`. Nothing is lost — a repo in develop mode appears in the
## lock-set listing as a row with state `develop` and its override path.
##
## Fixture (built ``./build/bin/repro``, black-box, fully offline): a workspace
## with BOTH tiers populated, so the tier and backend columns have something to
## distinguish —
##
##   <scratch>/
##     origin-core.git   — the PUBLIC repo, pinned by the committed repro.lock
##     origin-team.git   — the TEAM repo, pinned by the git-checkout backend
##     ws/
##       repro.lock                — public tier / committed-lock backend
##       .repro/manifests/         — team tier / git-checkout backend
##       .repro-workspace.toml     — layer 4 route: team -> git-checkout
##       core/                     — on disk AT its locked revision (at-lock)
##       team-lib/                 — on disk, DRIFTED off it (drifted)
##
## Asserts:
##   1. `--list` needs no selector and lists the WHOLE lock set, with the six
##      columns, one row per repo, and the per-backend inventory naming each
##      tier, backend kind and location;
##   2. the four reachable states are reported truthfully: `at-lock`,
##      `drifted`, `absent`, and `develop` (after an override is recorded);
##   3. `--list --json` carries the same six fields per repo plus the backend
##      inventory, under `reprobuild.develop-list.v1`;
##   4. `--list` MUTATES NOTHING: the workspace tree is byte-identical
##      afterwards, compared entry-by-entry with size, mode and nanosecond
##      mtime — a "read-only" path that writes a receipt is not read-only;
##   5. the pre-set route's override listing is intact under
##      `--list-overrides`, byte-for-byte its old `<node>\t<path>` output.
##
## Falsifiability / pre-fix failure: against ``391a892a`` this test fails at
## (1) with exit 1 and
##
##   repro develop: error: repro develop requires a current project containing
##   repro.nim (or legacy reprobuild.nim)
##
## Mutation check: restoring `--list` to the `return false` list in
## ``looksLikeDevelopAllArgs`` reproduces exactly that and fails (1)-(4);
## moving the `--list` return in ``executeDevelopAll`` to AFTER the
## override-file write fails (4).
##
## Mocks: NONE. Real git repositories, a real committed lock, a real manifest
## checkout, the real ``repro`` binary, the real lock backends.
##
## Hermetic: fresh tempdir; every configuration layer except the fixture's own
## layer 4 is silenced. Skip: ``git`` missing or ``repro`` unbuilt.

import std/[algorithm, json, os, osproc, strutils, tempfiles, times, unittest]

const reproBinary = "./build/bin/repro"

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"DS6 Tester\"")

proc commitIn(gitBin, repo, name: string): string =
  writeFile(repo / name, name & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(repo) & " commit -m " & q(name))
  requireGit(q(gitBin) & " -C " & q(repo) & " rev-parse HEAD").strip()

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  let sha = commitIn(gitBin, workPath, "seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  sha

proc projectToml(coreUrl, teamUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"team-origin\"\nfetch = \"" & teamUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/team-lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc depInline(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", groups = \"\" }"

proc committedLock(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds6-fixture\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

type TreeEntry = object
  rel: string
  kind: string
  size: BiggestInt
  perms: string
  mtimeNs: int64

proc snapshotTree(root: string): seq[TreeEntry] =
  ## Every entry under ``root``, with size, permissions and NANOSECOND mtime.
  ## Coarser comparisons (existence, or second-resolution mtimes) would let a
  ## rewritten-in-place receipt pass as "unchanged".
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}, followFilter = {pcDir}):
    var e = TreeEntry(rel: relativePath(path, root))
    let info = getFileInfo(path, followSymlink = false)
    e.kind = $info.kind
    e.size = info.size
    e.perms = $info.permissions
    e.mtimeNs = info.lastWriteTime.toUnix() * 1_000_000_000 +
      info.lastWriteTime.nanosecond
    result.add(e)
  result.sort(proc (a, b: TreeEntry): int = cmp(a.rel, b.rel))

proc renderSnapshot(entries: seq[TreeEntry]): string =
  for e in entries:
    result.add(e.rel & "\t" & e.kind & "\t" & $e.size & "\t" & e.perms &
      "\t" & $e.mtimeNs & "\n")

proc rowFor(output, name: string): string =
  for line in output.splitLines():
    if line.startsWith(name & " ") or line == name: return line
  ""

suite "DS-6: --list answers the lock-set question, read-only":

  test "t_develop_list_reports_tier_and_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds6-list-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let teamSha = seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml("file://" & coreOrigin, "file://" & teamOrigin))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "team-lib.toml",
        repoFragment("team-lib", "team-origin"))
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      discard requireGit(q(gitBin) & " clone " & q("file://" & coreOrigin) &
        " " & q(ws / "core"))
      discard requireGit(q(gitBin) & " clone " & q("file://" & teamOrigin) &
        " " & q(ws / "team-lib"))
      createDir(ws / ".repro")
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")

      writeFile(ws / "repro.lock",
        committedLock(depInline("core", "core", "file://" & coreOrigin,
          coreSha)))
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"team-lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # Publish `team-lib`'s per-repo record into the TEAM backend.
      let lockRes = run(repro & " workspace lock --workspace-root=" & q(ws),
        cwd = ws)
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # `team-lib` DRIFTS off its locked revision; `core` stays at its lock.
      let driftSha = commitIn(gitBin, ws / "team-lib", "drift.txt")
      check driftSha != teamSha

      # ---- (1) --list with NO selector lists the whole set. ---------------
      let listed = run(repro & " develop --list --tool-provisioning=path",
        cwd = ws)
      if listed.code != 0:
        checkpoint("develop --list output: " & listed.output)
      check listed.code == 0
      check "REPO" in listed.output
      check "TIER" in listed.output
      check "BACKEND" in listed.output
      check "REVISION" in listed.output
      check "STATE" in listed.output
      check "PATH" in listed.output
      # The per-backend inventory — both tiers, both backend kinds, both
      # locations. It was previously computed on every run and printed only on
      # an EMPTY union, so no successful run could ever show it.
      check ("backend: public tier / committed-lock at " &
        (ws / "repro.lock")) in listed.output
      check ("backend: team tier / git-checkout at " & manifestsRoot) in
        listed.output
      # The fixed-order selection trace: six stages, none of them given here.
      for stage in ["mode --all", "project (not given)", "group (not given)",
                    "filter (not given)", "only (not given)",
                    "except (not given)"]:
        check ("selection: " & stage) in listed.output

      # ---- (2) tier / backend / revision / state per repo. ---------------
      let coreRow = rowFor(listed.output, "core")
      let teamRow = rowFor(listed.output, "team-lib")
      check coreRow.len > 0
      check teamRow.len > 0
      check "public" in coreRow
      check "committed-lock" in coreRow
      check coreSha in coreRow
      check "at-lock" in coreRow
      check (ws / "core") in coreRow
      check "team" in teamRow
      check "git-checkout" in teamRow
      check teamSha in teamRow
      check "drifted" in teamRow
      check (ws / "team-lib") in teamRow

      # ---- (3) --list --json carries the same facts, machine-readable. ---
      let jsonRes = run(repro &
        " develop --list --json --tool-provisioning=path", cwd = ws)
      check jsonRes.code == 0
      var jsonText = ""
      var inJson = false
      for line in jsonRes.output.splitLines():
        if not inJson and line.startsWith("{"): inJson = true
        if inJson: jsonText.add(line & "\n")
      let report = parseJson(jsonText)
      check report["schemaId"].getStr() == "reprobuild.develop-list.v1"
      check report["exitCode"].getInt() == 0
      var seenNames: seq[string]
      for repo in report["repos"]:
        seenNames.add(repo["name"].getStr())
        for field in ["name", "tier", "backend", "revision", "path", "state"]:
          check repo.hasKey(field)
        if repo["name"].getStr() == "team-lib":
          check repo["tier"].getStr() == "team"
          check repo["backend"].getStr() == "git-checkout"
          check repo["revision"].getStr() == teamSha
          check repo["state"].getStr() == "drifted"
      seenNames.sort()
      check seenNames == @["core", "team-lib"]
      var backendKinds: seq[string]
      for b in report["backends"]:
        backendKinds.add(b["kind"].getStr())
      backendKinds.sort()
      check backendKinds == @["committed-lock", "git-checkout"]

      # ---- (4) --list MUTATED NOTHING. -----------------------------------
      # Snapshot before/after over the WHOLE workspace, entry by entry.
      let before = snapshotTree(ws)
      check before.len > 0
      let again = run(repro & " develop --list --tool-provisioning=path",
        cwd = ws)
      check again.code == 0
      let againJson = run(repro &
        " develop --list --json --tool-provisioning=path", cwd = ws)
      check againJson.code == 0
      let after = snapshotTree(ws)
      if renderSnapshot(before) != renderSnapshot(after):
        checkpoint("workspace changed under --list")
      check renderSnapshot(before) == renderSnapshot(after)

      # ---- (2b) `absent` and `develop` states. ---------------------------
      # A repo whose intended path does not exist reads `absent`; one carrying
      # a develop override reads `develop` at the override's path.
      moveDir(ws / "core", scratch / "core-parked")
      let absentList = run(repro & " develop --list --tool-provisioning=path",
        cwd = ws)
      check absentList.code == 0
      check "absent" in rowFor(absentList.output, "core")

      let developed = run(repro & " develop --only=core --into=" &
        q(scratch / "deps") & " --tool-provisioning=path", cwd = ws)
      if developed.code != 0:
        checkpoint("develop --only=core output: " & developed.output)
      check developed.code == 0
      let developList = run(repro & " develop --list --tool-provisioning=path",
        cwd = ws)
      check developList.code == 0
      let developRow = rowFor(developList.output, "core")
      check "develop" in developRow
      check (scratch / "deps" / "core") in developRow

      # ---- (5) the pre-set route's override listing is intact. -----------
      # Its old flag was `--list`; the lock-set query took that name, so the
      # override map answers to `--list-overrides` and prints exactly what it
      # always printed: `<node>\t<path>`, one per line.
      let project = scratch / "project"
      createDir(project)
      writeFile(project / "repro.nim", "# fixture project\n")
      createDir(scratch / "dep-x")
      writeFile(scratch / "dep-x" / "repro.nim", "# fixture dependency\n")
      let overrideAdd = run(repro & " develop dep-x --into=" &
        q(scratch / "dep-x"), cwd = project)
      if overrideAdd.code != 0:
        checkpoint("develop dep-x --into output: " & overrideAdd.output)
      check overrideAdd.code == 0
      let overrideList = run(repro & " develop --list-overrides", cwd = project)
      check overrideList.code == 0
      check overrideList.output.strip() ==
        "dep-x\t" & os.normalizedPath(absolutePath(scratch / "dep-x"))
