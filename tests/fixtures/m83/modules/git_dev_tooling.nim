## M83 Phase A fixture sibling module: exports a `gitDevTooling`
## template that contributes a small bundle of resource entries.
## Imported by `home_with_module.nim` to verify that user-authored
## modules compose correctly into a profile.

import std/tables

import repro_profile

template gitDevTooling*(targetResources: var seq[ResourceIntent]) =
  ## Reusable git-development resource bundle. Phase A users invoke
  ## this from within `resources:` blocks; the macro splices the
  ## destination seq in as the first positional argument so this
  ## template's signature matches that contract.
  envUserVariable(targetResources, name = "GIT_PAGER", value = "delta")
  fsUserFile(targetResources, hostFile = "~/.gitconfig",
    content = "[user]\n  name = Test User\n")
