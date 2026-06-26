## Workspace-Manifest-Optional MO-4 — a single workspace routes different
## repo-sets (keyed by visibility) to DISTINCT locking backends, and a
## workspace operation records each repo through its ASSIGNED backend.
##
## The config maps:  public → committed-file,  team → git-checkout,
## personal → external-CLI.  We resolve the per-repo backend assignment
## (``resolveRepoBackends``, reusing ``ResolvedRepo.visibility``) and run the
## MO-4 recording operation (``recordWorkspaceParticipation`` — the same proc
## the lock/gate path calls). We then assert each repo's record LANDED IN ITS
## OWN MEDIUM and in NO OTHER:
##   - the public repo's record is a ``.rec`` file under the committed-file
##     store dir (and absent from the team git-checkout + personal DB);
##   - the team repo's record is a committed ``locks/...`` file in the
##     git-checkout manifest repo (and absent from the other two mediums);
##   - the personal repo's record is a key in the external-CLI stub's DB
##     (and absent from the other two mediums).
##
## Falsifiable: the per-medium isolation assertions FAIL if the router sends
## every repo to one backend (then two of the three mediums hold nothing, and
## the cross-medium "absent from the others" checks trip). Confirmed by
## collapsing every route to committed-file — the team/personal medium reads
## then come back empty and the test fails.
##
## Default leg: a public-only workspace with NO ``[locking]`` config resolves
## every repo to the committed solved-graph lock (``committed-lock``) with
## ``store == nil`` — NO backend is constructed.
##
## Skip rule: ``git`` missing on PATH (the git-checkout backend needs it).

import std/[options, os, osproc, tables, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import repro_workspace_manifests
import git_tool

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc q(value: string): string = quoteShell(value)

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
    " config user.name \"MO-4 Tester\"")
  writeFile(path / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(path) & " commit -m seed")

proc writeStubCli(path: string) =
  ## External-CLI stub honoring ``ExternalCliContractSchemaV1`` (a ``$DB_DIR``
  ## KV store), identical to the MO-3 contract stub.
  writeFile(path, """#!/usr/bin/env bash
set -euo pipefail
db="${DB_DIR:?DB_DIR unset}"
op="$1"; key="$2"
safe=$(printf '%s' "$key" | tr '/' '_')
if [ "$op" = "put" ]; then
  json=$(cat)
  val=$(printf '%s' "$json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  printf '%s' "$val" > "$db/$safe"
  exit 0
elif [ "$op" = "get" ]; then
  if [ -f "$db/$safe" ]; then
    val=$(cat "$db/$safe")
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":true,"value":"%s"}' "$val"
  else
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":false}'
  fi
  exit 0
fi
echo "unknown op: $op" >&2
exit 1
""")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc mkRepo(name, path: string; v: WorkspaceVisibility): ResolvedRepo =
  ResolvedRepo(name: name, path: path, visibility: v)

suite "MO-4 — workspace routes repo-sets to distinct backends":

  test "t_workspace_routes_repo_sets_to_distinct_backends":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-mo4-route-", "")
      defer: removeDir(ws)

      # The git-checkout backend writes into a real manifest git repo.
      let teamManifest = ws / "manifests-team"
      initGitRepo(gitBin, teamManifest)

      # The external-CLI backend talks to a stub KV store.
      let db = ws / "personal-db"
      createDir(db)
      let stub = ws / "personal-store.sh"
      writeStubCli(stub)
      putEnv("DB_DIR", db)
      defer: delEnv("DB_DIR")

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # ---- routing config: one backend per visibility tier --------------
      let routing = BootstrapLockingBody(route: @[
        LockingRouteEntry(visibility: "public", backend: "committed-file",
          path: some("committed-store")),
        LockingRouteEntry(visibility: "team", backend: "git-checkout",
          path: some("manifests-team")),
        LockingRouteEntry(visibility: "personal", backend: "external-cli",
          program: some(stub))])

      let repos = @[
        mkRepo("app", "app", wvPublic),
        mkRepo("teamlib", "teamlib", wvTeam),
        mkRepo("secret", "secret", wvPersonal)]

      let assignments = resolveRepoBackends(
        routing, repos, ws, identity, gitBin)

      # ---- each repo ASSIGNED its backend per its visibility ------------
      check assignments.len == 3
      var byRepo = initTable[string, RepoBackendAssignment]()
      for a in assignments: byRepo[a.repoName] = a
      check byRepo["app"].backendKind == "committed-file"
      check byRepo["teamlib"].backendKind == "git-checkout"
      check byRepo["secret"].backendKind == "external-cli"
      # The three backends are genuinely DISTINCT store objects.
      check byRepo["app"].store != byRepo["teamlib"].store
      check byRepo["teamlib"].store != byRepo["secret"].store
      check byRepo["app"].store != byRepo["secret"].store

      # ---- the operation records each repo through its backend ----------
      var shas = initTable[string, string]()
      shas["app"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      shas["teamlib"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      shas["secret"] = "cccccccccccccccccccccccccccccccccccccccc"
      let outcomes = recordWorkspaceParticipation(assignments, "demo", shas)
      check outcomes.len == 3
      for o in outcomes:
        if not o.recorded:
          checkpoint("not recorded: " & o.repoName & " via " &
            o.backendKind & ": " & o.diagnostic)
        check o.recorded

      # ---- the public record landed in the committed-file medium only ---
      let committedStore = byRepo["app"].store
      let teamStore = byRepo["teamlib"].store
      let personalStore = byRepo["secret"].store

      block publicMedium:
        # On disk under the committed-file store dir.
        check fileExists(ws / "committed-store" / "locks" / "demo" / "app" /
          (shas["app"] & ".rec"))
        let got = committedStore.latestLock("demo", "app")
        check got.isSome
        if got.isSome: check got.get().key.sha == shas["app"]
        # Absent from the OTHER two mediums (distinct-backends isolation).
        check teamStore.latestLock("demo", "app").isNone
        check personalStore.latestLock("demo", "app").isNone

      block teamMedium:
        # A committed lock file in the git-checkout manifest repo.
        check fileExists(teamManifest / "locks" / "demo" / "teamlib" /
          (shas["teamlib"] & ".toml"))
        let got = teamStore.latestLock("demo", "teamlib")
        check got.isSome
        if got.isSome: check got.get().key.sha == shas["teamlib"]
        check committedStore.latestLock("demo", "teamlib").isNone
        check personalStore.latestLock("demo", "teamlib").isNone

      block personalMedium:
        # A key in the external-CLI stub's DB.
        check fileExists(db / ("lock_demo_secret_" & shas["secret"]))
        let got = personalStore.latestLock("demo", "secret")
        check got.isSome
        if got.isSome: check got.get().key.sha == shas["secret"]
        check committedStore.latestLock("demo", "secret").isNone
        check teamStore.latestLock("demo", "secret").isNone

  test "public-only workspace with no routing config constructs no backend":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-mo4-default-", "")
      defer: removeDir(ws)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # No [locking] routes + all-public repos ⇒ the committed solved-graph
      # lock alone: every repo resolves to "committed-lock" with NO store.
      let routing = BootstrapLockingBody()
      let repos = @[
        mkRepo("app", "app", wvPublic),
        mkRepo("lib", "lib", wvPublic)]
      let assignments = resolveRepoBackends(
        routing, repos, ws, identity, gitBin)
      check assignments.len == 2
      for a in assignments:
        check a.backendKind == "committed-lock"
        check a.store.isNil          # NO backend constructed
      var shas = initTable[string, string]()
      shas["app"] = "1111111111111111111111111111111111111111"
      shas["lib"] = "2222222222222222222222222222222222222222"
      let outcomes = recordWorkspaceParticipation(assignments, "demo", shas)
      for o in outcomes:
        check not o.recorded         # nothing written to any store medium
      # No store directory was created under the workspace.
      check not dirExists(ws / ".repro" / "lockstore")
