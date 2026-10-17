## Activity-scoped `stow/` packages: a `stow:` block inside an activity
## (reprobuild-pm spec Home-Profile-Intent-Layer.md §Stow-Style Dotfile
## Support, "Packages that belong to an activity";
## Gradual-Nix-To-Reprobuild-Migration.md §Hosts, GM11).
##
## A profile's `stow/` tree is discovered without a declaration: every
## immediate subdirectory is a GNU `stow` package and every file in it is
## linked into `$HOME` on every host. Some packages configure a layer only
## some hosts run -- a GUI terminal's settings, remote-desktop connection
## files -- and a headless host should not get them. Such a package is
## claimed by the activity it belongs to:
##
##   activity desktop_core:
##     kitty
##     stow:
##       "kitty"            # stow/kitty/ belongs to desktop_core
##       "rdp"
##
##   activity default:
##     stow:
##       when windows():
##         "rdp"            # ... and to every Windows host
##
## The rule, applied by the planner for the host being planned:
##
##   * a package no claim names is materialized on every host (unchanged);
##   * a package some claim names is materialized only where at least one
##     of its claims holds -- the host's selection enables the claim's
##     activity AND the claim's guard holds there;
##   * a claim naming a package the `stow/` tree does not have is refused
##     at plan time (Core-Invariants.md §Unrecognised Input Is Rejected,
##     Not Skipped).
##
## Claims are a union: the same package may be claimed by several
## activities (or under several guards); naming it twice in one activity is
## refused as a mistake.
##
## This module holds the validation the `profile` macro, the intent
## decoders and the home adapter share.

import std/[sets, strutils]

import ./types

const
  StowBlockKeyword* = "stow"
    ## The block name inside `activity <name>:`.

proc stowPackageNameProblem*(name: string): string =
  ## Why `name` cannot name a `stow/` package, or "". A package is ONE
  ## immediate subdirectory of `stow/`, so the name is one path segment:
  ## not empty, no separator, not `.` / `..`, no surrounding whitespace and
  ## no control character (it is printed in diagnostics).
  if name.len == 0:
    return "the package name is empty"
  if name != name.strip():
    return "the package name `" & name & "` has leading or trailing whitespace"
  if name in [".", ".."]:
    return "`" & name & "` is not a package directory"
  for ch in name:
    if ch in {'/', '\\'}:
      return "`" & name & "` is a path; name one immediate subdirectory " &
        "of stow/ (e.g. \"kitty\" for stow/kitty/)"
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return "the package name `" & name.escape() &
        "` contains a control character"
  ""

proc stowScopesProblem*(scopes: openArray[StowScope];
                        declaredActivities: openArray[string]): string =
  ## Why `scopes` cannot be a profile's stow claims, or "". The macro builds
  ## only valid claims; this is the check every reader repeats for an
  ## intent that reached it another way (an envelope, a JSON document), so a
  ## malformed claim is refused rather than ignored or widened to every
  ## host.
  var declared = initHashSet[string]()
  for a in declaredActivities:
    declared.incl a
  var seen = initHashSet[(string, string, string)]()
  for s in scopes:
    let nameProblem = stowPackageNameProblem(s.package)
    if nameProblem.len > 0:
      return "stow claim of activity `" & s.activity & "`: " & nameProblem
    if s.activity.len == 0:
      return "stow claim of `" & s.package & "` names no activity"
    if s.activity notin declared:
      return "stow claim of `" & s.package & "` names activity `" &
        s.activity & "`, which the profile does not declare"
    let key = (s.package, s.activity, s.guard.expr)
    if key in seen:
      return "activity `" & s.activity & "` claims stow package `" &
        s.package & "` twice"
    seen.incl key
  ""
