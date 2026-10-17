## Who manages a host's system scope: the `system:` key of a block-form
## `hosts:` entry (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Hosts, feature 2, "System-management attribute").
##
## A home profile's `hosts:` registry is the single host registry. A host
## whose home this profile manages but whose system something else manages
## (another repository's deployment, a distribution's own tooling) says so:
##
##   hosts:
##     "build-server":
##       activities: [default, develop_software]
##       system: managedElsewhere("metacraft-labs/infra")
##     "arch":
##       activities: [default]
##       system: managedElsewhere
##
## The argument is an optional pointer to what manages the system --
## normally the managing repository. `repro infra plan` / `apply` and
## `repro system sync` refuse such a host and name the pointer, and
## `repro home export` carries the attribute for the Nix side
## (`intent.systemManagedElsewhere`, export schema 4).
##
## A host without `system:` is managed here (the default). There is no
## spelling for "managed here": an entry that says nothing about its system
## is the common case, and a second spelling for it would be a second way to
## write the same registry.
##
## This module holds the VOCABULARY and the validation the `profile` macro
## and the text parser (`repro_home_intent/parser`) share, plus the one
## lookup every reader uses (`systemManagementFor`).

import std/[strutils, tables]

import ./types

const
  HostSystemKey* = "system"
    ## The block-form `hosts:` key.
  ManagedElsewhereKeyword* = "managedElsewhere"
    ## Its only value: `managedElsewhere` or `managedElsewhere("<pointer>")`.

type
  HostSystemManagement* = object
    ## The system-management attribute of one host, as read from a
    ## profile's `hosts:` registry.
    declared*: bool
      ## The registry has an entry for the host.
    managedElsewhere*: bool
      ## The entry says `system: managedElsewhere[...]`.
    managedBy*: string
      ## The pointer, or "" when the entry names none. Meaningful only when
      ## `managedElsewhere`.

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

proc systemManagementFor*(intent: ProfileIntent;
                          host: string): HostSystemManagement =
  ## The system-management attribute of `host` in `intent`'s `hosts:`
  ## registry. A host the registry does not name is reported as not
  ## declared and managed here; the caller decides whether an undeclared
  ## host is acceptable (`repro infra` plans it as before; the dotfiles
  ## scripts refuse it).
  result.declared = intent.hosts.hasKey(host)
  if intent.systemManagedElsewhere.hasKey(host):
    result.managedElsewhere = true
    result.managedBy = intent.systemManagedElsewhere[host]

proc describeManagement*(m: HostSystemManagement): string =
  ## One phrase for diagnostics: "managed elsewhere (by <pointer>)" or
  ## "managed elsewhere (no pointer given)" or "managed here".
  if not m.managedElsewhere:
    "managed here"
  elif m.managedBy.len > 0:
    "managed elsewhere (by " & m.managedBy & ")"
  else:
    "managed elsewhere (the profile names no manager)"
