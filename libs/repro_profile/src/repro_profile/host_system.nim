## Who manages a host's system scope, and how: the `system:` key of a
## block-form `hosts:` entry (reprobuild-pm spec Gradual-Nix-To-Reprobuild-
## Migration.md §Hosts, feature 2, "System-management attribute"; spec
## ReproOS-Add-On-Mode.md §8.1-§8.2).
##
## A home profile's `hosts:` registry is the single host registry. An entry
## says nothing about the host's system when this configuration manages the
## whole of it (the default). Otherwise its `system:` key takes one of two
## values:
##
##   hosts:
##     "build-server":
##       activities: [default, develop_software]
##       system: managedElsewhere("metacraft-labs/infra")
##     "arch":
##       activities: [default]
##       system: managedElsewhere
##     "rpi2":
##       activities: [default]
##       system: addOn
##     "validator-01":
##       activities: [default]
##       system:
##         mode: addOn
##         activities: [ethereum_validator, host_baseline]
##     "reproos-box":
##       activities: [default]
##       system: {mode: full, activities: [host_baseline]}
##
## * `managedElsewhere[("<pointer>")]`: something else manages the system
##   (another repository's deployment, a distribution's own tooling). The
##   optional pointer names it. `repro infra plan` / `apply` and
##   `repro system sync` refuse such a host and name the pointer.
## * `addOn`: the host's system belongs to its distribution (Debian, Ubuntu,
##   ...), and Reprobuild manages a declared set of services, files and
##   accounts on top of it -- ReproOS add-on mode. The short form selects the
##   system profile's `default` activity only. The block form
##   (`mode: addOn` plus `activities: [...]`, also writable inline as
##   `{mode: addOn, activities: [...]}`) selects further system-profile
##   activities; `default` is always enabled and is not listed.
## * `full`: this configuration manages the whole system (the default when
##   the key is absent). The block form `{mode: full, activities: [...]}`
##   selects system activities on such a host (decided 2026-10-30, spec
##   §13 decision 17), with the same validation as `addOn`; the bare
##   `system: full` means exactly what an absent key means.
##
## `repro home export` carries the attribute for the Nix side
## (`intent.hostSystems`, `evaluation.system`, export schema 5).
##
## An entry that says nothing about its system is the common case: a fully
## managed host selecting `default` only. The block form is refused when it
## would mean exactly a short form (no activities), and `default` is refused
## in its activity list.
##
## This module holds the VOCABULARY and the validation the `profile` macro
## and the text parser (`repro_home_intent/parser`) share, plus the lookups
## every reader uses (`systemManagementFor`, `enabledSystemActivities`).

import std/[sets, strutils, tables]

import ./types

const
  HostSystemKey* = "system"
    ## The block-form `hosts:` key.
  ManagedElsewhereKeyword* = "managedElsewhere"
    ## `managedElsewhere` or `managedElsewhere("<pointer>")`.
  AddOnKeyword* = "addOn"
    ## `addOn`, or `mode: addOn` inside the block form.
  FullKeyword* = "full"
    ## `full`, or `mode: full` inside the block form.
  SystemModeKey* = "mode"
    ## The block form's mode line.
  SystemActivitiesKey* = "activities"
    ## The block form's activity list.
  DefaultSystemActivity* = "default"
    ## The system profile's activity every host enables.

type
  ManagementMode* = enum
    ## How a host's system scope is managed, as every reader reports it. The
    ## string values are the export's `evaluation.system.mode` vocabulary.
    mmFull = "full"
      ## No `system:` key: this configuration manages the whole system
      ## (ReproOS, or a system switch such as `nixos-rebuild`).
    mmAddOn = "addOn"
      ## `system: addOn`: Reprobuild manages declared objects on top of the
      ## host's distribution, never the distribution itself.
    mmManagedElsewhere = "managedElsewhere"
      ## `system: managedElsewhere[...]`: something else manages it.

  HostSystemManagement* = object
    ## The system-management attribute of one host, as read from a
    ## profile's `hosts:` registry.
    declared*: bool
      ## The registry has an entry for the host.
    spelled*: bool
      ## The entry has a `system:` key (so `mmFull` was written as
      ## `system: full` or its block form, not left implicit).
    mode*: ManagementMode
    managedBy*: string
      ## The pointer, or "" when the entry names none. Meaningful only for
      ## `mmManagedElsewhere`.
    systemActivities*: seq[string]
      ## The system activities the entry selects beyond `default`
      ## (`mmAddOn` only), in declaration order.

proc managedElsewhere*(m: HostSystemManagement): bool =
  ## The entry says `system: managedElsewhere[...]`.
  m.mode == mmManagedElsewhere

proc isAddOn*(m: HostSystemManagement): bool =
  ## The entry says `system: addOn` (either form).
  m.mode == mmAddOn

proc systemPointerProblem*(pointer: string): string =
  ## Why `pointer` cannot be a `managedElsewhere("...")` argument, or "".
  ## The pointer is free text a diagnostic prints and a script reads, so it
  ## must be one non-blank line: an empty string would read as "no pointer"
  ## while the profile spelled one, and a line break would split the
  ## diagnostic a script parses.
  if pointer.strip().len == 0:
    return "the pointer is empty; write `" & ManagedElsewhereKeyword &
      "` without an argument when nothing names the manager"
  if '\n' in pointer or '\r' in pointer:
    return "the pointer spans several lines; name the manager on one line"
  ""

proc isActivityIdentifier(name: string): bool =
  ## An activity name as every parser of activity lists accepts it: a
  ## non-empty run of ASCII letters, digits and `_`.
  if name.len == 0:
    return false
  for c in name:
    if not (c.isAlphaAscii() or c.isDigit() or c == '_'):
      return false
  true

proc systemActivitiesProblem*(activities: openArray[string]): string =
  ## Why `activities` cannot be the block form's activity list, or "". The
  ## list is what distinguishes the block form from `system: addOn`, so an
  ## empty one is a second spelling of the short form; `default` is always
  ## enabled, so naming it is a second spelling too; a name given twice is
  ## a typo the planner would silently absorb.
  if activities.len == 0:
    return "the activity list is empty; write `system: " & AddOnKeyword &
      "` to select only the system profile's `default` activity"
  var seen = initHashSet[string]()
  for a in activities:
    if not isActivityIdentifier(a):
      return "`" & a & "` is not an activity name (letters, digits and `_`)"
    if a == DefaultSystemActivity:
      return "`" & DefaultSystemActivity & "` is always enabled; list only " &
        "the activities selected beyond it"
    if a in seen:
      return "activity `" & a & "` is listed twice"
    seen.incl a
  ""

proc systemBlockProblem*(mode: string; hasActivities: bool;
                         activities: openArray[string]): string =
  ## Why a block-form `system:` value (`mode:` = `mode`, `""` when absent;
  ## an `activities:` list when `hasActivities`) is invalid, or "". Shared by
  ## the macro and the text parser so both refuse the same shapes with the
  ## same words.
  if mode.len == 0:
    return "the block form needs `" & SystemModeKey & ": " & AddOnKeyword &
      "` or `" & SystemModeKey & ": " & FullKeyword & "`"
  if mode == ManagedElsewhereKeyword:
    return "`" & ManagedElsewhereKeyword & "` selects no system activities; " &
      "write `system: " & ManagedElsewhereKeyword & "` or `system: " &
      ManagedElsewhereKeyword & "(\"<managing repository>\")`"
  if mode notin [AddOnKeyword, FullKeyword]:
    return "unknown mode `" & mode & "` (the block form takes `" &
      SystemModeKey & ": " & AddOnKeyword & "` or `" & SystemModeKey & ": " &
      FullKeyword & "`)"
  if not hasActivities:
    return "the block form needs `" & SystemActivitiesKey & ": [...]`; " &
      "write `system: " & mode & "` to select only `default`"
  systemActivitiesProblem(activities)

proc hostSystemDeclProblem*(decl: HostSystemDecl): string =
  ## Why `decl` is not a value either parser could have produced, or "".
  ## Readers of an encoded intent (RBPI, JSON) check it, so a hand-edited or
  ## newer document is refused instead of half-read.
  case decl.mode
  of hsmManagedElsewhere:
    if decl.activities.len > 0:
      return "a `" & ManagedElsewhereKeyword & "` entry selects no system " &
        "activities"
    if decl.managedBy.len > 0:
      return systemPointerProblem(decl.managedBy)
  of hsmAddOn, hsmFull:
    if decl.managedBy.len > 0:
      return "a `" & $decl.mode & "` entry names no manager"
    if decl.activities.len > 0:
      return systemActivitiesProblem(decl.activities)
  ""

proc systemManagementFor*(intent: ProfileIntent;
                          host: string): HostSystemManagement =
  ## The system-management attribute of `host` in `intent`'s `hosts:`
  ## registry. A host the registry does not name is reported as not
  ## declared and fully managed here; the caller decides whether an
  ## undeclared host is acceptable (`repro infra` plans it as before; the
  ## dotfiles scripts refuse it).
  result.declared = intent.hosts.hasKey(host)
  result.mode = mmFull
  if intent.hostSystems.hasKey(host):
    let decl = intent.hostSystems[host]
    result.spelled = true
    case decl.mode
    of hsmManagedElsewhere:
      result.mode = mmManagedElsewhere
      result.managedBy = decl.managedBy
    of hsmAddOn:
      result.mode = mmAddOn
      result.systemActivities = decl.activities
    of hsmFull:
      result.mode = mmFull
      result.systemActivities = decl.activities

proc enabledSystemActivities*(m: HostSystemManagement): HashSet[string] =
  ## THE system-scope activity selection rule (spec ReproOS-Add-On-Mode.md
  ## §8.2): `default` always, plus the activities an entry's block form
  ## lists (`addOn` or `full`). An undeclared host, or one with no block
  ## form, enables `default` only.
  result = initHashSet[string]()
  result.incl DefaultSystemActivity
  for a in m.systemActivities:
    result.incl a

proc describeManagement*(m: HostSystemManagement): string =
  ## One phrase for diagnostics: "managed here", "managed here in add-on
  ## mode (system activities: default, x)" or "managed elsewhere (...)".
  case m.mode
  of mmFull:
    if m.systemActivities.len > 0:
      "managed here (system activities: " &
        (@[DefaultSystemActivity] & m.systemActivities).join(", ") & ")"
    else:
      "managed here"
  of mmAddOn:
    var acts = @[DefaultSystemActivity]
    acts.add m.systemActivities
    "managed here in add-on mode (system activities: " & acts.join(", ") &
      ")"
  of mmManagedElsewhere:
    if m.managedBy.len > 0:
      "managed elsewhere (by " & m.managedBy & ")"
    else:
      "managed elsewhere (the profile names no manager)"
