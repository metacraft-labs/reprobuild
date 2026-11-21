## Mutable local Nix source cannot supply a reusable evaluation identity.
## The helper's known flake files do not describe its imported read closure;
## retain fresh evaluation until evaluator-owned identities replace this rule.
import std/strutils

proc nixSelectorScheme(value: string): string =
  ## The URL scheme of a flake reference, lower-cased, or "" when the
  ## reference has none (a path or a registry name).
  if value.len == 0 or value[0] notin Letters:
    return ""
  for i in 1 ..< value.len:
    let c = value[i]
    if c == ':':
      return value[0 ..< i].toLowerAscii()
    if c notin Letters + Digits + {'+', '.', '-'}:
      return ""
  ""

const
  NixFragmentChars = Letters + Digits +
    {'.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
     ':', '@', '/', '?', ' ', '"', '^', '-'}
    ## Nix's URL fragment characters: RFC 3986 pchar plus `/ ? " ^` and
    ## space (`fragmentRegex` in Nix's url-parts.hh); `%` is allowed only as
    ## the start of a `%HH` escape.
  NixUrlChars = Letters + Digits +
    {'.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
     ':', '@', '/', '?', '#', '%', '^', '-'}
    ## Characters a URL reference may carry without Nix's URL parser
    ## rejecting it and falling back to reading the string as a path.

proc isNixFragment(value: string): bool =
  var i = 0
  while i < value.len:
    if value[i] == '%':
      if i + 2 >= value.len or value[i + 1] notin HexDigits or
          value[i + 2] notin HexDigits:
        return false
      i += 3
    elif value[i] in NixFragmentChars:
      inc i
    else:
      return false
  true

proc isNixRegistryReference(value: string): bool =
  ## Nix's flake-registry reference (`parseFlakeIdRef`): its flake-id regex
  ## `[A-Za-z][A-Za-z0-9_-]*`, an optional `/ref` whose characters may
  ## include `/`, then an optional `#fragment`. There is no `?query`: Nix
  ## reads `id?dir=x#y` as a path.
  let hashAt = value.find('#')
  let base = if hashAt < 0: value else: value[0 ..< hashAt]
  if hashAt >= 0 and not isNixFragment(value[hashAt + 1 .. ^1]):
    return false
  if base.len == 0 or base[0] notin Letters:
    return false
  var i = 1
  while i < base.len and base[i] in Letters + Digits + {'_', '-'}:
    inc i
  if i == base.len:
    return true
  if base[i] != '/' or i + 1 >= base.len or
      base[i + 1] notin Letters + Digits + {'@'}:
    return false
  for c in base[i + 2 .. ^1]:
    if c notin Letters + Digits + {'_', '.', '/', '@', '+', '-'}:
      return false
  true

proc isMutableLocalNixSelector*(selector: string): bool =
  ## Local is decided by where the source is read from, not by a list of
  ## flake types (Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3
  ## item 4). Nix tries each reading of a reference in turn and, when the
  ## registry and URL readings fail, reads it as a path relative to its
  ## working directory (the workspace). So "remote" is decided positively,
  ## from the exact string `nix` receives (nothing is stripped first):
  ## - a reference with no scheme is remote only when the whole string is a
  ##   registry reference (`id`, `id/ref`, `id/ref/rev`, optional
  ##   `#fragment`, no `?query`); `sub/#x`, `sub.d#x`, `id?dir=x#y` and
  ##   ` id#x` are paths;
  ## - a reference with a scheme is local for `path:` and any `file`
  ##   transport (`file:`, `git+file:`, `hg+file:`, `tarball+file:`, ...),
  ##   and for any string Nix's URL parser would reject (whitespace, a
  ##   character outside the URL alphabet, a second `#`).
  ## The helper (tools/reprobuild-nix-daemon) implements the same policy;
  ## tests/fixtures/nix-evaluation-policy.json keeps the two aligned.
  let scheme = nixSelectorScheme(selector)
  if scheme.len == 0:
    return not isNixRegistryReference(selector)
  if scheme in ["path", "file"] or scheme.endsWith("+file"):
    return true
  if selector.count('#') > 1:
    return true
  for c in selector:
    if c notin NixUrlChars:
      return true
  false

proc requiresFreshNixEvaluation*(selector, expressionFile: string): bool =
  expressionFile.len > 0 or isMutableLocalNixSelector(selector)
