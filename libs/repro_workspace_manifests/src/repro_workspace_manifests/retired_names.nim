## repro_workspace_manifests/retired_names.nim
##
## The workspace spellings that branch roles and the settings files replaced,
## kept in ONE place for exactly one purpose: so that a file or a command line
## still using one fails with a diagnostic that names the replacement, rather
## than with a bare "unknown key" that leaves the operator to guess.
##
## Nothing here is a compatibility path. A retired spelling is never read as
## what it used to mean: a `repo.v1` fragment does not load, `[project] trunk`
## and `default_revision` are refused, and the retired settings and state file
## names are not read as settings or state. The one reader of an old file that
## survives is the state-file migration `repro health --fix` runs
## (`workspace_branch.migrateWorkspaceStateFile`), because without it an
## operator still on the old name would have no remedy but editing files by
## hand.
##
## The design these names gave way to is Workspace-Branch-Roles.md and
## Workspace-Settings-Files.md; the retired spellings themselves are listed,
## with their replacements and the reasons, in the specification's
## Retired-Names.md.

import repro_core/workspace_root

import ./types
import ./diagnostics

const
  retiredRepoFragmentSchema* = "reprobuild.workspace.repo.v1"
    ## The fragment schema whose one branch key was `[repo] branch`.
  retiredRepoBranchKey* = "branch"
    ## `[repo] branch`, the mainline under its pre-roles name.
  retiredProjectKeys* = ["trunk", "default_revision"]
    ## `[project]` keys that named a branch for the whole project.
  retiredSettingsSchema* = "reprobuild.workspace.bootstrap.v1"
    ## The schema of the retired settings file.
  retiredSettingsFileName* = workspace_root.RetiredSettingsFileName
    ## `.repro-workspace.toml`.
  retiredPrivateSettingsFileName* = ".repro-workspace-private.toml"
    ## The retired settings file's credential-bearing companion.
  retiredStateFileName* = workspace_root.RetiredStateFileName
    ## `workspace.toml` under `.repro/`.

proc retiredRepoFragmentSchemaMessage*(): string =
  ## Why a fragment declaring the retired schema does not load, and what to
  ## change.
  "`" & retiredRepoFragmentSchema & "` is a retired fragment schema; this " &
    "repro reads `" & schemaRepoFragmentV2 & "`. Change `schema` to \"" &
    schemaRepoFragmentV2 & "\" and rename `[repo] " & retiredRepoBranchKey &
    "` to `mainline`"

proc retiredRepoBranchKeyMessage*(): string =
  ## Why a `[repo] branch` key is refused.
  "`" & retiredRepoBranchKey & "` is not a `[repo]` key (it is retired): a " &
    "repo's mainline is `mainline`"

proc retiredProjectKeyMessage*(key: string): string =
  ## Why a retired `[project]` key is refused, naming what replaced it. ""
  ## for a key that is not retired.
  case key
  of "trunk":
    "`trunk` is not a `[project]` key (it is retired): a project's default " &
      "workspace branch is the workspace root repository's resolved " &
      "mainline. Declare it in repro-workspace.toml — `[workspace] " &
      "mainline`, or a `[workspace] profile` / `default_profile` that " &
      "supplies one"
  of "default_revision":
    "`default_revision` is not a `[project]` key (it is retired): each " &
      "repo's branch is its `mainline`. Declare it in the repo's fragment, " &
      "or once in a `[profiles.<name>]` table of repro-workspace.toml that " &
      "the fragments name (or that `[workspace] default_profile` applies " &
      "to every fragment naming none)"
  else: ""

proc retiredSettingsFileMessage*(): string =
  ## What to do with a retired settings file.
  "`" & retiredSettingsFileName & "` is the retired name of the workspace " &
    "settings file, and this repro does not read it. Rename it to `" &
    SettingsFileName & "` and rewrite it as `schema = \"" &
    schemaWorkspaceSettingsV1 & "\"`: delete a `[manifest]` table that " &
    "names this repository itself, turn one that names a record store into " &
    "`[records] url` / `branch` / `publish_locks`, and replace " &
    "`[manifest] private_url` (and the `" & retiredPrivateSettingsFileName &
    "` companion) with a named `[[manifest]]` layer whose url " &
    "repro-workspace.local.toml supplies"

proc retiredManifestTableMessage*(): string =
  ## Why a single `[manifest]` table in the settings file is refused: it is
  ## the retired settings file's pointer table, whose keys moved.
  "a single `[manifest]` table is the retired settings file's pointer, and " &
    "its keys moved: a record store is `[records] url` / `branch` / " &
    "`publish_locks`, an extra manifest layer is a `[[manifest]]` entry " &
    "(with its own `revision` pin), and `private_url` is a named " &
    "`[[manifest]]` layer whose url repro-workspace.local.toml supplies"

proc retiredStateFileMessage*(): string =
  ## What to do with a state file under its retired name.
  "`.repro/" & retiredStateFileName & "` is the retired name of the " &
    "workspace state file, and this repro does not read it. Run " &
    "`repro health --fix` to move it to `.repro/" & StateFileName & "` " &
    "(its `[[manifest]]` layers move to repro-workspace.local.toml)"

proc refuseRetiredSettingsFile*(dir: string): bool =
  ## Raise when `dir` holds the retired settings file and no current one: the
  ## directory is a workspace root that has not been migrated, and reading it
  ## as "no settings" would silently drop its policy (its record store, its
  ## default projects, its verification). Inside
  ## `toleratingMalformedWorkspaceFiles` (`repro health`) the diagnostic is set
  ## aside for health's `workspace-settings` row instead, and the answer is
  ## `true` — the caller proceeds as if there were no settings file. `false`
  ## when there is nothing to refuse.
  let retired = retiredSettingsFileIn(dir)
  if retired.len == 0:
    return false
  try:
    raiseManifestError(retired, "", schemaWorkspaceSettingsV1,
      retiredSettingsSchema, retiredSettingsFileMessage())
  except WorkspaceManifestParseError as err:
    if not setAsideMalformedWorkspaceFile(err, mwkSettings):
      raise
  true

proc refuseRetiredStateFile*(workspaceRoot: string): bool =
  ## Raise when `workspaceRoot` records its state only under the retired name:
  ## reading it as "no state" would silently forget the active project set
  ## and the workspace branch. Inside `toleratingMalformedWorkspaceFiles`
  ## (`repro health`, whose `--fix` migrates the file) the diagnostic is set
  ## aside for health's `workspace-state` row instead, and the answer is
  ## `true` — the caller proceeds as if no state were recorded. `false` when
  ## there is nothing to refuse.
  let retired = retiredStateFileIn(workspaceRoot)
  if retired.len == 0:
    return false
  try:
    raiseManifestError(retired, "", schemaWorkspaceStateV1, "",
      retiredStateFileMessage())
  except WorkspaceManifestParseError as err:
    if not setAsideMalformedWorkspaceFile(err, mwkState):
      raise
  true
