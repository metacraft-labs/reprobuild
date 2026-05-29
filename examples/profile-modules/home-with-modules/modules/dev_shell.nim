## Canonical M83 Phase F1 example sibling module: a developer shell
## bundle.
##
## This is the second of two sample modules shipped under
## ``examples/profile-modules/home-with-modules/``. It exists to
## demonstrate that multiple sibling modules compose — the host
## profile can `import` both and call them side-by-side without either
## helper interfering with the other.
##
## ``developerShell()`` returns ``seq[ActivityElement]``: the search
## tools (`ripgrep`, `fd`), a JSON CLI (`jq`), and a modal editor
## (`neovim`). The activity-body parser splats the result.

import repro_profile

proc developerShell*(): seq[ActivityElement] =
  ## A small bundle of developer shell tooling. Use alongside
  ## ``gitDevTooling()`` to get a complete CLI development
  ## environment.
  @[
    package "ripgrep",
    package "fd",
    package "jq",
    package "neovim",
  ]
