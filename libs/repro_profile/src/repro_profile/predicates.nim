## Predicate combinators for the M83 Phase A profile macro library.
##
## A predicate is a stringly-typed expression that the apply-time
## parser (`libs/repro_home_intent/src/repro_home_intent/predicate.nim`)
## already knows how to canonicalise and evaluate. The job of this
## module is purely AST-building: assemble the predicate at compile
## time as a canonical string and stash it inside a `PredicateExpr`.
##
## The canonicalisation rules mirror the apply-time canonicalize proc:
## sort `and`/`or` operand sets lexicographically by their rendered
## form, drop redundant parens, lowercase standard idents. Tests in
## `tests/t_smoke_repro_profile.nim` pin the exact output (e.g.
## `windows and arm64` -> `arm64 and windows`).

import std/algorithm

import ./types

type
  PredicateValue* = object
    ## A predicate operand that is NOT a boolean expression on its own.
    ## Today the only one is `host`; it surfaces here so users can
    ## write `host == "dev-laptop"` and get a typed `PredicateExpr`
    ## back instead of needing to hand-craft a string.
    ident*: string

# ---------------------------------------------------------------------
# Internal helpers - the rendering layer.
# ---------------------------------------------------------------------

proc isStandardOp(s: string): bool =
  ## Is `s` a top-level `and` / `or` predicate string? Used to decide
  ## whether to wrap with parens when nesting under `not`.
  # Cheap detection: scan for top-level " and " / " or " outside parens.
  var depth = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '(':
      inc depth
    elif c == ')':
      dec depth
    elif depth == 0 and i + 4 < s.len:
      if s[i] == ' ' and s[i + 1] == 'a' and s[i + 2] == 'n' and
         s[i + 3] == 'd' and s[i + 4] == ' ':
        return true
      if s[i] == ' ' and s[i + 1] == 'o' and s[i + 2] == 'r' and
         s[i + 3] == ' ':
        return true
    inc i
  false

proc wrapIfComposite(s: string): string =
  ## Wrap with parens if the rendering contains a top-level `and`/`or`.
  if isStandardOp(s):
    "(" & s & ")"
  else:
    s

proc splitOnTopLevel(s, sep: string): seq[string] =
  ## Split `s` on `sep` at depth-0 paren level. Used to flatten chains
  ## like `a and b and c`.
  result = @[]
  var depth = 0
  var startIdx = 0
  var i = 0
  while i <= s.len - sep.len:
    let c = s[i]
    if c == '(':
      inc depth
      inc i
      continue
    if c == ')':
      dec depth
      inc i
      continue
    if depth == 0 and i + sep.len <= s.len and s[i ..< i + sep.len] == sep:
      result.add s[startIdx ..< i]
      inc i, sep.len
      startIdx = i
      continue
    inc i
  result.add s[startIdx .. ^1]

proc canonicalAnd(parts: seq[string]): string =
  ## Build a canonical `and` chain over already-rendered operands.
  ## Flatten nested `and`s, sort alphabetically, wrap any `or` operand
  ## in parens so the parser still sees `and` as the top-level.
  var flat: seq[string] = @[]
  for p in parts:
    let pieces = splitOnTopLevel(p, " and ")
    for piece in pieces:
      flat.add piece
  flat.sort(cmp[string])
  var wrapped: seq[string] = @[]
  for p in flat:
    if splitOnTopLevel(p, " or ").len > 1:
      wrapped.add "(" & p & ")"
    else:
      wrapped.add p
  result = ""
  for i, w in wrapped:
    if i > 0:
      result.add " and "
    result.add w

proc canonicalOr(parts: seq[string]): string =
  var flat: seq[string] = @[]
  for p in parts:
    let pieces = splitOnTopLevel(p, " or ")
    for piece in pieces:
      flat.add piece
  flat.sort(cmp[string])
  result = ""
  for i, p in flat:
    if i > 0:
      result.add " or "
    result.add p

# ---------------------------------------------------------------------
# Standard set - one template per built-in predicate.
# ---------------------------------------------------------------------

template windows*(): PredicateExpr = PredicateExpr(expr: "windows")
template macos*(): PredicateExpr = PredicateExpr(expr: "macos")
template linux*(): PredicateExpr = PredicateExpr(expr: "linux")
template bsd*(): PredicateExpr = PredicateExpr(expr: "bsd")
template wsl*(): PredicateExpr = PredicateExpr(expr: "wsl")
template x86_64*(): PredicateExpr = PredicateExpr(expr: "x86_64")
template arm64*(): PredicateExpr = PredicateExpr(expr: "arm64")
template arm32*(): PredicateExpr = PredicateExpr(expr: "arm32")
template headless*(): PredicateExpr = PredicateExpr(expr: "headless")

template host*(): PredicateValue =
  ## `host == "name"` / `host in ["a", "b"]` syntax sugar.
  PredicateValue(ident: "host")

# ---------------------------------------------------------------------
# Combinators.
# ---------------------------------------------------------------------

proc combineAnd*(a, b: PredicateExpr): PredicateExpr =
  PredicateExpr(expr: canonicalAnd(@[a.expr, b.expr]))

proc combineOr*(a, b: PredicateExpr): PredicateExpr =
  PredicateExpr(expr: canonicalOr(@[a.expr, b.expr]))

proc combineNot*(a: PredicateExpr): PredicateExpr =
  PredicateExpr(expr: "not " & wrapIfComposite(a.expr))

proc combineEq*(a: PredicateValue, b: string): PredicateExpr =
  PredicateExpr(expr: a.ident & " == \"" & b & "\"")

proc combineNe*(a: PredicateValue, b: string): PredicateExpr =
  PredicateExpr(expr: a.ident & " != \"" & b & "\"")

proc combineIn*(a: PredicateValue, b: seq[string]): PredicateExpr =
  var rhs = "["
  for i, item in b:
    if i > 0:
      rhs.add ", "
    rhs.add "\""
    rhs.add item
    rhs.add "\""
  rhs.add "]"
  PredicateExpr(expr: a.ident & " in " & rhs)

# Operator overloads so users can write idiomatic predicate
# expressions. Implemented as procs because templates would collide
# with the system `and`/`or`/`not` for bools when a PredicateExpr
# expression is misclassified by the typechecker.

proc `and`*(a, b: PredicateExpr): PredicateExpr = combineAnd(a, b)
proc `or`*(a, b: PredicateExpr): PredicateExpr = combineOr(a, b)
proc `not`*(a: PredicateExpr): PredicateExpr = combineNot(a)
proc `==`*(a: PredicateValue, b: string): PredicateExpr = combineEq(a, b)
proc `!=`*(a: PredicateValue, b: string): PredicateExpr = combineNe(a, b)
proc `in`*(a: PredicateValue, b: openArray[string]): PredicateExpr =
  combineIn(a, @b)

# A raw `predicate"<expr>"` escape hatch for hand-written predicate
# strings (e.g. user-defined identifiers that aren't covered by the
# standard set). The string is kept verbatim; the apply-time parser
# will canonicalise it.

proc predicate*(s: string): PredicateExpr =
  PredicateExpr(expr: s)

# ---------------------------------------------------------------------
# Guards: a runtime predicate attached to intent elements.
#
# An activity body carries its guards as a tree (`aekWhenGuard` around a
# list of elements). Resources and config overrides are flat lists, so each
# one carries its own `guard`. Both are evaluated by the planner against the
# target host, never by the compile, which is what lets one compiled profile
# describe every platform (Gradual-Nix-To-Reprobuild-Migration.md §Platform-
# neutral intent). The `profile` macro lowers a runtime `when <pred>:` inside
# `resources:` / `config:` onto `guarded(...)`; helper modules call the same
# helpers directly.
# ---------------------------------------------------------------------

proc conjoinGuard*(outer, inner: PredicateExpr): PredicateExpr =
  ## `outer and inner`, where an empty expression means "always". Nested
  ## guards conjoin, so a resource inside `when linux():` inside
  ## `when arm64():` carries `arm64 and linux`.
  if inner.expr.len == 0:
    outer
  elif outer.expr.len == 0:
    inner
  else:
    combineAnd(outer, inner)

proc guarded*(pred: PredicateExpr;
              elements: openArray[ActivityElement]): ActivityElement =
  ## An activity-body element that enables `elements` only on hosts where
  ## `pred` holds — the helper-proc spelling of `when <pred>:` in an activity
  ## body:
  ##
  ## ```nim
  ## proc secrets*(): seq[ActivityElement] =
  ##   @[package "age",
  ##     guarded(linux(), [package "bitwarden", package "pinentry"])]
  ## ```
  ActivityElement(kind: aekWhenGuard, predicate: pred,
    guardedBody: @elements)

proc applyGuard*(target: var seq[ResourceIntent]; start: int;
                 pred: PredicateExpr) =
  ## Conjoin `pred` into the guard of every resource appended since `start`.
  for i in start ..< target.len:
    target[i].guard = conjoinGuard(pred, target[i].guard)

proc applyGuard*(target: var seq[ConfigOverride]; start: int;
                 pred: PredicateExpr) =
  ## Conjoin `pred` into the guard of every override appended since `start`.
  for i in start ..< target.len:
    target[i].guard = conjoinGuard(pred, target[i].guard)

template guarded*[T: ResourceIntent | ConfigOverride](
    target: var seq[T]; pred: PredicateExpr; body: untyped) =
  ## Guard every resource (or config override) `body` appends to `target`
  ## by `pred`. This is the helper-template spelling of a runtime
  ## `when <pred>:` inside `resources:` / `config:`:
  ##
  ## ```nim
  ## template zshResources*(targetResources: var seq[ResourceIntent]) =
  ##   guarded(targetResources, linux() or macos()):
  ##     shellIntegration(targetResources, hostFile = "~/.zshrc", ...)
  ## ```
  ##
  ## The body runs on every host (it only DECLARES intent); what the guard
  ## changes is where the planner applies the result.
  block:
    let guardStart = target.len
    let guardPred = pred
    body
    applyGuard(target, guardStart, guardPred)
