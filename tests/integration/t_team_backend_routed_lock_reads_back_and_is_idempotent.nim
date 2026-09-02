## Regression — a workspace that adopts its ``.repro/manifests`` checkout as the
## TEAM lock backend (an explicit ``[locking]`` route → git-checkout at
## ``.repro/manifests``, exactly what ``repro locking adopt-manifest`` writes)
## must be able to READ BACK the per-repo lock records it wrote, and re-locking
## an unchanged workspace must stay a clean no-op.
##
## This is the migration happy path (``repo-workspaces`` committed workspace
## locks to the manifest repo; the reprobuild equivalent is the team route over
## the same checkout). Three defects on this path are pinned here:
##
##   * **#2 (the crash) — routed records are readable.** ``repro workspace lock``
##     writes each repo's record as a schema-less ``[[repo]]`` git-checkout
##     backend body under ``locks/<project>/<repo>/<sha>.toml``. The "latest
##     lock" reader (``latestLockShasViaGit`` → consumed by ``status`` / ``check``
##     / ``sync``) used the STRICT ``reprobuild.workspace.lock.v1`` parser, which
##     rejects that body (``double bracket not allowed``) — so ``status`` CRASHED
##     non-zero after ``adopt-manifest``. The fix merges every candidate record
##     tolerantly (``shasFromBody``). Asserted: ``status --json`` exits 0 and
##     reports every repo ``at-lock``.
##   * **#1 — the lock summary line has no blank path.** The renderer printed
##     ``workspace lock: wrote  (trigger=…)`` with an empty path whenever no
##     lock file path was set. Asserted: the summary never contains ``wrote  (``.
##     (HL-2 §6 Decision 1 later restored the trigger-keyed PARTITION write on
##     this path — the team backend's lock document, holding only the repos
##     routed to it — so the summary now names a real path. The blank-path
##     assertion still holds and still guards the routed-but-unowned shape,
##     where the manifest backend owns no repo and no path exists to print.)
##   * **#4 — idempotent re-lock.** Re-writing an identical record stages no
##     change, so the backend's ``git commit`` exited non-zero ("nothing to
##     commit") and was surfaced as ``failed to record … via git-checkout
##     backend`` — which under the tier-isolation policy can escalate to a push
##     refusal. Asserted: a second ``workspace lock`` exits 0 with no
##     ``failed to record``.
##
## Falsifiability: pointing ``reproBinary`` at a pre-fix build flips (#2) —
## ``status --json`` exits non-zero with ``double bracket not allowed`` — and
## (#4) — the second lock prints ``failed to record``. Confirmed by running this
## test against the unpatched ``repro 0.1.0`` (both assertions fail there).
##
## Hermetic: fresh tempdir; the other config layers are silenced. Skip: ``git``
## missing or ``./build/bin/repro`` absent.

import std/[json, os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Routed Lock Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"Routed Lock Tester\"")

proc projectToml(coreUrl, libUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/lib.toml\",\n]\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

suite "regression — manifest team backend routed lock reads back + idempotent":

  test "t_team_backend_routed_lock_reads_back_and_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = createTempDir("routed-lock-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let libOrigin = scratch / "origin-lib.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let libSha = seedGitOrigin(gitBin, libOrigin, scratch / "seed-lib")

      let ws = scratch / "workspace"
      createDir(ws)
      let manifestsRoot = ws / ".repro" / "manifests"
      createDir(manifestsRoot / "projects")
      createDir(manifestsRoot / "repos")
      writeFile(manifestsRoot / "projects" / "mix.toml",
        projectToml(fileUrl(coreOrigin), fileUrl(libOrigin)))
      writeFile(manifestsRoot / "repos" / "core.toml",
        repoFragment("core", "core-origin"))
      writeFile(manifestsRoot / "repos" / "lib.toml",
        repoFragment("lib", "lib-origin"))

      # The team backend is the manifest checkout itself (adopt-manifest's
      # ``path = ".repro/manifests"``). It must be a real git repo so the
      # git-checkout backend can commit each record.
      initGitRepo(gitBin, manifestsRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
        " commit -m manifests")

      cloneInto(gitBin, coreOrigin, ws / "core")
      cloneInto(gitBin, libOrigin, ws / "lib")
      writeWorkspaceBranch(ws, project = "mix", branch = "main")

      # ``[locking]`` route mapping BOTH repos' team tier to the manifest
      # checkout — byte-for-byte the route ``repro locking adopt-manifest``
      # scaffolds.
      writeFile(ws / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n\n" &
        "[locking]\n" &
        "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
        "path = \".repro/manifests\", repos = [\"core\", \"lib\"] }]\n")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- lock: per-repo records land in the manifest checkout ----------
      let lock1 = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lock1.code != 0:
        checkpoint("workspace lock output: " & lock1.output)
      check lock1.code == 0
      # #1 — no blank-path summary line on the routed path.
      check not lock1.output.contains("wrote  (")
      # HL-2 §6 Decision 1 — the team backend's record is the trigger-keyed
      # PARTITION LOCK (trigger = ``core``, the project's first declared repo),
      # a ``reprobuild.workspace.lock.v1`` document holding every repo routed to
      # this backend. Non-trigger repos are recorded BY that document, not by a
      # minimal per-repo body squatting on their own future coordinate; see
      # ``t_workspace_lock_partition_resolves_a_sibling_for_ci`` for why that
      # distinction is load-bearing for CI.
      let partitionPath =
        manifestsRoot / "locks" / "mix" / "core" / (coreSha & ".toml")
      check fileExists(partitionPath)
      let partition = readFile(partitionPath)
      check partition.contains("schema = \"reprobuild.workspace.lock.v1\"")
      check partition.contains("revision = \"" & libSha & "\"")
      check not fileExists(manifestsRoot / "locks" / "mix" / "lib" /
        (libSha & ".toml"))

      # ---- #2 (the crash): status reads the routed records back ----------
      let status = run(reproBinary & " workspace status" &
        " --workspace-root=" & q(ws) & " --json")
      if status.code != 0:
        checkpoint("status output: " & status.output)
      check status.code == 0
      check not status.output.contains("double bracket not allowed")
      let report = parseJson(status.output)
      # Both repos resolve to their locked HEAD → at-lock, none unrecorded.
      check report["summary"]["atLock"].getInt() == 2
      check report["summary"]["noLockRecorded"].getInt() == 0

      # ---- #4 (idempotency): re-locking the unchanged workspace is clean -
      let lock2 = run(reproBinary & " workspace lock --workspace-root=" & q(ws))
      if lock2.code != 0:
        checkpoint("second workspace lock output: " & lock2.output)
      check lock2.code == 0
      check not lock2.output.contains("failed to record")
