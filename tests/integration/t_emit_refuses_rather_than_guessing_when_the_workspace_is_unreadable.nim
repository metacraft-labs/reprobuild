## NF-1 (Nix-Flake-Coexistence.md §5; Nix-Flake-Coexistence.milestones.org
## §NF-1) — **an empty override list and a failure MUST NOT look alike to
## `.envrc`**.
##
##   > `emit_refuses_rather_than_guessing_when_the_workspace_is_unreadable` —
##   > no silent empty output; an empty override list and a failure must not
##   > look alike to `.envrc`. Mutation: return empty on error ⇒ red.
##
## ## Why this is the sharpest test in the milestone
##
## The whole campaign exists because of a mechanism that produced nothing while
## claiming to work (§5: "the knob was **inert** … silently, for weeks"). The
## new verb's failure mode has exactly the same shape available to it: a
## workspace whose lock backend cannot be read has NO develop set, and an
## implementation that answered that with an empty argument line would hand
## `.envrc` a perfectly well-formed `use flake` with no overrides on it — which
## builds from the pins while the file says it builds from the siblings. That
## is not a new bug; it is the SAME bug, re-implemented inside the tool that
## was written to remove it.
##
## So the contract asserted here is that the two outcomes differ in a way a
## shell can branch on, and that the failing one carries nothing on stdout:
##
##   | outcome                         | exit | stdout      | stderr        |
##   |---------------------------------|------|-------------|---------------|
##   | overrides resolved              | 0    | the args    | a count       |
##   | the selection is legitimately   | 0    | empty       | says so       |
##   | empty                           |      |             |               |
##   | the workspace cannot be read    | 2    | **empty**   | why + remedy  |
##
## Empty stdout on failure is not decoration. `.envrc` splices this output
## into a `use flake` line; a diagnostic printed on stdout would be spliced in
## as a flake argument, and the resulting failure would name a nix parse error
## instead of an unreadable lock store. Which is why the refusal goes to stderr
## and the exit status carries the signal.
##
## ## The three ways the workspace can be unreadable, all covered
##
##   1. **The lock backend's medium exists and cannot be read.** A routed team
##      `committed-file` store at mode `000`, holding a real published record —
##      the DS-3 condition `t_develop_refuses_unreadable_backend_of_any_kind`
##      pins for `repro develop`, asserted here for the emitter, because a
##      refusal that only one verb honours is not a property of the workspace.
##   2. **The flake cannot be read.** The verb was asked to name a flake's
##      inputs; with no readable `flake.nix` it does not know what the input
##      names ARE, and every override it could emit would be a guess.
##   3. **The flake declares no inputs at all.** A parse that matched nothing
##      is indistinguishable from a flake with nothing to override — the
##      positive-assertion rule `scripts/check_dev_shell_env.sh` states for
##      its own scans ("a scan that matched nothing fails rather than passing
##      quietly").
##
## ## Asserts
##
##   1. unreadable lock store ⇒ exit 2, **stdout empty**, stderr names the
##      tier, the backend kind, its location and a runnable remedy;
##   2. control: with the bits restored the SAME workspace answers exit 0 with
##      a non-empty argument line, so (1) is about readability alone;
##   3. a legitimately empty selection answers exit 0 with empty stdout and
##      says so on stderr — and the exit codes of (1) and (3) DIFFER, which is
##      the whole contract: `.envrc` can tell them apart;
##   4. a missing `flake.nix` refuses with exit 2 and empty stdout;
##   5. an unreadable `flake.nix` refuses the same way — present-but-unreadable
##      must not degrade to "declares no inputs";
##   6. a flake with an empty `inputs` block refuses rather than answering
##      "nothing to override".
##
## ## Mutation (from the milestone): return empty on error ⇒ RED
##
## It fails (1) on the exit code and fails (3) on the code comparison, which is
## the assertion that says the two outcomes are distinguishable at all.
##
## Test-double policy: NO mocks, doubles or fakes. Real git origins and clones,
## a real routed `committed-file` lock store holding a real record published by
## the real `repro workspace lock`, real POSIX permission bits, the real
## `./build/bin/repro`.
##
## Hermetic: fresh tempdir; system and user configuration layers silenced,
## layer 5 supplied by the fixture. Permission bits are restored in `defer` so
## the tempdir stays removable. Skip (announced, never silent): `git` missing,
## `repro` unbuilt, or running as root — root reads a mode-000 directory
## whatever its bits say, so the fixture cannot express the condition and a
## pass would be a lie.

import std/[os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  from std/posix import Mode, chmod, geteuid

const reproBinary = "./build/bin/repro"

proc cannotModelUnreadablePaths(): bool =
  when defined(posix):
    geteuid() == 0
  else:
    true

proc setMode(path: string; mode: int): int =
  when defined(posix):
    int(chmod(path.cstring, Mode(mode)))
  else:
    -1

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    # `echo`, not `checkpoint`: a checkpoint is only flushed when a `check`
    # fails, and this path `quit`s instead — so a fixture command that failed
    # would take its own diagnostic with it and leave an empty suite header as
    # the only evidence.
    echo "fixture command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output
    quit 1
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"NF1 Refusal Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "flake.nix", "{ outputs = _: { }; }\n")
  writeFile(workPath / "seed.txt", extractFilename(workPath) & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

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

proc committedLock(url, sha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"nf1-refusal\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [{ name = \"core\", path = \"core\", coord_kind = \"vcs\"" &
  ", url = \"" & url & "\", ref = \"main\", revision = \"" & sha &
  "\", integrity = \"git-sha1:" & sha &
  "\", version = \"\", visibility = \"public\", participation = \"\"" &
  ", depends = \"\", groups = \"\" }]\n"

suite "NF-1: an unreadable workspace refuses; it never answers empty":

  test "t_emit_refuses_rather_than_guessing_when_the_workspace_is_unreadable":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary) or
        cannotModelUnreadablePaths():
      echo "SKIPPED (loudly): " &
        "t_emit_refuses_rather_than_guessing_when_the_workspace_is_unreadable " &
        "needs `git`, a built ./build/bin/repro, and a non-root euid " &
        "(root reads mode-000 paths regardless of their bits, so the " &
        "condition under test cannot be expressed); git=" &
        (if gitBin.len == 0: "MISSING" else: gitBin) & " repro=" &
        (if fileExists(reproBinary): "present" else: "UNBUILT") &
        " root=" & $cannotModelUnreadablePaths()
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("nf1-refusal-", "")

      let coreOrigin = scratch / "origin-core.git"
      let teamOrigin = scratch / "origin-team-lib.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      discard seedGitOrigin(gitBin, teamOrigin, scratch / "seed-team-lib")

      let ws = scratch / "ws"
      initGitRepo(gitBin, ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      let storeDir = ws / ".repro" / "lockstore-team"
      let app = ws / "app"
      defer:
        discard setMode(storeDir, 0o755)
        discard setMode(app / "flake.nix", 0o644)
        removeDir(scratch)

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

      for name in ["core", "team-lib"]:
        discard requireGit(q(gitBin) & " clone " &
          q("file://" & scratch / ("origin-" & name & ".git")) & " " &
          q(ws / name))
      writeFile(ws / ".repro" / "workspace.toml",
        "schema = \"reprobuild.workspace.local.v1\"\n\n" &
        "[workspace]\n" &
        "project = \"mix\"\n" &
        "branch = \"main\"\n")
      writeFile(ws / "repro.lock",
        committedLock("file://" & coreOrigin, coreSha))
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")

      createDir(ws / ".git" / "repro")
      writeFile(ws / ".git" / "repro" / "config.toml",
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"committed-file\", " &
        "path = \".repro/lockstore-team\", repos = [\"team-lib\"] }]\n")

      createDir(app)
      proc inputLine(name: string): string =
        "    " & name & ".url = " & '"' & "github:example/" & name & '"' & ";\n"
      writeFile(app / "flake.nix",
        "{\n  inputs = {\n" & inputLine("core-src") & inputLine("team-lib-src") &
        "  };\n\n  outputs = _: { };\n}\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")

      # Publish the team record while the store is still readable, so the ONLY
      # thing that changes below is readability — not the record's existence.
      let published = run(repro & " workspace lock --workspace-root=" & q(ws))
      if published.code != 0:
        checkpoint("workspace lock output: " & published.output)
      check published.code == 0
      check dirExists(storeDir)

      proc emit(flags: string; dir = app):
          tuple[code: int; outText, errText: string] =
        let outFile = scratch / "emit.out"
        let errFile = scratch / "emit.err"
        let res = run(repro & " flake override-args --tool-provisioning=path " &
          flags & " >" & q(outFile) & " 2>" & q(errFile), cwd = dir)
        (code: res.code, outText: readFile(outFile),
         errText: readFile(errFile))

      # ---- (1) the lock backend's medium cannot be read. ------------------
      check setMode(storeDir, 0o000) == 0
      let unreadable = emit("--all")
      check setMode(storeDir, 0o755) == 0
      if unreadable.code == 0:
        checkpoint("expected a refusal; stdout was: " & unreadable.outText &
          "\nstderr: " & unreadable.errText)
      check unreadable.code == 2
      # STDOUT EMPTY. `.envrc` splices stdout into `use flake`; a diagnostic
      # there would become a flake argument.
      check unreadable.outText.strip().len == 0
      # …and the refusal says which medium, where, and what to do.
      check "team" in unreadable.errText
      check "committed-file" in unreadable.errText
      check storeDir in unreadable.errText
      check "team-lib" in unreadable.errText
      check "chmod" in unreadable.errText
      # The verb must not have invented an answer out of the backends it COULD
      # read: `core` resolves perfectly well from the committed lock, and
      # emitting its override alone would be exactly the "narrowed set nobody
      # was told about" this rule forbids.
      check "core-src" notin unreadable.outText

      # ---- (2) control: readable again, the same workspace answers. -------
      let readable = emit("--all")
      if readable.code != 0:
        checkpoint("control stdout: " & readable.outText &
          "\nstderr: " & readable.errText)
      check readable.code == 0
      check "--override-input core-src path:" in readable.outText
      check "--override-input team-lib-src path:" in readable.outText

      # ---- (3) a legitimately EMPTY selection is not a failure. -----------
      # `--filter` is the one selector that may match nothing (CLI/develop.md
      # §"Membership axis"), so this is an empty answer that is CORRECT — and
      # it must be distinguishable from (1) by something `.envrc` can branch
      # on. That something is the exit status.
      let emptySelection = emit("--all --filter='no-such-repo-*'")
      if emptySelection.code != 0:
        checkpoint("empty-selection stdout: " & emptySelection.outText &
          "\nstderr: " & emptySelection.errText)
      check emptySelection.code == 0
      check emptySelection.outText.strip().len == 0
      # Not silent either: the run says it resolved nothing.
      check emptySelection.errText.strip().len > 0
      # THE CONTRACT, stated directly: the two empty-stdout outcomes differ.
      check emptySelection.code != unreadable.code

      # ---- (4) no flake to read its inputs from. --------------------------
      # Reached from inside the workspace so the lock set is fine and the
      # flake is the only thing missing.
      let noFlake = emit("--all", dir = ws)
      check noFlake.code == 2
      check noFlake.outText.strip().len == 0
      check "flake.nix" in noFlake.errText

      # ---- (5) a flake that exists and cannot be read. --------------------
      # "Unreadable includes degrading to silence": present-but-unreadable
      # must not come out as "this flake declares no inputs".
      check setMode(app / "flake.nix", 0o000) == 0
      let unreadableFlake = emit("--all")
      check setMode(app / "flake.nix", 0o644) == 0
      check unreadableFlake.code == 2
      check unreadableFlake.outText.strip().len == 0
      check "flake.nix" in unreadableFlake.errText

      # ---- (6) a flake whose inputs block is empty. -----------------------
      let hollow = scratch / "hollow"
      createDir(hollow)
      writeFile(hollow / "flake.nix", "{\n  inputs = { };\n\n  outputs = _: { };\n}\n")
      let hollowRes = emit("--all --flake=" & q(hollow))
      check hollowRes.code == 2
      check hollowRes.outText.strip().len == 0
      check "input" in hollowRes.errText
