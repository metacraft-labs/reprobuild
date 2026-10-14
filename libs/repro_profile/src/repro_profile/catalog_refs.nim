## Contribution-catalog imports a profile declares.
##
## A recipe imports a provisioning-contribution catalog
## (`reprobuild-nix-packages`, `reprobuild-scoop-packages`, an
## `reprobuild-llm-agent-packages` module, ...) with a Nim `import` of the
## catalog's module, and the `provisioningFor` blocks that module registers
## become candidates for the recipe's `uses:`. A home profile declares the
## same imports in its `catalogs:` section; `repro home apply` writes them as
## those `import` statements into the recipe it extracts the profile's
## package references from (`repro_home_apply/catalog_projection`), so a
## profile reference sees exactly the contributions a recipe importing the
## same modules sees (Provisioning-Contributions.md §"Profile Package
## References").
##
## This module holds the one rule for what an entry may spell, shared by the
## `profile` macro, the text inspector (`repro_home_intent`) and the
## projection, so the three cannot accept different paths. It depends on
## `std/strutils` only, so importing it adds nothing to the profile compile's
## closure.

import std/strutils

const CatalogModuleExtension* = ".nim"
  ## A declared module may name its file with or without this suffix, as a
  ## Nim `import` may.

proc catalogImportPathProblem*(path: string): string =
  ## Why ``path`` cannot name a catalog module a profile imports, or "" when
  ## it can. An entry names the catalog's Nim module relative to the
  ## profile directory, the way a recipe's `import "../catalog/repro"` names
  ## it relative to the recipe: forward slashes, no empty or `.` segment.
  ## `..` is allowed, because a catalog is a separate checkout, normally a
  ## sibling of the profile's repository. An absolute path is refused: the
  ## profile travels between machines (and into `repro home export`), and an
  ## absolute path would name a directory of the machine it was written on.
  if path.len == 0:
    return "the path is empty"
  if '\\' in path:
    return "use forward slashes (`/`), not backslashes"
  if path[0] == '/' or (path.len >= 2 and path[1] == ':'):
    return "the path must be relative to the profile directory"
  for segment in path.split('/'):
    if segment.len == 0:
      return "the path has an empty segment (`//` or a trailing `/`)"
    if segment == ".":
      return "the path has a `.` segment"
  if path.split('/')[^1] == "..":
    return "the path names a directory, not a catalog module"
  ""
