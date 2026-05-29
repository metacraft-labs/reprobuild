## Profile-shape macros and the activity/config/hosts/resources sub-
## block templates. The user's `home.nim` (or `system.nim`) reads:
##
## ```
## import repro/profile
##
## profile "zahary":
##   activity default:
##     neovim
##     tmux
##     when windows:
##       windows-terminal
##
##   activity develop_software:
##     git
##     gh
##
##   config:
##     git:
##       userName = "Zahary"
##
##   hosts:
##     "dev-laptop": [develop_software]
##
##   resources:
##     fsUserFile(
##       hostFile = "~/.config/foo.conf",
##       content = "...")
## ```
##
## The `profile` macro transforms this into a `main` proc that builds a
## `ProfileIntent` value at runtime and emits it as JSON via
## `emitProfileIntent`. Compile-time evaluation is NOT used in Phase A
## -- the whole structure is built at runtime when `nim c -r home.nim`
## runs the resulting binary. This keeps the macro implementation
## simple and is consistent with how Nim's macros + templates interact
## with the JSON encoder.
##
## Strategy:
## - `profile` is a macro because it needs to inspect the body for
##   `activity name: ...`, `config:`, `hosts:`, `resources:` sub-
##   blocks and rewrite them.
## - The sub-blocks (`activity`, `config`, `hosts`, `resources`) are
##   themselves macros that consume the body and emit Nim statements
##   that append to an in-scope `__profileIntent` builder variable.
## - `when` blocks inside an activity body are parsed by inspecting the
##   `nnkWhenStmt` AST and emitting a `guardedBody` element.
##
## The accumulator is named `__profileIntent` (double-underscore prefix
## reduces accidental shadowing). The `profile` macro declares it as a
## `var` at the top of the generated `main`.

import std/[macros, strutils, tables]

import ./types
import ./predicates
import ./emit

const ProfileIntentVar* = "profileIntentBuilder"
const ActivityBodyVar* = "activityBodyBuilder"

# ---------------------------------------------------------------------
# Activity body parser (compile-time AST -> Nim statements that append
# to the `__activityBody` seq).
# ---------------------------------------------------------------------

proc parseActivityBody(body: NimNode; targetSeq: NimNode): NimNode

proc parseActivityStmt(stmt: NimNode; targetSeq: NimNode): NimNode =
  ## A single statement inside an activity body. The valid shapes are:
  ##   - bare identifier (package reference) -> aekPackageRef
  ##   - quoted string (package reference with non-ident chars)
  ##   - `when <pred>: <body>` (predicate guard) -> aekWhenGuard
  ## Anything else is a compile-error.
  case stmt.kind
  of nnkIdent:
    let pkgName = $stmt
    result = quote do:
      `targetSeq`.add ActivityElement(kind: aekPackageRef,
        pkgName: `pkgName`)
  of nnkAccQuoted:
    # `weird-pkg-name` via backticks.
    var combined = ""
    for child in stmt:
      combined.add $child
    result = quote do:
      `targetSeq`.add ActivityElement(kind: aekPackageRef,
        pkgName: `combined`)
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    let pkgName = stmt.strVal
    result = quote do:
      `targetSeq`.add ActivityElement(kind: aekPackageRef,
        pkgName: `pkgName`)
  of nnkWhenStmt:
    # Single branch only; `elif` / `else` not supported in profile
    # activity bodies per the M83 design.
    if stmt.len != 1 or stmt[0].kind != nnkElifBranch:
      error("activity body `when` must have exactly one branch (no " &
            "`elif` / `else` supported in Phase A)", stmt)
    let branch = stmt[0]
    let predExpr = branch[0]
    let guardBody = branch[1]
    let innerSym = genSym(nskVar, "guardedBody")
    let inner = newNimNode(nnkStmtList)
    inner.add quote do:
      var `innerSym`: seq[ActivityElement] = @[]
    inner.add parseActivityBody(guardBody, innerSym)
    let predSym = genSym(nskLet, "pred")
    inner.add quote do:
      let `predSym` = `predExpr`
      `targetSeq`.add ActivityElement(kind: aekWhenGuard,
        predicate: `predSym`, guardedBody: `innerSym`)
    result = newNimNode(nnkBlockStmt)
    result.add newEmptyNode()
    result.add inner
  of nnkCommentStmt:
    result = newEmptyNode()
  of nnkDiscardStmt:
    result = newEmptyNode()
  else:
    error("unsupported activity body element: " & $stmt.kind &
          " (allowed: bare identifier, string literal, `when` block)",
          stmt)

proc parseActivityBody(body: NimNode; targetSeq: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind == nnkStmtList:
    for stmt in body:
      let parsed = parseActivityStmt(stmt, targetSeq)
      if parsed.kind != nnkEmpty:
        result.add parsed
  else:
    let parsed = parseActivityStmt(body, targetSeq)
    if parsed.kind != nnkEmpty:
      result.add parsed

# ---------------------------------------------------------------------
# Top-level subblock detection.
# ---------------------------------------------------------------------

proc isCallTo(stmt: NimNode; name: string): bool =
  stmt.kind in {nnkCall, nnkCommand} and
    stmt.len >= 1 and stmt[0].kind == nnkIdent and $stmt[0] == name

proc parseConfigSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `config:` body is a list of `<pkg>: <subblock>` entries where the
  ## subblock contains `key = value` assignments.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("config: expects an indented block of per-package overrides",
          body)
  for entry in body:
    if entry.kind != nnkCall or entry.len != 2 or
       entry[1].kind != nnkStmtList:
      error("config entry must be of the form `<pkg>: <key = value, ...>`",
            entry)
    var pkgName: string
    case entry[0].kind
    of nnkIdent: pkgName = $entry[0]
    of nnkStrLit: pkgName = entry[0].strVal
    else:
      error("config package name must be an identifier or string literal",
            entry[0])
    for assignment in entry[1]:
      if assignment.kind != nnkAsgn or assignment.len != 2:
        error("config entry must contain `key = value` assignments",
              assignment)
      var keyName: string
      case assignment[0].kind
      of nnkIdent: keyName = $assignment[0]
      of nnkStrLit: keyName = assignment[0].strVal
      else:
        error("config key must be an identifier or string literal",
              assignment[0])
      let valueExpr = assignment[1]
      let pkgLit = newStrLitNode(pkgName)
      let keyLit = newStrLitNode(keyName)
      result.add quote do:
        block:
          when `valueExpr` is string:
            `profileVar`.configOverrides.add ConfigOverride(
              pkg: `pkgLit`, key: `keyLit`,
              value: ConfigValue(kind: cvkString, s: `valueExpr`))
          elif `valueExpr` is int:
            `profileVar`.configOverrides.add ConfigOverride(
              pkg: `pkgLit`, key: `keyLit`,
              value: ConfigValue(kind: cvkInt, i: `valueExpr`))
          elif `valueExpr` is bool:
            `profileVar`.configOverrides.add ConfigOverride(
              pkg: `pkgLit`, key: `keyLit`,
              value: ConfigValue(kind: cvkBool, b: `valueExpr`))
          else:
            `profileVar`.configOverrides.add ConfigOverride(
              pkg: `pkgLit`, key: `keyLit`,
              value: ConfigValue(kind: cvkExpr, expr: $`valueExpr`))

proc parseHostsSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `hosts:` body is a list of `"hostname": [activity1, activity2]`
  ## entries.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("hosts: expects an indented block of host -> activity-list " &
          "mappings", body)
  for entry in body:
    if entry.kind != nnkCall or entry.len != 2:
      error("hosts entry must be `\"hostname\": [activities]`", entry)
    var hostName: string
    case entry[0].kind
    of nnkStrLit: hostName = entry[0].strVal
    of nnkIdent: hostName = $entry[0]
    else:
      error("hosts entry key must be a string literal or identifier",
            entry[0])
    let listSrc = entry[1]
    var activitySeq: NimNode
    case listSrc.kind
    of nnkStmtList:
      if listSrc.len != 1:
        error("hosts entry body must be a single bracket list", listSrc)
      activitySeq = listSrc[0]
    else:
      activitySeq = listSrc
    if activitySeq.kind notin {nnkBracket, nnkPrefix}:
      error("hosts entry value must be a `[activity1, activity2]` " &
            "bracket list", activitySeq)
    var actNames: seq[string] = @[]
    let actNode = if activitySeq.kind == nnkPrefix and activitySeq.len == 2 and
                       activitySeq[1].kind == nnkBracket: activitySeq[1]
                  else: activitySeq
    for item in actNode:
      case item.kind
      of nnkIdent: actNames.add $item
      of nnkStrLit: actNames.add item.strVal
      else:
        error("hosts activity list entry must be an identifier or " &
              "string literal", item)
    let hostLit = newStrLitNode(hostName)
    var addCalls = newNimNode(nnkStmtList)
    let tmpSym = genSym(nskVar, "hostActs")
    addCalls.add quote do:
      var `tmpSym`: seq[string] = @[]
    for a in actNames:
      let aLit = newStrLitNode(a)
      addCalls.add quote do:
        `tmpSym`.add `aLit`
    addCalls.add quote do:
      `profileVar`.hosts[`hostLit`] = `tmpSym`
    let blk = newNimNode(nnkBlockStmt)
    blk.add newEmptyNode()
    blk.add addCalls
    result.add blk

proc parseResourcesSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `resources:` body is a list of resource-constructor calls. Each
  ## call must be one of the resource constructor templates declared
  ## in `./resources.nim` or a user-authored template that takes a
  ## `targetResources` final parameter. The macro rewrites each call
  ## to pass the in-scope profile's `resources` seq through.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("resources: expects an indented block of resource " &
          "constructor calls", body)
  for stmt in body:
    case stmt.kind
    of nnkCall, nnkCommand:
      # Build `<callee>(profileVar.resources, <stmt's original args>)`
      # -- target seq goes first positional. Templates in
      # `./resources.nim` take it as their leading param. User-authored
      # modules follow the same convention.
      var newCall = newNimNode(nnkCall)
      newCall.add stmt[0]
      var dotExpr = newNimNode(nnkDotExpr)
      dotExpr.add profileVar
      dotExpr.add newIdentNode("resources")
      newCall.add dotExpr
      for i in 1 ..< stmt.len:
        newCall.add stmt[i]
      result.add newCall
    of nnkCommentStmt:
      discard
    else:
      error("resources: block expects constructor calls (e.g. " &
            "`fsUserFile(...)`); got " & $stmt.kind, stmt)

proc parseActivityCall(call: NimNode; profileVar: NimNode): NimNode =
  ## A top-level `activity name: body` form. Emit an
  ## ActivityIntent into __profileIntent.activities.
  if call.len != 3:
    error("activity must be `activity <name>: <body>`", call)
  var actName: string
  case call[1].kind
  of nnkIdent: actName = $call[1]
  of nnkStrLit: actName = call[1].strVal
  else:
    error("activity name must be an identifier or string literal", call[1])
  let body = call[2]
  let bodySym = genSym(nskVar, "actBody")
  let nameLit = newStrLitNode(actName)
  let inner = newNimNode(nnkStmtList)
  inner.add quote do:
    var `bodySym`: seq[ActivityElement] = @[]
  inner.add parseActivityBody(body, bodySym)
  inner.add quote do:
    `profileVar`.activities.add ActivityIntent(name: `nameLit`,
      body: `bodySym`)
  result = newNimNode(nnkBlockStmt)
  result.add newEmptyNode()
  result.add inner

# ---------------------------------------------------------------------
# The top-level `profile` macro.
# ---------------------------------------------------------------------

macro profile*(name: static[string]; body: untyped): untyped =
  ## Top-level wrapper. Body contains a mix of `activity`, `config`,
  ## `hosts`, and `resources` sub-blocks. Builds a ProfileIntent
  ## value at runtime + emits it via `emitProfileIntent`.
  let profSym = genSym(nskVar, ProfileIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `profSym`: ProfileIntent
    `profSym`.name = `name`

  if body.kind != nnkStmtList:
    error("profile body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCommand:
      if stmt[0].kind == nnkIdent and $stmt[0] == "activity":
        stmts.add parseActivityCall(stmt, profSym)
      else:
        error("unrecognised profile body form: " & $stmt[0], stmt)
    of nnkCall:
      let head = stmt[0]
      if head.kind == nnkIdent:
        case $head
        of "activity":
          stmts.add parseActivityCall(stmt, profSym)
        of "config":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("config must be `config: <body>`", stmt)
          stmts.add parseConfigSection(stmt[1], profSym)
        of "hosts":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("hosts must be `hosts: <body>`", stmt)
          stmts.add parseHostsSection(stmt[1], profSym)
        of "resources":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("resources must be `resources: <body>`", stmt)
          stmts.add parseResourcesSection(stmt[1], profSym)
        else:
          error("unrecognised profile body form: " & $head, stmt)
      else:
        error("unrecognised profile body form", stmt)
    of nnkCommentStmt:
      discard
    else:
      error("unrecognised profile body form: " & $stmt.kind, stmt)

  # Trailing emit. `quit 0` inside emitProfileIntent so control
  # never returns.
  stmts.add quote do:
    emitProfileIntent(`profSym`)

  # Wrap the whole thing in a `proc main()` so the macro doesn't
  # pollute the user's module scope.
  let mainSym = ident("main")
  result = newNimNode(nnkStmtList)
  result.add quote do:
    proc `mainSym`() =
      `stmts`
  result.add quote do:
    when isMainModule:
      `mainSym`()
