## Canonical M83 Phase F1 example sibling module: a git development
## environment bundle.
##
## This module is a teaching artifact. It demonstrates the two
## composition shapes that user-authored modules can use to extend a
## profile:
##
##   1. ``gitDevTooling()`` returns ``seq[ActivityElement]``. The
##      activity-body parser splats the result so the helper's package
##      list inlines into the activity, exactly as if the user had
##      written every package name by hand.
##
##   2. ``gitIdentity()`` is a config-override helper. It takes the
##      in-scope override list (which the ``config:`` macro splices in
##      as the first positional argument, mirroring the resource-
##      constructor convention) and appends one ``ConfigOverride``
##      record per git config key. The user invokes it inside the
##      ``config:`` block.
##
## Together they show that a single sibling module can contribute to
## multiple sections of the host profile, and that the host profile's
## body remains declarative — the call sites read as data, not as
## imperative code.

import repro_profile

proc gitDevTooling*(): seq[ActivityElement] =
  ## Reusable git-development package bundle. Includes the git CLI
  ## (`git`), the GitHub CLI (`gh`), a terminal-UI front-end
  ## (`lazygit`), and a diff pager (`delta`). The activity-body
  ## parser inlines each returned element via the splat convention.
  @[
    package "git",
    package "gh",
    package "lazygit",
    package "delta",
  ]

template gitIdentity*(targetOverrides: var seq[ConfigOverride];
                      name, email: string) =
  ## Append `user.name` + `user.email` overrides to a profile's
  ## `configOverrides` list. The `config:` macro splices the in-scope
  ## list in as the first positional argument when the user writes
  ## `gitIdentity(name = "...", email = "...")` inside a `config:`
  ## block; this template's signature matches that contract.
  targetOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue(name))
  targetOverrides.add ConfigOverride(pkg: "git", key: "userEmail",
    value: strValue(email))
