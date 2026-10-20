## The committed lock pins a dependency's IDENTITY and never its
## MATERIALIZATION: no `deps` record carries a filesystem `path`, and where a
## dependency is checked out is derived on THIS machine from its name.
##
## Workspace-Manifests.md §"The locked-dependency model": "**A lock pins a
## dependency IDENTITY, not a materialization.**" — identity, coordinates,
## integrity, solved version and metadata, and nothing else. §"Mode-agnostic":
## "the materialization is chosen locally". Issue
## `2026-10-14-committed-lock-records-a-filesystem-path-per-dependency.md`
## records the measured violation: every `reprobuild.solved-graph-lock.v2`
## `deps` record carried a workspace-relative `path`; one of them,
## `../dev/reprobuild-latest`, named a directory that never existed, and every
## workspace-resolving command then announced that two locks "disagree" on it.
##
## Asserts:
##   1. The REAL writer (`lockedDepsForWorkspace` over a real manifest
##      workspace, serialized by `serializeLockedDependencies`) emits a
##      `reprobuild.solved-graph-lock.v3` document with NO `path` key, the root
##      entry marked `self = "true"`, and the sibling recorded by name +
##      coordinates + integrity.
##   2. Reading that lock back (`populateLockedDeps`, the committed-lock
##      source every consumer goes through) resolves the sibling to its real
##      checkout BY NAME — here through the workspace manifest, which declares
##      it at `libs/lib-b`, a layout the one-level sibling default would miss.
##   3. A v2 lock carrying STALE paths (`../dev/<name>`) is read without error
##      and every recorded path is discarded: a sibling resolves to where it is
##      actually checked out — the manifest location, the develop-override
##      `local_path`, or the `../<name>` default — and a refresh RE-OBSERVES a
##      sibling found there instead of carrying a stale pin forward verbatim.
##      Re-serializing the v2 lock yields v3 with no path.
##   4. Through the real `repro` binary: a root lock whose v2 entry for a repo
##      records a stale path but the SAME revision as that repo's own lock is
##      NOT reported as a disagreement — only identity (the revision) is
##      compared — and the repo resolves at its real checkout, `at-lock`.
##
## Falsifiability (observed against `b21c844aa0`, the sources without the
## fix, with `build/bin/repro` dispatching to `build/bin/reprobuild` built
## from them; all three cases FAIL): (1)
## fails on the `path = "../libs/lib-b"` key and the v2 schema line; (3) fails
## because the stale `../dev/lib-b` comes back as the dependency's path, and a
## refresh carries the stale `lib-c` pin forward instead of re-observing it;
## (4) fails on the "disagree" notice naming `../dev/liba`.
##
## NO MOCKS. Every repository is a real git repository with a real bare
## origin on the real filesystem; the manifest is a real on-disk manifest the
## production resolver reads; the writer, reader and CLI are the production
## ones. Nothing touches $HOME or the network.
##
## Skip rule: `git` missing on PATH. Case (4) requires `build/bin/repro`.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_cli_support
import repro_lock
import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check`: this runs outside a `test` body as well, where
  ## `check` cannot fail the test.
  let res = runCmd(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configureIdentity(gitBin, work: string) =
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"Lock Tester\"")

proc seedPublished(gitBin, scratch, work, name: string): string =
  ## A bare origin plus a checkout of it at `work` with one published commit.
  ## Returns the origin path. The commit body carries `work`, so two seeds made
  ## in the same second still have different shas.
  # The origin's leaf is the repository name the writer records for a checkout
  # (`repositoryNameFromUrl`), so it is spelled exactly `<name>.git`.
  let origin = scratch / "origins" / (name & ".git")
  createDir(scratch / "origins")
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  createDir(parentDir(work))
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " & q(work))
  configureIdentity(gitBin, work)
  writeFile(work / "README.md", name & " fixture\n" & work & "\n")
  writeFile(work / ".gitignore", ".repro/\nrepro.lock\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin main")
  origin

proc headOf(gitBin, work: string): string =
  requireGit(q(gitBin) & " -C " & q(work) & " rev-parse HEAD").strip()

proc advance(gitBin, work: string): string =
  ## One more published commit on `work`; returns the new HEAD.
  writeFile(work / "later.txt", "later\n" & work & "\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add later.txt")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m later")
  discard requireGit(q(gitBin) & " -C " & q(work) & " push origin main")
  headOf(gitBin, work)

proc fragment(name, path: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & path & "\"\n" &
    "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, d in depends:
      if i > 0: result.add(", ")
      result.add("\"" & d & "\"")
    result.add("]\n")

proc projectToml(project: string; origins: seq[(string, string)]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & project & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, origin) in origins:
    result.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(origin) & "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in origins:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc v2Dep(name, path, url, sha: string): string =
  ## One v2 `deps` record exactly as the pre-v3 writer spelled it — `path`
  ## included, which is the field under test.
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", tags = \"\" }"

proc v2Lock(deps: seq[string]): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\nplatform = \"x86_64-linux\"\noptimal = true\n" &
  "inputs_digest = \"no-materialization-path\"\n" &
  "variants = []\npackages = []\n" &
  "deps = [" & deps.join(", ") & "]\n"

const v3Schema = "schema = \"reprobuild.solved-graph-lock.v3\""
  ## Spelled literally rather than through `SolvedGraphLockSchemaV3`, so this
  ## file compiles — and fails on its assertions — against a tree that predates
  ## the v3 schema.

proc depNamed(ld: LockedDependencies; name: string): LockedDep =
  for d in ld.deps:
    if d.name == name: return d
  LockedDep(name: "")

proc entryText(body, name: string): string =
  ## The inline-table text of the `deps` record named `name`, or "".
  # After `deps = [`: a `packages` entry starts with the same prefix.
  let at = body.find("{ name = \"" & name & "\"", max(0, body.find("deps = [")))
  if at < 0: return ""
  let close = body.find('}', at)
  if close < 0: return ""
  body[at .. close]

suite "the committed lock records no materialization path":

  test "the real writer emits v3 records with no path, read back by name":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let scratch = createTempDir("repro-lock-no-path-", "")
      defer: removeDir(scratch)
      # A manifest workspace whose sibling is NOT at the one-level default:
      # `lib-b` is declared at `libs/lib-b`. Only the manifest can say so.
      let ws = scratch / "workspace"
      createDir(ws)
      let app = ws / "app"
      let libB = ws / "libs" / "lib-b"
      let appOrigin = seedPublished(gitBin, scratch, app, "app")
      let libBOrigin = seedPublished(gitBin, scratch, libB, "lib-b")
      createDir(ws / "projects")
      createDir(ws / "repos")
      writeFile(ws / "projects" / "app.toml", projectToml("app",
        @[("app", appOrigin), ("lib-b", libBOrigin)]))
      writeFile(ws / "repos" / "app.toml", fragment("app", "app", @["lib-b"]))
      writeFile(ws / "repos" / "lib-b.toml",
        fragment("lib-b", "libs/lib-b", @[]))
      writeWorkspaceBranch(ws, project = "app", branch = "main")
      let libBHead = headOf(gitBin, libB)

      # ---- (1) the real writer records identity only. --------------------
      let deps = lockedDepsForWorkspace(app)
      let body = serializeLockedDependencies(LockedDependencies(deps: deps))
      checkpoint(body)
      check v3Schema in body
      check "solved-graph-lock.v2" notin body
      check "path =" notin body
      check "libs/lib-b" notin body
      check body.count("self = \"true\"") == 1
      check "self = \"true\"" in entryText(body, "app")
      let libBText = entryText(body, "lib-b")
      check libBText.len > 0
      check ("revision = \"" & libBHead & "\"") in libBText
      check ("integrity = \"git-sha1:" & libBHead & "\"") in libBText
      check "self" notin libBText

      # ---- (2) read back: the sibling resolves to its checkout BY NAME. --
      writeFile(app / "repro.lock", body)
      let readBack = populateLockedDeps(
        LockSource(kind: lskCommittedLock, workspaceRoot: app))
      let rootDep = depNamed(readBack, "app")
      check rootDep.name == "app"
      check rootDep.path == "."   # the self entry is held at its own directory
      let libBDep = depNamed(readBack, "lib-b")
      check libBDep.name == "lib-b"
      check libBDep.coordinates.revision == libBHead
      check libBDep.path == "../libs/lib-b"
      check dirExists(app / libBDep.path / ".git")

      # ---- (3a) a v2 lock with a STALE path: the path is not believed. ---
      writeFile(app / "repro.lock", v2Lock(@[
        v2Dep("app", ".", fileUrl(appOrigin), headOf(gitBin, app)),
        v2Dep("lib-b", "../dev/lib-b", fileUrl(libBOrigin), libBHead)]))
      let stale = populateLockedDeps(
        LockSource(kind: lskCommittedLock, workspaceRoot: app))
      check depNamed(stale, "app").path == "."
      check depNamed(stale, "lib-b").path == "../libs/lib-b"
      check depNamed(stale, "lib-b").coordinates.revision == libBHead
      # Re-serialized, the v2 document becomes a v3 one with no path at all.
      let rewritten = serializeLockedDependencies(stale)
      check v3Schema in rewritten
      check "path =" notin rewritten
      check "../dev" notin rewritten

  test "outside a workspace a stale v2 path yields to the override and the default":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let scratch = createTempDir("repro-lock-no-path-standalone-", "")
      defer: removeDir(scratch)
      # No workspace at all: `app` with `lib-c` beside it (the one-level
      # default) and `lib-d` somewhere a develop override declares.
      let top = scratch / "standalone"
      let app = top / "app"
      let libC = top / "lib-c"
      let libD = top / "elsewhere" / "lib-d"
      let appOrigin = seedPublished(gitBin, scratch, app, "app")
      let libCOrigin = seedPublished(gitBin, scratch, libC, "lib-c")
      let libDOrigin = seedPublished(gitBin, scratch, libD, "lib-d")
      let libCPinned = headOf(gitBin, libC)
      let libCHead = advance(gitBin, libC)
      check libCPinned != libCHead
      let libDHead = headOf(gitBin, libD)
      createDir(app / ".repro")
      writeFile(app / ".repro" / "develop-overrides.toml",
        "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
        "[[override]]\n" &
        "package = \"lib-d\"\n" &
        "local_path = \"../elsewhere/lib-d\"\n" &
        "state = \"editable\"\n" &
        "created_at = \"2026-10-18T00:00:00Z\"\n")
      # Both siblings are recorded at directories that do not exist.
      writeFile(app / "repro.lock", v2Lock(@[
        v2Dep("app", ".", fileUrl(appOrigin), headOf(gitBin, app)),
        v2Dep("lib-c", "../dev/lib-c", fileUrl(libCOrigin), libCPinned),
        v2Dep("lib-d", "../dev/lib-d", fileUrl(libDOrigin), libDHead)]))
      check not dirExists(top / "dev")

      # ---- (3b) the reader derives each location locally. ----------------
      let ld = populateLockedDeps(
        LockSource(kind: lskCommittedLock, workspaceRoot: app))
      check depNamed(ld, "lib-c").path == "../lib-c"
      check depNamed(ld, "lib-d").path == "../elsewhere/lib-d"
      check dirExists(app / depNamed(ld, "lib-d").path / ".git")

      # ---- (3c) a refresh re-observes the sibling where it really is. ----
      # With the recorded path believed, `../dev/lib-c` is not a checkout and
      # the stale pin is carried forward verbatim; derived by name, the
      # checkout at `../lib-c` is found and its moved HEAD is recorded.
      let refreshed = lockedDepsForWorkspace(app)
      var libCRefreshed = LockedDep(name: "")
      for d in refreshed:
        if d.name == "lib-c": libCRefreshed = d
      check libCRefreshed.name == "lib-c"
      check libCRefreshed.coordinates.revision == libCHead
      let body = serializeLockedDependencies(LockedDependencies(deps: refreshed))
      checkpoint(body)
      check "path =" notin body
      check "../dev" notin body

  test "a stale root-lock path is not reported as a disagreement":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let reproBin = reproBinary()
      let scratch = createTempDir("repro-lock-no-path-two-locks-", "")
      defer: removeDir(scratch)
      let ws = scratch / "workspace"
      createDir(ws)
      let liba = ws / "liba"
      let libaOrigin = seedPublished(gitBin, scratch, liba, "liba")
      let libaSha = headOf(gitBin, liba)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "ws.toml",
        projectToml("ws", @[("liba", libaOrigin)]))
      writeFile(manifestsRoot / "repos" / "liba.toml",
        fragment("liba", "liba", @[]))
      writeWorkspaceBranch(ws, project = "ws", branch = "main")
      # The ROOT lock records `liba` at a directory that never existed — the
      # measured `../dev/reprobuild-latest` shape — at the SAME revision the
      # repo's own lock publishes. The two agree on identity.
      writeFile(ws / "repro.lock", v2Lock(@[
        v2Dep("liba", "../dev/liba", fileUrl(libaOrigin), libaSha)]))
      writeFile(liba / "repro.lock", v2Lock(@[
        v2Dep("liba", ".", fileUrl(libaOrigin), libaSha)]))

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (4) no disagreement on a path; the real checkout resolves. -----
      let listed = runCmd(q(reproBin) &
        " develop --list --json --tool-provisioning=path --workspace-root=" &
        q(ws))
      checkpoint(listed.output)
      check listed.code == 0
      check "disagree" notin listed.output
      check "../dev/liba" notin listed.output
      var report: JsonNode = nil
      try:
        report = parseJson(listed.output)
      except CatchableError as err:
        checkpoint("unparseable --json output: " & err.msg)
      check not report.isNil
      if report != nil:
        check report["errors"].len == 0
        var found = false
        for r in report["repos"]:
          if r["name"].getStr() == "liba":
            found = true
            check r["revision"].getStr() == libaSha
            check r["path"].getStr() == os.normalizedPath(liba)
            check r["state"].getStr() == "at-lock"
        check found
