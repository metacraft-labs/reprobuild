## RA-22 — `repro remove <repo>` reachability garbage collection +
## dirty-checkout guard.
##
## Black-box: drives the compiled ``repro`` binary against a hermetic
## workspace via ``execCmdEx`` (non-TTY by nature). Local bare git origins
## stand in for the develop-mode siblings.
##
## Topology (RA-21 ``depends`` edges):
##
##     root-r ──▶ libb ──┬─▶ libs        root-t ──▶ libs
##                       └─▶ libu
##
## ``libs`` is SHARED: reached from ``libb`` AND directly from the surviving
## root ``root-t``. ``libu`` is TRANSITIVE-ONLY: reached ONLY through ``libb``.
## Removing ``libb`` must:
##   - GC ``libb``'s checkout (the removed target), and
##   - GC ``libu`` (transitive-only — nothing else reaches it once ``libb`` is
##     gone), but
##   - KEEP ``libs`` (still reached from the surviving ``root-t``).
## The decision is reachability over the ``depends`` graph from the SURVIVING
## roots, not name matching: ``libu`` is a project membership too, so a GC
## that seeds every membership as its own root would wrongly keep it. This
## case is what makes the test falsifiable against the seeding bug.
##
## Sub-cases (each its own ``test_ra22_*`` block):
##   1. ``repro remove libb`` GCs libb + libu; libs + the roots STAY.
##   2. A DIRTY GC target, non-TTY, no ``--force`` → REFUSE; nothing deleted
##      (RA-9 destructive-command safety).
##   3. The same dirty target WITH ``--force`` → removed.
##
## Skip rule: ``git`` missing on PATH (same convention as the RA suites).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string; branch = "main") =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA22 Tester\"")
  writeFile(workPath / "README.md", "RA22 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))

proc fragmentToml(name, remoteName: string; depends: seq[string]): string =
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remoteName & "\"\n" &
    "revision = \"main\"\n"
  if depends.len > 0:
    var quoted: seq[string]
    for d in depends: quoted.add("\"" & d & "\"")
    result.add("depends = [" & quoted.join(", ") & "]\n")

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    projectFile: string

const repoNames = ["root-r", "root-t", "libb", "libs", "libu"]

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra22-remove-" & slug & "-", "")
  result.reproBin = reproBinary()

  var origins: array[repoNames.len, string]
  for i, n in repoNames:
    origins[i] = result.scratch / ("origin-" & n & ".git")
    seedGitOrigin(gitBin, origins[i], result.scratch / ("seed-" & n))

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")

  # Project manifest: all four repos included, each with a remote.
  var pt =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"demo\"\ndefault_revision = \"main\"\ntrunk = \"main\"\n\n"
  for i, n in repoNames:
    pt.add("[[remote]]\nname = \"" & n & "-origin\"\nfetch = \"" &
      fileUrl(origins[i]) & "\"\n\n")
  pt.add("includes = [\n")
  for n in repoNames:
    pt.add("  \"repos/" & n & ".toml\",\n")
  pt.add("]\n")
  result.projectFile = manifestsRoot / "projects" / "demo.toml"
  writeFile(result.projectFile, pt)

  # Fragments with the depends edges: root-r->libb, libb->{libs, libu},
  # root-t->libs. ``libu`` is transitive-only (reached only via libb);
  # ``libs`` is shared (reached via libb AND directly via root-t).
  writeFile(manifestsRoot / "repos" / "root-r.toml",
    fragmentToml("root-r", "root-r-origin", @["libb"]))
  writeFile(manifestsRoot / "repos" / "root-t.toml",
    fragmentToml("root-t", "root-t-origin", @["libs"]))
  writeFile(manifestsRoot / "repos" / "libb.toml",
    fragmentToml("libb", "libb-origin", @["libs", "libu"]))
  writeFile(manifestsRoot / "repos" / "libs.toml",
    fragmentToml("libs", "libs-origin", @[]))
  writeFile(manifestsRoot / "repos" / "libu.toml",
    fragmentToml("libu", "libu-origin", @[]))

  # Clone every repo into the workspace as a present sibling.
  for i, n in repoNames:
    cloneInto(gitBin, origins[i], workspaceRoot / n)

  writeFile(workspaceRoot / ".repo" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nbranch = \"main\"\n")
  result.workspaceRoot = workspaceRoot

proc invokeRemove(fx: Fixture; extra: seq[string]): tuple[code: int; output: string] =
  var parts = @[q(fx.reproBin), "remove"]
  for e in extra: parts.add(q(e))
  parts.add("--workspace-root=" & q(fx.workspaceRoot))
  runCmd(parts.join(" "))

proc makeDirty(repoPath: string) =
  writeFile(repoPath / "uncommitted.txt", "local work that must not vanish\n")

suite "RA-22 — repro remove reachability GC and dirty guard":

  test "test_ra22_remove_gcs_unique_checkout_keeps_shared":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "gc")
      defer: removeDir(fx.scratch)

      # All siblings present before removal.
      for n in repoNames:
        check dirExists(fx.workspaceRoot / n)

      # Remove libb (clean): GC libb's checkout AND libu (transitive-only),
      # but libs STAYS (root-t still reaches it), and the surviving roots
      # stay.
      let res = invokeRemove(fx, @["libb", "--json"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      # libb's checkout is gone.
      check not dirExists(fx.workspaceRoot / "libb")
      # libu is COLLECTED — transitive-only, nothing reaches it once libb is
      # gone. This is what fails if the GC seeds every membership as its own
      # root (the seeding bug).
      check not dirExists(fx.workspaceRoot / "libu")
      # libs SURVIVES — still reached from the surviving root-t.
      check dirExists(fx.workspaceRoot / "libs")
      # The two roots are untouched.
      check dirExists(fx.workspaceRoot / "root-r")
      check dirExists(fx.workspaceRoot / "root-t")
      # The report's removed set is exactly {libb, libu} (order-independent).
      let braceIdx = res.output.find('{')
      check braceIdx >= 0
      let rep = parseJson(res.output[braceIdx .. ^1])
      var removed: seq[string]
      for r in rep["repos"]:
        if r["effect"].getStr() == "removed":
          removed.add(r["name"].getStr())
      check removed.len == 2
      check "libb" in removed
      check "libu" in removed
      check "libs" notin removed
      # libb's include was dropped; libs's include remains.
      check not readFile(fx.projectFile).contains("repos/libb.toml")
      check readFile(fx.projectFile).contains("repos/libs.toml")

  test "test_ra22_remove_dirty_gc_target_non_tty_without_force_refuses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty-refuse")
      defer: removeDir(fx.scratch)

      let dirtyRepo = fx.workspaceRoot / "libb"
      makeDirty(dirtyRepo)

      # Non-TTY (execCmdEx), no --force, dirty GC target → REFUSE.
      let res = invokeRemove(fx, @["libb"])
      check res.code == 2
      check res.output.contains("--force")
      # NOTHING discarded: the dirty tree, the dirty file, and the
      # declaration are all intact.
      check dirExists(dirtyRepo)
      check fileExists(dirtyRepo / "uncommitted.txt")
      check readFile(fx.projectFile).contains("repos/libb.toml")
      # libs and libu are also still present (no GC happened at all).
      check dirExists(fx.workspaceRoot / "libs")
      check dirExists(fx.workspaceRoot / "libu")

  test "test_ra22_remove_dirty_gc_target_with_force_removes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty-force")
      defer: removeDir(fx.scratch)

      let dirtyRepo = fx.workspaceRoot / "libb"
      makeDirty(dirtyRepo)

      # --force opts out of the prompt → the removal proceeds.
      let res = invokeRemove(fx, @["libb", "--force"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check not dirExists(dirtyRepo)
      check not readFile(fx.projectFile).contains("repos/libb.toml")
      # libu (clean, transitive-only) is GC'd alongside the forced libb.
      check not dirExists(fx.workspaceRoot / "libu")
      # libs survives the forced removal too.
      check dirExists(fx.workspaceRoot / "libs")
