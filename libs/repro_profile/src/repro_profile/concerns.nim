## The home-profile concerns: the names a `hosts:` entry's `applies:` list
## may use to say which parts of the profile Reprobuild applies on a host
## (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Concern-scoped apply).
##
## This module holds the VOCABULARY only -- the closed set of names, in their
## canonical order, and the validation the `profile` macro and the text
## parser share. Which operation belongs to which concern is decided in one
## place, `repro_home_resources/concerns` (resource kinds and generation
## records) and `repro_home_apply/pipeline` (package references, whose
## concern depends on the realization the planner selects).
##
## The names are aligned with the Nix helper library's category switches
## (`packages`, `homebrew` = `applications`, `files`, `environment`) and with
## the host-facts categories, so a category switch and a concern cover the
## same entries.

import std/[strutils]

type
  HomeConcern* = enum
    ## One concern of a home profile. The string form is the name a profile
    ## writes and every document (manifest, export, host facts) carries.
    hcPackages = "packages"
      ## Package references whose selected realization does not place an
      ## application (and references with no realization at all).
    hcApplications = "applications"
      ## Package references whose selected realization places an
      ## application bundle; Homebrew token resources.
    hcFiles = "files"
      ## Stow links, package-generated files, `fs.userFile`, `config:`
      ## overrides.
    hcEnvironment = "environment"
      ## `env.userVariable`, `env.userPath`, `shell.integration`,
      ## `fs.managedBlock`.
    hcServices = "services"
      ## `systemd.userUnit`, `launchd.userAgent`, `windows.startup`.
    hcSettings = "settings"
      ## `macos.userDefault`, `linux.gsettings`, `linux.dconfKey`,
      ## `linux.kdeConfigKey`, `windows.registryValue`, `vscode.extension`.

  ConcernSet* = set[HomeConcern]

const
  AllHomeConcerns*: ConcernSet = {low(HomeConcern) .. high(HomeConcern)}

proc homeConcernNames*(): seq[string] =
  ## Every concern name, in canonical order.
  for c in HomeConcern:
    result.add $c

proc parseHomeConcern*(name: string; concern: var HomeConcern): bool =
  ## Parse a concern name. Exact match only: names are lower-case
  ## identifiers and a near miss (`Packages`, `app`) is an unknown concern,
  ## not a spelling to be guessed at.
  for c in HomeConcern:
    if $c == name:
      concern = c
      return true
  false

proc concernListProblem*(names: openArray[string]): string =
  ## Why `names` is not a valid `applies:` list, or "" when it is. An unknown
  ## name and a name given twice are refused (Core-Invariants.md
  ## §Unrecognised Input Is Rejected, Not Skipped); an empty list is valid
  ## (Reprobuild applies nothing on that host).
  var seen: ConcernSet
  for name in names:
    var c: HomeConcern
    if not parseHomeConcern(name, c):
      return "unknown concern `" & name & "` (known: " &
        homeConcernNames().join(", ") & ")"
    if c in seen:
      return "concern `" & name & "` is named twice"
    seen.incl c
  ""

proc toConcernSet*(names: openArray[string]): ConcernSet =
  ## The set `names` denotes. Raises `ValueError` naming the problem when
  ## `concernListProblem` refuses the list.
  let problem = concernListProblem(names)
  if problem.len > 0:
    raise newException(ValueError, problem)
  for name in names:
    var c: HomeConcern
    discard parseHomeConcern(name, c)
    result.incl c

proc concernNames*(s: ConcernSet): seq[string] =
  ## The names of `s`, in canonical order.
  for c in HomeConcern:
    if c in s:
      result.add $c
