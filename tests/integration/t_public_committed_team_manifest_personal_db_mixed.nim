## Workspace-Manifest-Optional MO-4 — a MIXED workspace (one public repo, one
## team repo, one personal repo) records each repo's participation through its
## own backend end-to-end, AND an unrouted private repo fails loud.
##
## Routing:  public → committed-file (the committed-lock medium),
##           team → git-checkout (a company git manifest),
##           personal → external-CLI (a DB-backed personal store).
## The MO-4 recording operation (``recordWorkspaceParticipation``) runs across
## all three and SUCCEEDS, and we assert:
##   - the public repo's participation is in the committed (committed-file)
##     medium;
##   - the team repo's is in the git manifest backend;
##   - the personal repo's is in the external-CLI/DB stub.
##
## Missing-backend leg: with NO route for the personal tier, a personal repo
## present in the workspace makes ``resolveRepoBackends`` raise a loud
## ``StoreRoutingError`` that NAMES the repo and the remedy — you cannot record
## a private repo's participation with nowhere to put it.
##
## Falsifiable: if the router collapsed all repos to one backend, the
## per-medium reads for the other two backends would be empty and the medium
## assertions fail; if a missing private backend did NOT error, the final
## ``expect StoreRoutingError`` block fails. Confirmed both ways locally.
##
## Skip rule: ``git`` missing on PATH (the git-checkout backend needs it).

import std/[options, os, osproc, strutils, tables, tempfiles, unittest]

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

suite "MO-4 — mixed public/team/personal workspace":

  test "t_public_committed_team_manifest_personal_db_mixed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-mo4-mixed-", "")
      defer: removeDir(ws)

      let companyManifest = ws / "company-manifest"
      initGitRepo(gitBin, companyManifest)

      let db = ws / "personal-db"
      createDir(db)
      let stub = ws / "personal-store.sh"
      writeStubCli(stub)
      putEnv("DB_DIR", db)
      defer: delEnv("DB_DIR")

      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      let routing = BootstrapLockingBody(route: @[
        LockingRouteEntry(visibility: "public", backend: "committed-file",
          path: some("committed-lock")),
        LockingRouteEntry(visibility: "team", backend: "git-checkout",
          path: some("company-manifest")),
        LockingRouteEntry(visibility: "personal", backend: "external-cli",
          program: some(stub))])

      let repos = @[
        mkRepo("ui", "ui", wvPublic),
        mkRepo("teamcore", "teamcore", wvTeam),
        mkRepo("notes", "notes", wvPersonal)]

      let assignments = resolveRepoBackends(
        routing, repos, ws, identity, gitBin)
      var byRepo = initTable[string, RepoBackendAssignment]()
      for a in assignments: byRepo[a.repoName] = a

      var shas = initTable[string, string]()
      shas["ui"] = "1010101010101010101010101010101010101010"
      shas["teamcore"] = "2020202020202020202020202020202020202020"
      shas["notes"] = "3030303030303030303030303030303030303030"

      # ---- the operation succeeds across all three backends -------------
      let outcomes = recordWorkspaceParticipation(assignments, "mix", shas)
      check outcomes.len == 3
      for o in outcomes:
        if not o.recorded:
          checkpoint("not recorded: " & o.repoName & " (" & o.backendKind &
            "): " & o.diagnostic)
        check o.recorded

      # ---- public participation in the committed (committed-file) lock --
      check byRepo["ui"].backendKind == "committed-file"
      check fileExists(ws / "committed-lock" / "locks" / "mix" / "ui" /
        (shas["ui"] & ".rec"))
      let uiGot = byRepo["ui"].store.latestLock("mix", "ui")
      check uiGot.isSome
      if uiGot.isSome: check uiGot.get().key.sha == shas["ui"]

      # ---- team participation in the git manifest backend ---------------
      check byRepo["teamcore"].backendKind == "git-checkout"
      check fileExists(companyManifest / "locks" / "mix" / "teamcore" /
        (shas["teamcore"] & ".toml"))
      let teamGot = byRepo["teamcore"].store.latestLock("mix", "teamcore")
      check teamGot.isSome
      if teamGot.isSome: check teamGot.get().key.sha == shas["teamcore"]

      # ---- personal participation in the external-CLI/DB stub -----------
      check byRepo["notes"].backendKind == "external-cli"
      check fileExists(db / ("lock_mix_notes_" & shas["notes"]))
      let notesGot = byRepo["notes"].store.latestLock("mix", "notes")
      check notesGot.isSome
      if notesGot.isSome: check notesGot.get().key.sha == shas["notes"]

      # ---- cross-medium isolation: no record bled into another backend --
      check byRepo["teamcore"].store.latestLock("mix", "ui").isNone
      check byRepo["notes"].store.latestLock("mix", "ui").isNone
      check byRepo["ui"].store.latestLock("mix", "teamcore").isNone

  test "private repo with no assigned backend fails loud":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let ws = createTempDir("repro-mo4-noback-", "")
      defer: removeDir(ws)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)

      # Public + team are routed; the PERSONAL tier is NOT. A personal repo
      # in the workspace then has nowhere to record its participation.
      let routing = BootstrapLockingBody(route: @[
        LockingRouteEntry(visibility: "public", backend: "committed-file",
          path: some("committed-lock"))])
      let repos = @[
        mkRepo("ui", "ui", wvPublic),
        mkRepo("secretlib", "secretlib", wvPersonal)]

      var raised = false
      try:
        discard resolveRepoBackends(routing, repos, ws, identity, gitBin)
      except StoreRoutingError as err:
        raised = true
        # The error names the offending repo AND the remedy.
        check err.msg.contains("secretlib")
        check err.msg.contains("personal")
        check err.msg.contains("[[locking.route]]")
      check raised
