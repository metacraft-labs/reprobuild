## GM4 — plan-time expansion of a profile's data files.
##
## The profile binary declares its data files by name only
## (`ProfileIntent.dataFiles`, the `data:` section). This module is the ONE
## place that turns those references into intent: it reads each file
## (`repro_home_intent.readDataFile`, which validates the fixed row schema
## and the built-in-only `when` grammar) and merges every row into the
## named activity as the activity-body element the row stands for.
## `repro home plan` / `apply` / `apply --plan` (through
## `compileAndAdaptHomeProfile`) and `repro home export` all call it, so the
## planner, the export and the export's `--target` evaluation see the same
## rows (Core-Invariants.md §One Implementation Per Concern).
##
## The expansion runs AFTER the profile-compile edge, never inside it: the
## edge's inputs are the Nim sources io-mon observes the compiler read, and
## no step of the compile or of the profile binary's run opens a data file.
## Editing a data file therefore re-plans without recompiling
## (Gradual-Nix-To-Reprobuild-Migration.md §Declarative data files read at
## plan time; gate `e2e_data_file_edit_does_not_recompile`).
##
## Row semantics (also what GM5's Nix `readData` must reproduce, against
## the shared fixtures under `tests/fixtures/data-files/`):
##
## * files are expanded in `data:` order, rows in file order;
## * a row joins the activity it names; an activity no `activity` block
##   declares is created after the declared ones (in first-row order), so a
##   data file can carry a whole activity that `hosts:` selects — exactly as
##   `repro home add --activity` creates one;
## * a row without `when` is the element `package(<name>[, "<version>"]
##   [, binaries = @[...]])`; with `when` it is that element inside
##   `when <predicate>:`, the predicate in canonical form;
## * which rows apply on a host is then the planner's ordinary rule: the
##   row's activity is enabled for the host, and its guard holds for the
##   target;
## * a `[[resource]]` row is the resource its kind's constructor builds from
##   the row's keys (the constructor's parameters), appended to the
##   profile-wide resources after the compiled ones in `data:` / file order,
##   with its `when` (canonical) as the guard — it applies on a host when the
##   guard holds, like a guarded entry of `resources:`.

import std/[os]

import repro_profile
import repro_home_intent

import ./adapter_home

type
  ExpandedHomeIntent* = object
    intent*: ProfileIntent
      ## The compiled intent with every data row merged into `activities`
      ## and `dataFiles` emptied: an expanded intent cannot be expanded
      ## twice.
    dataFiles*: seq[DataFile]
      ## Each declared file as read — reference, exact bytes, rows — in
      ## `data:` order. The bytes are what the generation records and what
      ## `repro home export` digests.

proc dataRowElement*(row: DataPackageRow): ActivityElement =
  ## The activity-body element a row stands for.
  let reference = ActivityElement(kind: aekPackageRef, pkgName: row.name,
    pkgVersion: row.version, pkgBinaries: row.binaries)
  if row.whenPredicate.len == 0:
    return reference
  ActivityElement(kind: aekWhenGuard,
    predicate: PredicateExpr(expr: canonicalize(row.whenPredicate)),
    guardedBody: @[reference])

proc mergeDataRows*(intent: var ProfileIntent; files: openArray[DataFile]) =
  ## Merge the rows of `files` into `intent.activities` and
  ## `intent.resources` (see the module header for the order) and clear
  ## `intent.dataFiles`.
  for file in files:
    for row in file.rows:
      var target = -1
      for i, activity in intent.activities:
        if activity.name == row.activity:
          target = i
          break
      if target < 0:
        intent.activities.add ActivityIntent(name: row.activity)
        target = intent.activities.high
      intent.activities[target].body.add dataRowElement(row)
    # Resource rows were built by their constructors when the file was read
    # (`repro_profile/resource_rows`); they join the profile-wide resources
    # after the compiled ones, in file order, guard attached.
    for resource in file.resources:
      intent.resources.add resource
  intent.dataFiles = @[]

proc expandProfileData*(intent: ProfileIntent; profilePath: string):
    ExpandedHomeIntent =
  ## Read the data files `intent` declares (relative to the directory of
  ## `profilePath`, the profile's `home.nim`) and merge their rows. Raises
  ## `EDataFile` for a missing, unreadable or invalid file, or for a
  ## reference the shared path rule (`dataFilePathProblem`) refuses — the
  ## macro already refused it, but an RBPI envelope is an input like any
  ## other. An intent that declares no data files is returned unchanged.
  result.intent = intent
  let profileDir = profilePath.parentDir
  for reference in intent.dataFiles:
    let problem = dataFilePathProblem(reference)
    if problem.len > 0:
      raiseDataFile(profilePath, reference, 0, "", problem)
    result.dataFiles.add readDataFile(profilePath, profileDir, reference)
  mergeDataRows(result.intent, result.dataFiles)

proc toLoadedDataFiles*(files: openArray[DataFile]): seq[LoadedDataFile] =
  ## The `Profile.loadedDataFiles` record of `files`: what the generation's
  ## intent snapshot stores.
  for f in files:
    result.add LoadedDataFile(path: f.path, content: f.content)

proc expandedHomeProfile*(intent: ProfileIntent; profilePath: string):
    Profile =
  ## The compile-then-adapt step every home planning path takes: expand the
  ## data files, adapt the expanded intent for the apply pipeline, and
  ## attach the bytes read so the generation records them.
  let expanded = expandProfileData(intent, profilePath)
  result = profileIntentToHomeProfile(expanded.intent, profilePath)
  result.loadedDataFiles = toLoadedDataFiles(expanded.dataFiles)
