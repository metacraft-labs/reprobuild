## Plan-time data-file references (GM4).
##
## A profile's `data:` section names data files beside the profile; the
## profile binary records the names only and the planner reads the files
## (Gradual-Nix-To-Reprobuild-Migration.md §Declarative data files read at
## plan time). This module holds the one rule for what a reference may
## spell, shared by the `profile` macro, the text inspector
## (`repro_home_intent`) and the planner's reader
## (`repro_profile_compile/data_expansion`), so the three cannot accept
## different paths. It depends on `std/strutils` only, so importing it adds
## nothing to the profile compile's closure.

import std/strutils

proc dataFilePathProblem*(path: string): string =
  ## Why `path` cannot name a plan-time data file, or "" when it can. A
  ## data file is named relative to the profile directory with forward
  ## slashes and stays inside it: the planner reads it from there, the
  ## generation's intent snapshot records it under that path, and a Nix
  ## consumer resolves the same string against the same directory
  ## (Gradual-Nix-To-Reprobuild-Migration.md §Declarative data files read
  ## at plan time). Shared by the macro, the text inspector and the
  ## planner so the three accept exactly the same spellings.
  if path.len == 0:
    return "the path is empty"
  if '\\' in path:
    return "use forward slashes (`/`), not backslashes"
  if path[0] == '/' or (path.len >= 2 and path[1] == ':'):
    return "the path must be relative to the profile directory"
  for segment in path.split('/'):
    if segment.len == 0:
      return "the path has an empty segment (`//` or a trailing `/`)"
    if segment == "." or segment == "..":
      return "the path must stay inside the profile directory (no `.` " &
        "or `..` segments)"
  ""
