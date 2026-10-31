## Mutable local Nix source cannot supply a reusable evaluation identity.
## The helper's known flake files do not describe its imported read closure;
## retain fresh evaluation until evaluator-owned identities replace this rule.
import std/strutils

proc isMutableLocalNixSelector*(selector: string): bool =
  let value = selector.strip()
  if value in [".", ".."]:
    return true
  for prefix in ["./", "../", ".#", "..#", "/", "path:", "file:", "git+file:"]:
    if value.startsWith(prefix):
      return true

proc requiresFreshNixEvaluation*(selector, expressionFile: string): bool =
  expressionFile.len > 0 or isMutableLocalNixSelector(selector)
