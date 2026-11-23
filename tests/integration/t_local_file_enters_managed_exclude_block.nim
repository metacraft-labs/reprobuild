## The local settings file is ignored per clone — and stops being ignored,
## and is reported, once the repository tracks it.
##
## Workspace-Settings-Files.md §4 and Workspace-Sibling-Ignore-Set.md: the
## managed block in the workspace root's `.git/info/exclude` lists
## `/repro-workspace.local.toml` under the block's tracked-probe rule (only a
## path git does not track is listed), never the tracked `.gitignore`; and
## `repro health` reports a TRACKED local settings file as a defect whose
## remedy is `git rm --cached`.
##
## The sequence, on a real git repository and through the real binary:
##
##   1. a workspace root that has never created the file: the regenerated
##      block lists `/repro-workspace.local.toml` (no trailing slash: a file),
##      next to a sibling checkout's entry; the tracked `.gitignore` does not
##      name it;
##   2. the file is then created: `git check-ignore` says the block ignores
##      it, and `git status --porcelain` does not show it;
##      `repro health --json` has no failing `local-settings-file` row;
##   3. the file is committed by mistake (`git add -f`): the next
##      regeneration drops the entry from the block, and `repro health`
##      reports a failing `local-settings-file` row whose remedy is
##      `git … rm --cached repro-workspace.local.toml`;
##   4. after that remedy (`git rm --cached` + commit) the entry is back and
##      the row is gone.
##
## No mocks: a real repository in a temporary directory, the real
## `refreshWorkspaceSiblingIgnores` every workspace verb calls, and the real
## `repro` for the health legs. Skip rule: only when `git` is not on PATH.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import sibling_ignores

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc git(gitBin, root: string; args: string): tuple[output: string; code: int] =
  let res = execCmdEx(q(gitBin) & " -C " & q(root) & " " & args)
  (output: res.output, code: res.exitCode)

proc requireGit(gitBin, root, args: string) =
  let res = git(gitBin, root, args)
  if res.code != 0:
    checkpoint("git " & args & " failed:\n" & res.output)
    quit 1

proc managedBlock(root: string): seq[string] =
  ## The lines between the managed block's markers in `.git/info/exclude`.
  let path = root / ".git" / "info" / "exclude"
  if not fileExists(path):
    return
  var inside = false
  for line in readFile(path).splitLines():
    if line == SiblingIgnoreBeginMarker:
      inside = true
    elif line == SiblingIgnoreEndMarker:
      inside = false
    elif inside and not line.startsWith("#"):
      result.add(line)

proc localSettingsRows(root: string): seq[JsonNode] =
  ## The `local-settings-file` rows of `repro health --json`.
  let health = runRepro(["health", "--json", "--offline",
    "--workspace-root=" & root])
  checkpoint("health --json exit=" & $health.code & "\nstdout: " &
    health.stdout & "\nstderr: " & health.stderr)
  let doc = parseJson(health.stdout)
  for row in doc["checks"]:
    if row["name"].getStr() == "local-settings-file":
      result.add(row)

suite "the local settings file enters the managed exclude block":

  test "t_local_file_enters_managed_exclude_block":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the workspace root is a real repository")
    else:
      let scratch = createTempDir("repro-local-exclude-", "")
      defer: removeDir(scratch)
      let root = scratch / "ws"
      createDir(root / "projects")
      writeFile(root / "projects" / "demo.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\n" &
        "name = \"demo\"\n")
      writeFile(root / ".gitignore", ".repro/\nworkspace-projects.md\n")
      requireGit(gitBin, root, "init -q -b main")
      requireGit(gitBin, root, "config user.email tester@example.invalid")
      requireGit(gitBin, root, "config user.name Tester")
      requireGit(gitBin, root, "add -A")
      requireGit(gitBin, root, "commit -q -m fixture")
      createDir(root / "sibling")
      writeFile(root / "sibling" / "file.txt", "a sibling checkout\n")
      let localFile = root / "repro-workspace.local.toml"
      const entry = "/repro-workspace.local.toml"

      # Leg 1 — never created: listed anyway, and only in the per-clone block.
      let first = refreshWorkspaceSiblingIgnores(gitBin, root)
      checkpoint("refresh: " & first.diagnostic)
      require first.ok
      let firstBlock = managedBlock(root)
      checkpoint("block: " & firstBlock.join(" | "))
      # PRIMARY: the local settings file is in the managed block.
      check entry in firstBlock
      check entry & "/" notin firstBlock
      check "/sibling/" in firstBlock
      check "repro-workspace.local.toml" notin readFile(root / ".gitignore")

      # Leg 2 — created: git ignores it, and health does not complain.
      writeFile(localFile,
        "schema = \"reprobuild.workspace.settings-local.v1\"\n")
      check git(gitBin, root, "check-ignore -q repro-workspace.local.toml").code == 0
      check "repro-workspace.local.toml" notin
        git(gitBin, root, "status --porcelain").output
      let quiet = localSettingsRows(root)
      for row in quiet:
        check row["status"].getStr() == "ok"

      # Leg 3 — committed by mistake: the block drops it, health reports it.
      requireGit(gitBin, root, "add -f repro-workspace.local.toml")
      requireGit(gitBin, root, "commit -q -m oops")
      let second = refreshWorkspaceSiblingIgnores(gitBin, root)
      require second.ok
      let secondBlock = managedBlock(root)
      checkpoint("block after tracking: " & secondBlock.join(" | "))
      check entry notin secondBlock
      check "/sibling/" in secondBlock
      let rows = localSettingsRows(root)
      check rows.len == 1
      if rows.len == 1:
        check rows[0]["status"].getStr() == "fail"
        check "tracked" in rows[0]["detail"].getStr()
        check "rm --cached repro-workspace.local.toml" in
          rows[0]["remedy"].getStr()
        check rows[0]["fixable"].getBool() == false
      let text = runRepro(["health", "--offline", "--workspace-root=" & root])
      check "local-settings-file" in text.stdout
      check "rm --cached repro-workspace.local.toml" in text.stdout

      # Leg 4 — the remedy: untracked again, listed again, no failing row.
      requireGit(gitBin, root, "rm -q --cached repro-workspace.local.toml")
      requireGit(gitBin, root, "commit -q -m untrack")
      let third = refreshWorkspaceSiblingIgnores(gitBin, root)
      require third.ok
      check entry in managedBlock(root)
      check fileExists(localFile)
      for row in localSettingsRows(root):
        check row["status"].getStr() == "ok"
