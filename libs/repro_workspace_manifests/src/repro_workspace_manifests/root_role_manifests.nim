## repro_workspace_manifests/root_role_manifests.nim
##
## The workspace ROOT repository carries the manifests (`projects/`, `repos/`)
## AND declares several roles of its own in the settings file
## (Workspace-Branch-Roles.md §3.4): a `mainline` and, typically, an
## `unstable` branch. Both roles' branches hold manifests, and a manifest
## migration can land on one and not the other. Every other repository has its
## manifests read from exactly one tree, so §3.5's per-load validation is
## enough there; for the root it is not, because a workspace tracking one role
## is then walled off by a defect that is already fixed on the other.
##
## This module answers two questions, both read from git objects and never
## from the working tree:
##
##   * `checkRootRoleManifests`: does every project of every declared role's
##     tree load? (the `root-role-manifests` health row.)
##   * `diagnoseRootRefusal`: a manifest load was refused in this checkout;
##     which branch was it read from, is that checkout already at the tip of
##     the branch it follows (so `workspace sync` cannot change anything), and
##     does another declared role resolve? (the `manifest` row's detail and
##     remedy.)
##
## Specified in CLI/health.md ("Root role manifests") and
## Retired-Names.md ("How each one fails").

import std/[options, os, sets, strutils]

import ./types
import ./diagnostics
import ./manifest_source
import ./resolver
import ./roles
import ./settings
import git_tool

type
  RootRoleFailure* = object
    ## One manifest of one role's tree that does not load.
    file*: string      ## source-relative, `projects/<name>.toml`
    message*: string   ## the loader's diagnostic

  RootRoleManifests* = object
    ## The outcome of loading every project of one declared root branch.
    roles*: seq[string]  ## declared roles naming this branch, in role order
    branch*: string
    refName*: string     ## the ref read: `origin/<branch>` else `<branch>`
    commit*: string      ## its tip, short; empty when `available` is false
    available*: bool     ## false: no such ref exists locally, nothing was read
    projects*: int       ## how many `projects/*.toml` were loaded
    failures*: seq[RootRoleFailure]

  RootRefusalDiagnosis* = object
    ## Why a manifest refusal in the root checkout may not be fixable by
    ## `workspace sync`.
    currentBranch*: string   ## empty when HEAD is detached
    currentCommit*: string   ## short
    followedRef*: string     ## the ref the checkout follows, or empty
    followedCommit*: string  ## short
    atTip*: bool             ## HEAD has everything `followedRef` has
    otherRoles*: seq[RootRoleManifests]
      ## the OTHER declared branches, each with its load outcome
    resolvingBranch*: string ## first other branch whose manifests all load

const
  shortSha = 10

proc git(identity: GitToolIdentity; root: string; args: varargs[string]):
    Option[string] =
  ## Stdout of a read-only git query in `root`, `none` on any failure.
  try:
    let res = queryGit(identity, @["-C", root] & @args)
    if res.code == 0: some(res.output.strip()) else: none(string)
  except CatchableError:
    none(string)

proc gitIdentity(): Option[GitToolIdentity] =
  try:
    some(ensureGitToolResolvable(tpmPathOnly, getEnv("PATH")))
  except CatchableError:
    none(GitToolIdentity)

proc declaredRootBranches*(s: WorkspaceSettings):
    seq[tuple[branch: string; roles: seq[string]]] =
  ## Every branch a role DECLARED by the root repository names (§3.4),
  ## distinct, mainline first, each with the roles that name it. A role that
  ## merely falls back to the mainline is not listed: it reads the mainline's
  ## tree and adds no tree of its own. Empty when the settings declare no
  ## mainline.
  var roles: seq[ResolvedRole]
  try:
    roles = resolveRootRoles(s)
  except WorkspaceManifestParseError:
    return
  for r in roles:
    if r.branch.len == 0 or r.resolvedRole != r.role:
      continue
    var placed = false
    for entry in result.mitems:
      if entry.branch == r.branch:
        entry.roles.add(r.role)
        placed = true
    if not placed:
      result.add((branch: r.branch, roles: @[r.role]))

proc readRootRef(identity: GitToolIdentity; root, branch: string):
    tuple[refName, commit: string] =
  ## The published tip when the checkout has one (`origin/<branch>`), else the
  ## local branch. The remote-tracking ref is what the other workspaces on the
  ## machine will read, so it is the tree whose manifests matter.
  for candidate in ["origin/" & branch, branch]:
    let ref0 = (if candidate.startsWith("origin/"): "refs/remotes/" & candidate
                else: "refs/heads/" & candidate)
    let sha = git(identity, root, "rev-parse", "--verify", "--quiet",
      ref0 & "^{commit}")
    if sha.isSome and sha.get().len > 0:
      return (refName: candidate, commit: sha.get())

proc loadBranchManifests(root, branch: string; roleNames: seq[string];
                         identity: GitToolIdentity): RootRoleManifests =
  result = RootRoleManifests(roles: roleNames, branch: branch)
  let found = readRootRef(identity, root, branch)
  if found.commit.len == 0:
    return
  result.available = true
  result.refName = found.refName
  result.commit = found.commit[0 ..< min(shortSha, found.commit.len)]
  var source: ManifestSource
  try:
    source = openGitRevisionSource(root, found.commit,
      identity.binaryPath)
  except WorkspaceManifestParseError as err:
    result.failures.add(RootRoleFailure(file: "(tree)", message: err.msg))
    return
  defer: source.close()
  var roleSettings: RoleSettings
  try:
    roleSettings = sourceRoleSettings(source)
  except WorkspaceManifestParseError as err:
    result.failures.add(RootRoleFailure(file: settingsFileName,
      message: err.msg))
    return
  for rel in source.listTomlFiles("projects"):
    inc result.projects
    try:
      discard resolveProjectAt(source, rel, roleSettings)
    except WorkspaceManifestParseError as err:
      result.failures.add(RootRoleFailure(file: rel, message: err.msg))
    except CatchableError as err:
      result.failures.add(RootRoleFailure(file: rel, message: err.msg))

proc checkRootRoleManifests*(workspaceRoot: string):
    seq[RootRoleManifests] =
  ## Load every `projects/*.toml` from the tip of every branch the root
  ## repository's settings file declares a role for. One entry per distinct
  ## branch. Empty when `workspaceRoot` is not a git checkout, has no settings
  ## file, or declares no mainline: there is then nothing to compare.
  let identity = gitIdentity()
  if identity.isNone or not dirExists(workspaceRoot / ".git") and
      not fileExists(workspaceRoot / ".git"):
    return
  let found = findWorkspaceSettings(workspaceRoot)
  if found.isNone:
    return
  for entry in declaredRootBranches(found.get()):
    result.add(loadBranchManifests(workspaceRoot, entry.branch, entry.roles,
      identity.get()))

proc describeFailures*(r: RootRoleManifests; limit = 3): string =
  ## `projects/a.toml: <message>` for the first `limit` failures, then a count.
  var parts: seq[string]
  for i, f in r.failures:
    if i >= limit:
      parts.add("and " & $(r.failures.len - limit) & " more")
      break
    parts.add(f.file & ": " & f.message)
  parts.join("; ")

proc rolesText*(r: RootRoleManifests): string =
  "role " & (if r.roles.len > 1: "s " else: "") & r.roles.join(", ") &
    " (branch '" & r.branch & "')"

proc diagnoseRootRefusal*(workspaceRoot: string): Option[RootRefusalDiagnosis] =
  ## Read the root checkout's own state after a manifest refusal. `none` when
  ## the root is not a git checkout, so the caller keeps its generic text.
  let identity = gitIdentity()
  if identity.isNone:
    return
  let id = identity.get()
  # `git -C` climbs to an enclosing repository; the root must itself be the
  # checkout (a directory `.git`, or a file for a worktree).
  if not dirExists(workspaceRoot / ".git") and
      not fileExists(workspaceRoot / ".git"):
    return
  if git(id, workspaceRoot, "rev-parse", "--git-dir").isNone:
    return
  var d = RootRefusalDiagnosis()
  let head = git(id, workspaceRoot, "rev-parse", "--verify", "--quiet",
    "HEAD^{commit}")
  if head.isNone:
    return
  d.currentCommit = head.get()[0 ..< min(shortSha, head.get().len)]
  d.currentBranch = git(id, workspaceRoot, "symbolic-ref", "--quiet",
    "--short", "HEAD").get("")
  if d.currentBranch.len > 0:
    let up = git(id, workspaceRoot, "rev-parse", "--abbrev-ref",
      d.currentBranch & "@{upstream}")
    d.followedRef = if up.isSome: up.get() else: ""
    if d.followedRef.len == 0:
      let guess = readRootRef(id, workspaceRoot, d.currentBranch)
      d.followedRef = guess.refName
    if d.followedRef.len > 0:
      let tip = git(id, workspaceRoot, "rev-parse", "--verify", "--quiet",
        d.followedRef & "^{commit}")
      if tip.isSome:
        d.followedCommit = tip.get()[0 ..< min(shortSha, tip.get().len)]
        # `sync` fast-forwards toward the ref; it can change nothing when
        # HEAD already contains the ref's tip.
        d.atTip = git(id, workspaceRoot, "merge-base", "--is-ancestor",
          d.followedRef, "HEAD").isSome
  let settings = findWorkspaceSettings(workspaceRoot)
  if settings.isSome:
    for entry in declaredRootBranches(settings.get()):
      if entry.branch == d.currentBranch:
        continue
      let outcome = loadBranchManifests(workspaceRoot, entry.branch,
        entry.roles, id)
      if outcome.available and outcome.failures.len == 0 and
          d.resolvingBranch.len == 0:
        d.resolvingBranch = entry.branch
      d.otherRoles.add(outcome)
  some(d)

proc refusalDetailSuffix*(d: RootRefusalDiagnosis): string =
  ## What to append to the `manifest` row's detail: which branch the manifests
  ## were read from and what the other declared roles say.
  var parts: seq[string]
  if d.currentBranch.len > 0:
    parts.add("read from branch '" & d.currentBranch & "' at " &
      d.currentCommit &
      (if d.followedRef.len > 0:
         (if d.atTip: ", which is the tip of " & d.followedRef &
            " (" & d.followedCommit & ")"
          else: ", behind " & d.followedRef & " (" & d.followedCommit & ")")
       else: ""))
  else:
    parts.add("read from a detached HEAD at " & d.currentCommit)
  for o in d.otherRoles:
    if not o.available:
      continue
    if o.failures.len == 0:
      parts.add(rolesText(o) & " resolves: all " & $o.projects &
        " project manifests load at " & o.refName & " (" & o.commit & ")")
    else:
      parts.add(rolesText(o) & " does not resolve either at " & o.refName &
        " (" & o.commit & "): " & describeFailures(o, 1))
  "(" & parts.join("; ") & ")"

proc refusalRemedy*(d: RootRefusalDiagnosis; syncCommand: string): string =
  ## The remedy for a manifest refusal. `workspace sync` is named only when it
  ## can change the outcome: the checkout is behind the ref it follows. At the
  ## tip it is a no-op, and the remedy is to land the fix on this branch from
  ## the role that resolves (never to hand-edit the manifest here).
  if d.currentBranch.len == 0 or d.followedRef.len == 0 or not d.atTip:
    return syncCommand
  if d.resolvingBranch.len > 0:
    return "this checkout is already at the tip of " & d.followedRef &
      ", so `workspace sync` changes nothing (unless the remote has moved since the last fetch); the fix is on branch '" &
      d.resolvingBranch & "' and has to land on '" & d.currentBranch &
      "' (cherry-pick the manifest change from '" & d.resolvingBranch &
      "', do not edit the manifest in this checkout)"
  "this checkout is already at the tip of " & d.followedRef &
    ", so `workspace sync` changes nothing (unless the remote has moved since the last fetch); no other declared role of the " &
    "root repository resolves either, so the manifest itself has to be " &
    "fixed on '" & d.currentBranch & "' and on every declared branch"
