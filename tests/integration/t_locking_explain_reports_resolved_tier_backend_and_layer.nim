## Unified-Locking-And-Hooks HL-1 (§4) — ``repro locking explain --json``
## attributes each repo to its resolved (tier, backend, DECLARING LAYER).
##
## The introspection verb a user runs to debug a layered config without
## guessing. It composes the configuration layers (built-in → system →
## dotfiles → parent-workspace → VCS-private) and reports, per repo: the
## resolved tier, the backend, AND which LAYER declared it (with the declaring
## file's path). This test drives the built ``./build/bin/repro`` against a
## committed-lock-only workspace whose single repo is claimed by a named TEAM
## route in the parent-workspace layer, and asserts the JSON surface:
##
##   1. Valid JSON with the ``reprobuild.locking-explain.v1`` schema.
##   2. The repo is attributed to the TEAM tier (from the declaring layer, not
##      its per-repo public field) with the ``git-checkout`` backend.
##   3. The declaring LAYER is ``parent-workspace-repo`` and the ``source``
##      names the ``.repro-workspace.toml`` that declared it.
##
## Falsifiable: if the verb omitted the layer attribution, assertion (3) has no
## ``layer`` / ``source`` fields to read and the object-key lookups raise /
## fail. Confirmed by deleting the ``"layer"``/``"source"`` keys from the JSON
## emitter: (3) then trips.
##
## Hermetic: a fresh tempdir git repo with a committed lock + a
## ``.repro-workspace.toml``; env overrides silence the system/dotfiles/
## VCS-private layers. Skip rule: ``git`` missing or ``./build/bin/repro``
## absent (the suite does NOT build the binary itself).

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

suite "HL-1 — repro locking explain reports tier + backend + layer":

  test "t_locking_explain_reports_resolved_tier_backend_and_layer":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "hl1-explain-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let repo = scratch / "work"
      check git(gitBin, "", "init -b main " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0

      # ---- establish the committed-lock workspace marker -----------------
      writeFile(repo / "repro.solver", solverInputs)
      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0
      check fileExists(repo / "repro.lock")

      # ---- a parent-workspace layer (.repro-workspace.toml) that NAMES the
      #      root repo (path ".") at the TEAM tier -------------------------
      # A team backend the git-checkout route points at (a real manifest repo).
      let teamManifest = repo / "manifests-team"
      check git(gitBin, "", "init -b main " & q(teamManifest)).code == 0
      check git(gitBin, teamManifest,
        "config user.email t@example.invalid").code == 0
      check git(gitBin, teamManifest, "config user.name Tester").code == 0
      writeFile(teamManifest / "seed.txt", "seed\n")
      check git(gitBin, teamManifest, "add seed.txt").code == 0
      check git(gitBin, teamManifest, "commit -m seed").code == 0

      writeFile(repo / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \"manifests-team\", repos = [\".\"] }]\n")

      check git(gitBin, repo, "add -A").code == 0
      check git(gitBin, repo, "commit -m lock").code == 0

      # ---- silence the other layers so only parent-workspace speaks ------
      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) drive `repro locking explain --json` ----------------------
      let res = run(reproBinary & " locking explain --workspace-root=" &
        q(repo) & " --json 2>/dev/null")
      check res.code == 0

      var parsed: JsonNode
      var parseOk = true
      try:
        parsed = parseJson(res.output.strip())
      except JsonParsingError:
        parseOk = false
      check parseOk

      check parsed["schema"].getStr() == "reprobuild.locking-explain.v1"
      check parsed["repos"].len >= 1

      # Find the root repo's attribution entry (path ".").
      var found: JsonNode = nil
      for r in parsed["repos"]:
        if r["path"].getStr() == ".":
          found = r
      check found != nil
      if found != nil:
        # (2) tier + backend from the declaring layer, not the per-repo field.
        check found["tier"].getStr() == "team"
        check found["backend"].getStr() == "git-checkout"
        # (3) the DECLARING LAYER + its source are attributed.
        check found["layer"].getStr() == "parent-workspace-repo"
        check found["source"].getStr().contains(".repro-workspace.toml")
