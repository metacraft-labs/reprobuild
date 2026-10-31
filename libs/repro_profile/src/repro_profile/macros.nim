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
## - `when` chains inside `resources:` and `config:` become runtime guards
##   on the resources / overrides they declare when their conditions are
##   predicates (`when linux():`), and stay Nim compile-time branches when
##   they are `defined(...)` conditions (`lowerWhenChain`).
## - A `resources:` block directly inside `activity <name>:` (GM9) declares
##   resources that belong to that activity: the planner plans them only on
##   hosts that select it (`parseActivityResources`).
## - A `stow:` block directly inside `activity <name>:` (GM11) names the
##   `stow/` packages that belong to that activity: the planner materializes
##   them only on hosts that select it (`parseActivityStow`,
##   `repro_profile/stow_scopes`).
## - `data:` lists plan-time data files (GM4). The macro records the
##   paths only; the planner reads and expands the files, so a data edit
##   never recompiles the profile.
## - `catalogs:` lists the provisioning-contribution catalogs the profile
##   imports, as Nim module paths relative to the profile directory. The
##   macro records the paths only; `repro home apply` imports them where it
##   resolves the profile's package references.
## - The intent is built by a proc of its own, so the platform probe can
##   evaluate it at compile time for other platforms (see the end of the
##   `profile` macro).
##
## The accumulator is named `__profileIntent` (double-underscore prefix
## reduces accidental shadowing). The `profile` macro declares it as a
## `var` at the top of the generated `main`.

import std/[macros, sequtils, strutils, tables]

import ./types
import ./predicates
import ./emit
import ./data_refs
import ./catalog_refs
import ./concerns
import ./host_system
import ./stow_scopes

const ProfileIntentVar* = "profileIntentBuilder"
const ActivityBodyVar* = "activityBodyBuilder"

# ---------------------------------------------------------------------
# Activity body parser (compile-time AST -> Nim statements that append
# to the `__activityBody` seq).
# ---------------------------------------------------------------------

proc parseActivityBody(body: NimNode; targetSeq: NimNode): NimNode

proc isActivityResourcesBlock(stmt: NimNode): bool =
  ## `resources: <body>` -- the GM9 activity-scoped resources block.
  stmt.kind == nnkCall and stmt.len == 2 and stmt[0].kind == nnkIdent and
    $stmt[0] == "resources" and stmt[1].kind == nnkStmtList

proc isActivityStowBlock(stmt: NimNode): bool =
  ## `stow: <body>` -- the GM11 block naming the `stow/` packages that
  ## belong to the activity (`repro_profile/stow_scopes`).
  stmt.kind == nnkCall and stmt.len == 2 and stmt[0].kind == nnkIdent and
    $stmt[0] == StowBlockKeyword and stmt[1].kind == nnkStmtList

proc parseActivityStmt(stmt: NimNode; targetSeq: NimNode): NimNode =
  ## A single statement inside an activity body. The valid shapes are:
  ##   - bare identifier (package reference) -> aekPackageRef
  ##   - quoted string (package reference with non-ident chars)
  ##   - `when <pred>: <body>` (predicate guard) -> aekWhenGuard
  ##   - a call statement `helper(args...)` — the M83 Phase F1
  ##     "splat" convention. The call must return `seq[ActivityElement]`;
  ##     the macro emits a `for elem in helper(args...): targetSeq.add
  ##     elem` loop so a user-authored sibling-module template that
  ##     bundles package references composes cleanly into the activity.
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
  of nnkCall, nnkCommand:
    # GM9: `resources:` belongs at the top of an activity body, where
    # `parseActivityCall` handles it. Here it would be under a `when` of the
    # body (or otherwise misplaced): refuse it rather than read it as a
    # helper call. Guard the resources themselves inside the block instead.
    if isActivityResourcesBlock(stmt):
      error("an activity's `resources:` block must sit directly in the " &
        "activity body, not under a `when`; put the `when <predicate>:` " &
        "inside the `resources:` block", stmt)
    # GM11: the same for a `stow:` block.
    if isActivityStowBlock(stmt):
      error("an activity's `stow:` block must sit directly in the " &
        "activity body, not under a `when`; put the `when <predicate>:` " &
        "inside the `stow:` block", stmt)
    # M69: recognize the `package(<id>[, "<version>"])` call form and
    # emit a typed `aekPackageRef` with the version literal pinned.
    # The bare-arg call `package(<id>)` records `pkgVersion = ""`. The
    # call is detected by callee identifier + 1-or-2-arg arity; the
    # version argument MUST be a string literal at compile time (the
    # intent layer records concrete versions, never expressions).
    if stmt.len >= 2 and stmt[0].kind == nnkIdent and $stmt[0] == "package" and
       (stmt[1].kind notin {nnkStmtList}):
      # Accepted forms:
      #   package(<id>)
      #   package(<id>, "<version>")
      #   package(<id>, binaries = @["a", "b"])
      #   package(<id>, "<version>", binaries = @["a", "b"])
      var pkgName = ""
      case stmt[1].kind
      of nnkIdent: pkgName = $stmt[1]
      of nnkAccQuoted:
        for child in stmt[1]: pkgName.add $child
      of nnkStrLit, nnkRStrLit, nnkTripleStrLit: pkgName = stmt[1].strVal
      else:
        error("`package(<id>, ...)` id argument must be an identifier " &
              "or string literal, got " & $stmt[1].kind, stmt[1])
      var version = ""
      var binariesNode = newNimNode(nnkBracket) # default: empty seq[string]
      for i in 2 ..< stmt.len:
        let arg = stmt[i]
        if arg.kind == nnkExprEqExpr:
          # Named arg. Only `binaries = @[...]` is recognised.
          if arg[0].kind != nnkIdent or $arg[0] != "binaries":
            error("`package(...)` named argument must be `binaries = " &
                  "@[\"<name>\", ...]`, got `" & repr(arg) & "`", arg)
          let valNode = arg[1]
          # Accept `@[\"a\", \"b\"]` (Prefix '@' over Bracket) or just
          # `[\"a\", \"b\"]` (raw Bracket); harvest the literals.
          var bracketNode: NimNode = nil
          if valNode.kind == nnkPrefix and valNode.len == 2 and
             valNode[0].kind == nnkIdent and $valNode[0] == "@" and
             valNode[1].kind == nnkBracket:
            bracketNode = valNode[1]
          elif valNode.kind == nnkBracket:
            bracketNode = valNode
          else:
            error("`package(<id>, binaries = ...)` value must be an array " &
                  "literal of string literals (e.g. `@[\"rg\"]`); got " &
                  $valNode.kind, valNode)
          binariesNode = newNimNode(nnkBracket)
          for child in bracketNode:
            case child.kind
            of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
              binariesNode.add newStrLitNode(child.strVal)
            else:
              error("`package(<id>, binaries = @[...])` entries must be " &
                    "string literals; got " & $child.kind, child)
        else:
          # Positional version argument. Must be a string literal.
          if version.len > 0:
            error("`package(...)` takes at most one positional version " &
                  "argument", arg)
          case arg.kind
          of nnkStrLit, nnkRStrLit, nnkTripleStrLit: version = arg.strVal
          else:
            error("`package(<id>, \"<version>\")` version argument must be " &
                  "a string literal (the intent layer records concrete " &
                  "versions; expressions are not allowed); got " &
                  $arg.kind, arg)
          if version.len == 0:
            error("`package(<id>, \"\")` empty version literal; pass " &
                  "`package(<id>)` for a bare reference", arg)
      # Emit: `targetSeq.add ActivityElement(kind: aekPackageRef,
      #   pkgName: <name>, pkgVersion: <version>, pkgBinaries: @[<binaries>])`
      let binariesSeq = newNimNode(nnkPrefix)
      binariesSeq.add newIdentNode("@")
      binariesSeq.add binariesNode
      result = quote do:
        `targetSeq`.add ActivityElement(kind: aekPackageRef,
          pkgName: `pkgName`, pkgVersion: `version`,
          pkgBinaries: `binariesSeq`)
    else:
      # Splat: user-authored helper that returns seq[ActivityElement].
      # The macro emits `for elem in <call>: targetSeq.add elem` so the
      # helper's contributions inline into the activity body.
      let elemSym = genSym(nskForVar, "actElem")
      let forStmt = newNimNode(nnkForStmt)
      forStmt.add elemSym
      forStmt.add stmt
      let addCall = newCall(newDotExpr(targetSeq, ident"add"), elemSym)
      forStmt.add newStmtList(addCall)
      result = forStmt
  of nnkCommentStmt:
    result = newEmptyNode()
  of nnkDiscardStmt:
    result = newEmptyNode()
  else:
    error("unsupported activity body element: " & $stmt.kind &
          " (allowed: bare identifier, string literal, `when` block, " &
          "or a helper call returning seq[ActivityElement])",
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

# ---------------------------------------------------------------------
# `when` chains inside `resources:` and `config:`.
#
# A `when` there is either a RUNTIME guard (`when linux():`,
# `when macos() or windows():`) or a Nim COMPILE-TIME branch
# (`when defined(windows):`). The macro sees untyped AST, so it cannot tell
# the two apart itself; it emits both lowerings behind a `when` on the
# conditions' TYPES and lets the compiler pick:
#
#   * every condition a `PredicateExpr` -> runtime guards. Each branch's
#     body runs on every host and its entries carry the branch's predicate
#     (`guarded(...)`); an `elif` / `else` branch carries the negation of
#     every earlier condition, so exactly one branch applies on any host.
#     The planner evaluates the guards against the target host, and an
#     export carries them as data.
#   * every condition a `bool` -> the ordinary Nim `when`, rewritten in
#     place. The unreached branches are elided by the compiler, so the
#     intent depends on the platform that compiled it; `repro home export`
#     detects that (the platform probe) and refuses to describe another
#     platform with it.
#   * a mix -> a compile error: a chain cannot be half compile-time.
# ---------------------------------------------------------------------

type
  WhenBranch = tuple[cond: NimNode, body: NimNode]
    ## One branch of a `when` chain; `cond` is nil for `else`.

proc whenBranches(stmt: NimNode; section: string): seq[WhenBranch] =
  for branch in stmt:
    case branch.kind
    of nnkElifBranch, nnkElifExpr:
      result.add (cond: branch[0], body: branch[1])
    of nnkElse, nnkElseExpr:
      result.add (cond: NimNode(nil), body: branch[0])
    else:
      error(section & ": unsupported `when` branch shape " & $branch.kind,
        branch)

proc conditionsAre(branches: seq[WhenBranch]; typeName: string): NimNode =
  ## `typeof(c1) is <typeName> and typeof(c2) is <typeName> ...` over the
  ## chain's conditions. `typeof` does not evaluate its argument.
  result = nil
  for b in branches:
    if b.cond.isNil:
      continue
    let test = infix(newCall(ident"typeof", copyNimTree(b.cond)), "is",
      ident(typeName))
    result = if result.isNil: test else: infix(result, "and", test)
  if result.isNil:
    result = ident"false"

proc lowerWhenChain(stmt: NimNode; section: string; target: NimNode;
                    rewrite: proc (body: NimNode): NimNode;
                    runtimeRewrite: proc (body: NimNode): NimNode = nil):
    NimNode =
  ## Lower a `when` chain inside `section` whose entries land in `target`
  ## (`profileVar.resources` / `profileVar.configOverrides`). `rewrite`
  ## rewrites one branch body the way the section rewrites its statements;
  ## `runtimeRewrite`, when given, replaces it for the runtime-guard
  ## lowering (the resources section uses it to refuse action edges, which
  ## carry no guard, under a runtime predicate).
  let runtimeBody = if runtimeRewrite.isNil: rewrite else: runtimeRewrite
  let branches = whenBranches(stmt, section)
  # Runtime lowering: one `guarded` block per branch, each with the
  # branch's condition conjoined with the negation of every earlier one.
  let runtime = newStmtList()
  var earlier: seq[NimNode] = @[]
  for b in branches:
    var effective: NimNode
    var condSym: NimNode = nil
    if b.cond.isNil:
      effective = newCall(ident"predicate", newStrLitNode(""))
    else:
      condSym = genSym(nskLet, "guardCond")
      runtime.add newLetStmt(condSym, copyNimTree(b.cond))
      effective = condSym
    for prior in earlier:
      effective = newCall(ident"conjoinGuard", effective,
        newCall(ident"combineNot", prior))
    if not condSym.isNil:
      earlier.add condSym
    # Each lowering gets its own copy of the body: the two trees must not
    # share nodes, since the compiler annotates the one it type-checks.
    runtime.add newCall(ident"guarded", target, effective,
      runtimeBody(copyNimTree(b.body)))
  let runtimeBlock = newNimNode(nnkBlockStmt).add(newEmptyNode(), runtime)
  # Compile-time lowering: the same `when`, bodies rewritten in place.
  let compileTime = newNimNode(nnkWhenStmt)
  for b in branches:
    if b.cond.isNil:
      compileTime.add newNimNode(nnkElse).add(rewrite(copyNimTree(b.body)))
    else:
      compileTime.add newNimNode(nnkElifBranch).add(copyNimTree(b.cond),
        rewrite(copyNimTree(b.body)))
  let mixed = section & ": a `when` chain mixes runtime predicates " &
    "(`linux()`, `host() == \"x\"`, ...) with compile-time conditions " &
    "(`defined(...)`); use one kind per chain"
  result = newNimNode(nnkWhenStmt)
  result.add newNimNode(nnkElifBranch).add(
    conditionsAre(branches, "PredicateExpr"), runtimeBlock)
  result.add newNimNode(nnkElifBranch).add(
    conditionsAre(branches, "bool"), compileTime)
  result.add newNimNode(nnkElse).add(newStmtList(
    newNimNode(nnkPragma).add(newColonExpr(ident"error",
      newStrLitNode(mixed)))))

proc rewriteConfigAssignments(pkgName: string; body: NimNode;
                              profileVar: NimNode): NimNode

proc rewriteConfigAssignment(pkgName: string; assignment: NimNode;
                             profileVar: NimNode): NimNode =
  ## One statement inside a `<pkg>:` sub-block of `config:`: a
  ## `key = value` assignment, or a `when` chain of assignments.
  case assignment.kind
  of nnkWhenStmt:
    let target = newDotExpr(profileVar, ident"configOverrides")
    return lowerWhenChain(assignment, "config", target,
      proc (b: NimNode): NimNode =
        rewriteConfigAssignments(pkgName, b, profileVar))
  of nnkCommentStmt, nnkDiscardStmt:
    return newEmptyNode()
  else:
    discard
  if assignment.kind != nnkAsgn or assignment.len != 2:
    error("config entry must contain `key = value` assignments (optionally " &
          "inside `when <predicate>:`)", assignment)
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
  result = quote do:
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

proc rewriteConfigAssignments(pkgName: string; body: NimNode;
                              profileVar: NimNode): NimNode =
  result = newStmtList()
  let stmts = if body.kind == nnkStmtList: toSeq(body.children) else: @[body]
  for assignment in stmts:
    let rewritten = rewriteConfigAssignment(pkgName, assignment, profileVar)
    if rewritten.kind != nnkEmpty:
      result.add rewritten

proc rewriteConfigBody(body: NimNode; profileVar: NimNode): NimNode

proc rewriteConfigStmt(entry: NimNode; profileVar: NimNode): NimNode =
  ## One statement directly inside `config:`: a `<pkg>: <assignments>`
  ## block, a helper call contributing overrides, a `when` chain of either,
  ## or a `for` loop over them.
  case entry.kind
  of nnkWhenStmt:
    let target = newDotExpr(profileVar, ident"configOverrides")
    return lowerWhenChain(entry, "config", target,
      proc (b: NimNode): NimNode = rewriteConfigBody(b, profileVar))
  of nnkForStmt:
    result = copyNimTree(entry)
    result[^1] = rewriteConfigBody(entry[^1], profileVar)
    return
  of nnkCommentStmt, nnkDiscardStmt:
    return newEmptyNode()
  else:
    discard
  # Helper-call shape: `helper(arg = ..., arg = ...)` — no trailing
  # block. The `nnkStmtList` second-child shape is what distinguishes
  # the per-pkg form from the helper-call form.
  if entry.kind in {nnkCall, nnkCommand} and
     (entry.len < 2 or entry[^1].kind != nnkStmtList):
    var newCall = newNimNode(nnkCall)
    newCall.add entry[0]
    var dotExpr = newNimNode(nnkDotExpr)
    dotExpr.add profileVar
    dotExpr.add newIdentNode("configOverrides")
    newCall.add dotExpr
    for i in 1 ..< entry.len:
      newCall.add entry[i]
    return newCall
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
  result = rewriteConfigAssignments(pkgName, entry[1], profileVar)

proc rewriteConfigBody(body: NimNode; profileVar: NimNode): NimNode =
  result = newStmtList()
  let stmts = if body.kind == nnkStmtList: toSeq(body.children) else: @[body]
  for entry in stmts:
    let rewritten = rewriteConfigStmt(entry, profileVar)
    if rewritten.kind != nnkEmpty:
      result.add rewritten

proc parseConfigSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `config:` body is a list of `<pkg>: <subblock>` entries where the
  ## subblock contains `key = value` assignments, OR a helper-call
  ## statement (M83 Phase F1 convention) that contributes config
  ## overrides via a user-authored sibling-module template. The helper
  ## is invoked as `helper(profileVar.configOverrides, args...)` —
  ## matching the resource-constructor convention — so the helper's
  ## body can append `ConfigOverride` records directly to the in-scope
  ## list.
  ##
  ## GM3: a `when <predicate>:` chain may wrap package blocks / helper
  ## calls, or assignments inside a package block; the overrides it
  ## declares carry the predicate as their `guard` (see `lowerWhenChain`).
  ## A `for` loop over entries is accepted too.
  if body.kind != nnkStmtList:
    error("config: expects an indented block of per-package overrides",
          body)
  result = rewriteConfigBody(body, profileVar)

proc hostsNameList(listSrc: NimNode; what: string): seq[string] =
  ## A `[a, b]` list of identifiers / string literals, as written after a
  ## host name or after `activities:` / `applies:`. `what` names the list in
  ## the diagnostics.
  var listNode: NimNode
  case listSrc.kind
  of nnkStmtList:
    if listSrc.len != 1:
      error("hosts " & what & " must be a single bracket list", listSrc)
    listNode = listSrc[0]
  else:
    listNode = listSrc
  if listNode.kind notin {nnkBracket, nnkPrefix}:
    error("hosts " & what & " must be a `[name1, name2]` bracket list",
          listNode)
  let items = if listNode.kind == nnkPrefix and listNode.len == 2 and
                   listNode[1].kind == nnkBracket: listNode[1]
              else: listNode
  if items.kind != nnkBracket:
    error("hosts " & what & " must be a `[name1, name2]` bracket list",
          listNode)
  for item in items:
    case item.kind
    of nnkIdent: result.add $item
    of nnkStrLit: result.add item.strVal
    else:
      error("hosts " & what & " entry must be an identifier or string " &
            "literal", item)

proc isHostsBlockForm(value: NimNode): bool =
  ## Whether a host entry's value is the block form (`activities:` /
  ## `applies:` lines) rather than the one-line `[activities]` list.
  value.kind == nnkStmtList and value.len > 0 and
    value[0].kind in {nnkCall, nnkCommand} and value[0].len == 2 and
    value[0][0].kind == nnkIdent

proc systemBlockPairs(v: NimNode): seq[(string, NimNode)] =
  ## The `key: value` pairs of a block-form `system:` value, written either
  ## indented under `system:` (a statement list of `key: value` calls) or
  ## inline as `{key: value, ...}` (a table constructor). Empty when `v` is
  ## neither shape.
  case v.kind
  of nnkStmtList:
    for item in v:
      if item.kind notin {nnkCall, nnkCommand} or item.len != 2 or
          item[0].kind != nnkIdent:
        return @[]
      var value = item[1]
      if value.kind == nnkStmtList and value.len == 1:
        value = value[0]
      result.add ($item[0], value)
  of nnkTableConstr:
    for item in v:
      if item.kind != nnkExprColonExpr or item[0].kind != nnkIdent:
        return @[]
      result.add ($item[0], item[1])
  else:
    discard

proc parseHostSystemBlock(pairs: seq[(string, NimNode)]; where: NimNode;
                          hostName: string): HostSystemDecl =
  ## The block form `mode: addOn` + `activities: [...]`. Every refusal is a
  ## compile error naming the host, worded by `host_system` so the text
  ## parser refuses the same shapes the same way.
  var mode = ""
  var hasActivities = false
  var activities: seq[string]
  var seen: seq[string]
  for (key, value) in pairs:
    if key in seen:
      error("hosts entry \"" & hostName & "\": system: `" & key &
            ":` is given twice", value)
    seen.add key
    case key
    of SystemModeKey:
      if value.kind != nnkIdent:
        error("hosts entry \"" & hostName & "\": system: `" & SystemModeKey &
              ":` takes an identifier (`" & AddOnKeyword & "` or `" &
              FullKeyword & "`)", value)
      mode = $value
    of SystemActivitiesKey:
      hasActivities = true
      activities = hostsNameList(value, "entry `system: activities:`")
    else:
      error("hosts entry \"" & hostName & "\": system: unknown key `" & key &
            ":` (expected `" & SystemModeKey & ":` and `" &
            SystemActivitiesKey & ":`)", value)
  let problem = systemBlockProblem(mode, hasActivities, activities)
  if problem.len > 0:
    error("hosts entry \"" & hostName & "\": system: " & problem, where)
  HostSystemDecl(mode: (if mode == FullKeyword: hsmFull else: hsmAddOn),
    activities: activities)

proc parseHostSystemValue(value: NimNode; hostName: string): HostSystemDecl =
  ## The value of a block-form host entry's `system:` key:
  ## `managedElsewhere`, `managedElsewhere("<pointer>")`, `addOn`, `full`,
  ## or the block form `mode: addOn | full` + `activities: [...]` (indented,
  ## or inline as `{mode: addOn, activities: [...]}`). Anything else is a compile error
  ## naming the host.
  var v = value
  if v.kind == nnkStmtList and v.len == 1:
    v = v[0]
  # The inline block form is a table constructor (`{...}`); the indented one
  # is the statement list under `system:`.
  let pairs = systemBlockPairs(if v.kind == nnkTableConstr: v else: value)
  if pairs.len > 0 and pairs[0][0] in [SystemModeKey, SystemActivitiesKey]:
    return parseHostSystemBlock(pairs, value, hostName)
  let expected = "`system: " & ManagedElsewhereKeyword & "`, `system: " &
    ManagedElsewhereKeyword & "(\"<managing repository>\")`, `system: " &
    AddOnKeyword & "`, `system: " & FullKeyword & "` or the block form " &
    "`system: {" & SystemModeKey & ": " & AddOnKeyword & " | " & FullKeyword &
    ", " & SystemActivitiesKey & ": [...]}`"
  if v.kind == nnkIdent and $v == AddOnKeyword:
    return HostSystemDecl(mode: hsmAddOn)
  if v.kind == nnkIdent and $v == FullKeyword:
    return HostSystemDecl(mode: hsmFull)
  if v.kind == nnkIdent and $v == ManagedElsewhereKeyword:
    return HostSystemDecl(mode: hsmManagedElsewhere)
  if v.kind in {nnkCall, nnkCommand} and v.len == 2 and
      v[0].kind == nnkIdent and $v[0] == ManagedElsewhereKeyword:
    # A plain string literal only: the text parser behind `repro home list`
    # / `add` (`repro_home_intent/parser`) reads the same entry, and it reads
    # "..." strings.
    if v[1].kind != nnkStrLit:
      error("hosts entry \"" & hostName & "\": the " &
            ManagedElsewhereKeyword & " pointer must be a string literal " &
            "naming what manages the system (expected " & expected & ")", v[1])
    let problem = systemPointerProblem(v[1].strVal)
    if problem.len > 0:
      error("hosts entry \"" & hostName & "\": system: " & problem, v[1])
    return HostSystemDecl(mode: hsmManagedElsewhere, managedBy: v[1].strVal)
  error("hosts entry \"" & hostName & "\": unknown `system:` value " &
        "`" & v.repr & "` (expected " & expected & ")", v)

proc parseHostsSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `hosts:` body is a list of host entries, each either
  ##
  ##   "hostname": [activity1, activity2]
  ##
  ## or the block form, which can also say which concerns Reprobuild applies
  ## on the host (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped
  ## apply):
  ##
  ##   "hostname":
  ##     activities: [activity1, activity2]   # omitted: `default` only
  ##     applies: [applications]              # omitted: every concern
  ##     system: managedElsewhere("org/infra") # omitted: managed here
  ##
  ## `system:` (`repro_profile/host_system`) says the host's system scope is
  ## managed elsewhere (optionally naming what manages it), or managed here
  ## in add-on mode: `system: addOn`, or the block form
  ## `system: {mode: addOn, activities: [...]}` selecting system activities.
  ##
  ## An unknown key, a repeated key, an unknown concern, a concern named
  ## twice and a malformed `system:` value are compile errors naming the
  ## host.
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
    var actNames: seq[string] = @[]
    var applies: seq[string] = @[]
    var hasApplies = false
    var hasSystem = false
    var systemDecl: HostSystemDecl
    let value = entry[1]
    if isHostsBlockForm(value):
      var seenKeys: seq[string] = @[]
      for item in value:
        if item.kind notin {nnkCall, nnkCommand} or item.len != 2 or
            item[0].kind != nnkIdent:
          error("hosts entry \"" & hostName & "\": expected " &
                "`activities: [...]`, `applies: [...]` or `system: ...`", item)
        let key = $item[0]
        if key in seenKeys:
          error("hosts entry \"" & hostName & "\": `" & key &
                ":` is given twice", item)
        seenKeys.add key
        case key
        of "activities":
          actNames = hostsNameList(item[1], "entry `activities:`")
        of "applies":
          hasApplies = true
          applies = hostsNameList(item[1], "entry `applies:`")
          let problem = concernListProblem(applies)
          if problem.len > 0:
            error("hosts entry \"" & hostName & "\": applies: " & problem,
                  item)
        of HostSystemKey:
          hasSystem = true
          systemDecl = parseHostSystemValue(item[1], hostName)
        else:
          error("hosts entry \"" & hostName & "\": unknown key `" & key &
                ":` (expected `activities:`, `applies:` or `system:`)", item)
    else:
      actNames = hostsNameList(value, "entry value")
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
    if hasApplies:
      let appliesSym = genSym(nskVar, "hostApplies")
      addCalls.add quote do:
        var `appliesSym`: seq[string] = @[]
      for c in applies:
        let cLit = newStrLitNode(c)
        addCalls.add quote do:
          `appliesSym`.add `cLit`
      addCalls.add quote do:
        `profileVar`.hostApplies[`hostLit`] = `appliesSym`
    if hasSystem:
      let modeLit = newLit(systemDecl.mode)
      let pointerLit = newStrLitNode(systemDecl.managedBy)
      var actsLit = newNimNode(nnkBracket)
      for a in systemDecl.activities:
        actsLit.add newStrLitNode(a)
      # `@[]` cannot type itself; an empty list is spelled with its type.
      var actsExpr: NimNode
      if actsLit.len == 0:
        actsExpr = newCall(newTree(nnkBracketExpr, ident"newSeq", ident"string"))
      else:
        actsExpr = prefix(actsLit, "@")
      addCalls.add quote do:
        `profileVar`.hostSystems[`hostLit`] = HostSystemDecl(mode: `modeLit`,
          managedBy: `pointerLit`, activities: `actsExpr`)
    let blk = newNimNode(nnkBlockStmt)
    blk.add newEmptyNode()
    blk.add addCalls
    result.add blk

## Windows-System-Resources Phase G: closed allow-list of typed-tool
## names whose ``.build(...)`` call is treated as a profile-scope
## action edge (instead of a live-state resource template). Each name
## here must be a typed-tool that exists in ``repro_dsl_stdlib`` and
## whose ``build`` proc returns a ``BuildActionDef`` whose ``call`` is
## an ``inlineExecCall(argv)`` — that is the only shape
## ``addProfileBuildAction`` accepts.
##
## Why a closed allow-list and not pattern-matching every ``<x>.build``
## call? Many existing typed tools (``gcc.build``, ``meson.build``, ...)
## return ``BuildActionDef`` from a SUBCOMMAND ``call`` shape (not
## ``inlineExecCall``); their result is meant to land in a ``build:``
## block consumed by the build-graph compiler, NOT inside a profile
## ``resources:`` block. Accepting every ``<x>.build`` call would
## silently swallow misplaced typed-tool calls and surface as a runtime
## ``ValueError`` from ``addProfileBuildAction`` instead of a clear
## compile-time diagnostic. The allow-list pins exactly the typed
## tools the Windows-System-Resources spec § 2.3 enumerates; new
## profile-scope typed tools (a hypothetical ``windowsInstallMsi``,
## ``zypperInstall``, ...) extend this list.
const ProfileActionEdgeTypedTools* = ["expandArchive"]

const ProfileActionEdgeBareCalls* = ["inlineExecCall"]
  ## Bare-ident action-edge calls (no typed-tool dot prefix). The
  ## spec calls out ``inlineExecCall(...)`` as the escape hatch for
  ## actions a typed tool doesn't yet cover (running a registration
  ## script, invoking an installer's silent-mode binary, ...). The
  ## macro recognises the bare ident and routes the call through
  ## ``buildAction(... call = inlineExecCall(argv), ...)`` so the
  ## resulting ``BuildActionDef`` lands in ``addProfileBuildAction``
  ## with the same code path the typed-tool calls take.

proc isProfileActionEdgeCall*(stmt: NimNode): bool =
  ## True when ``stmt`` is a call shape the profile macro treats as an
  ## action edge (build-graph item) rather than a live-state resource.
  ## Pure / no AST mutation — the caller (``rewriteResourcesStmt``)
  ## branches on this predicate.
  ##
  ## Recognised shapes (closed set):
  ##   * ``<ident>.build(...)`` where ``<ident>`` is in
  ##     ``ProfileActionEdgeTypedTools`` — a typed-tool action edge.
  ##   * ``<ident>(...)`` where ``<ident>`` is in
  ##     ``ProfileActionEdgeBareCalls`` — a bare ``inlineExecCall``
  ##     call (or other Phase-G-approved bare action-edge call).
  if stmt.kind notin {nnkCall, nnkCommand}:
    return false
  let head = stmt[0]
  case head.kind
  of nnkDotExpr:
    if head.len < 2: return false
    if head[0].kind notin {nnkIdent, nnkSym}: return false
    if head[1].kind notin {nnkIdent, nnkSym}: return false
    if $head[1] != "build": return false
    let tool = $head[0]
    for accepted in ProfileActionEdgeTypedTools:
      if tool == accepted: return true
    false
  of nnkIdent, nnkSym:
    let name = $head
    for accepted in ProfileActionEdgeBareCalls:
      if name == accepted: return true
    false
  else: false

proc rewriteActionEdgeCall(stmt: NimNode; profileVar: NimNode): NimNode =
  ## Rewrite an action-edge call (``expandArchive.build(...)`` /
  ## ``inlineExecCall(...)``) so its ``BuildActionDef`` return value
  ## lands in ``profileVar.buildActions`` via ``addProfileBuildAction``.
  ##
  ## For bare ``inlineExecCall(...)`` we also need to wrap it in
  ## ``buildAction(...)`` because ``inlineExecCall`` itself returns a
  ## ``PublicCliCall``, not a ``BuildActionDef`` (the
  ## ``addProfileBuildAction`` helper signature). The wrapping moves
  ## the caller-supplied ``id``/``inputs``/``outputs``/...
  ## keyword arguments onto ``buildAction`` and uses the
  ## ``inlineExecCall(...)`` value as the ``call =`` argument.
  ##
  ## The wrapping is done via a ``profileInlineExecActionEdge(...)``
  ## helper (defined in ``./build_actions.nim``) so the macro doesn't
  ## have to splice keyword arguments AST-by-AST: the helper accepts
  ## the same parameter set the spec § 2.3 example shows and assembles
  ## the ``BuildActionDef`` internally.
  let head = stmt[0]
  case head.kind
  of nnkDotExpr:
    # Typed-tool ``<x>.build(args)``: the result is already a
    # BuildActionDef; just wrap with addProfileBuildAction.
    var inner = newNimNode(nnkCall)
    inner.add stmt[0]
    for i in 1 ..< stmt.len:
      inner.add stmt[i]
    var pushCall = newNimNode(nnkCall)
    pushCall.add newIdentNode("addProfileBuildAction")
    var dotExpr = newNimNode(nnkDotExpr)
    dotExpr.add profileVar
    dotExpr.add newIdentNode("buildActions")
    pushCall.add dotExpr
    pushCall.add inner
    return pushCall
  of nnkIdent, nnkSym:
    # Bare ``inlineExecCall(...)``: rewrite to
    # ``profileInlineExecActionEdge(profileVar.buildActions, args)``
    # so the helper can splice the keyword args onto a
    # ``buildAction(...)`` call without the macro doing AST splicing.
    var helperCall = newNimNode(nnkCall)
    helperCall.add newIdentNode("profileInlineExecActionEdge")
    var dotExpr = newNimNode(nnkDotExpr)
    dotExpr.add profileVar
    dotExpr.add newIdentNode("buildActions")
    helperCall.add dotExpr
    for i in 1 ..< stmt.len:
      helperCall.add stmt[i]
    return helperCall
  else:
    error("internal: rewriteActionEdgeCall called on unrecognized call shape",
          stmt)

proc rewriteResourceCall(stmt: NimNode; profileVar: NimNode): NimNode =
  ## Rewrite a `<callee>(args)` resource-constructor call into
  ## `<callee>(profileVar.resources, args)` — target seq splat as the
  ## first positional argument. Used by `parseResourcesSection` and
  ## by the `when` branch walker.
  var newCall = newNimNode(nnkCall)
  newCall.add stmt[0]
  var dotExpr = newNimNode(nnkDotExpr)
  dotExpr.add profileVar
  dotExpr.add newIdentNode("resources")
  newCall.add dotExpr
  for i in 1 ..< stmt.len:
    newCall.add stmt[i]
  result = newCall

proc rewriteResourcesBody(body: NimNode; profileVar: NimNode): NimNode

proc rewriteResourcesStmt(stmt: NimNode; profileVar: NimNode): NimNode =
  ## A single statement inside a `resources:` body.
  ##
  ## Windows-System-Resources Phase G: the body now accepts a MIX of
  ## live-state resource constructor calls (``fsSystemFile(...)`` /
  ## ``windowsService(...)``) and action-edge typed-tool calls
  ## (``expandArchive.build(...)`` / ``inlineExecCall(...)``). The
  ## macro detects the action-edge shape via
  ## ``isProfileActionEdgeCall`` and rewrites it through a different
  ## code path (the call's return value lands in
  ## ``profileVar.buildActions`` instead of ``profileVar.resources``).
  case stmt.kind
  of nnkCall, nnkCommand:
    if isProfileActionEdgeCall(stmt):
      result = rewriteActionEdgeCall(stmt, profileVar)
    else:
      result = rewriteResourceCall(stmt, profileVar)
  of nnkWhenStmt:
    # A runtime predicate guard (`when linux():`) or a Nim compile-time
    # `when defined(...):` branch; `lowerWhenChain` emits both lowerings
    # and the conditions' types pick one.
    let target = newDotExpr(profileVar, ident"resources")
    result = lowerWhenChain(stmt, "resources", target,
      proc (b: NimNode): NimNode = rewriteResourcesBody(b, profileVar),
      proc (b: NimNode): NimNode =
        # Action edges (`expandArchive.build`, `inlineExecCall`) land in
        # `buildActions`, which has no guard: under a runtime predicate
        # they would run on every host. Refuse rather than drop the guard.
        let before = genSym(nskLet, "buildActionsBefore")
        let inner = rewriteResourcesBody(b, profileVar)
        let msg = newStrLitNode("resources: an action edge " &
          "(`expandArchive.build`, `inlineExecCall`) cannot sit under a " &
          "runtime `when <predicate>:`; action edges carry no guard. " &
          "Declare it outside the guard or under a compile-time " &
          "`when defined(...)`.")
        result = quote do:
          let `before` = `profileVar`.buildActions.len
          `inner`
          if `profileVar`.buildActions.len != `before`:
            raise newException(ValueError, `msg`))
  of nnkForStmt:
    # A loop over data that declares resources (`for app in apps:
    # fsUserFile(...)`): rewrite the loop body like any other resources
    # body. The loop runs when the profile binary runs, on every platform
    # alike; guards inside it stay data.
    result = copyNimTree(stmt)
    result[^1] = rewriteResourcesBody(stmt[^1], profileVar)
  of nnkCommentStmt, nnkDiscardStmt:
    result = newEmptyNode()
  else:
    error("resources: block expects constructor calls (e.g. " &
          "`fsUserFile(...)`), optionally inside `when <predicate>:` / " &
          "`when defined(...)` or a `for` loop; got " & $stmt.kind, stmt)

proc rewriteResourcesBody(body: NimNode; profileVar: NimNode): NimNode =
  ## Walk a `resources:` body (or a single nested `when` branch body)
  ## and rewrite every resource-constructor call. Recursive via
  ## `rewriteResourcesStmt` so nested `when` blocks compose cleanly.
  result = newNimNode(nnkStmtList)
  if body.kind == nnkStmtList:
    for stmt in body:
      let rewritten = rewriteResourcesStmt(stmt, profileVar)
      if rewritten.kind != nnkEmpty:
        result.add rewritten
  else:
    let rewritten = rewriteResourcesStmt(body, profileVar)
    if rewritten.kind != nnkEmpty:
      result.add rewritten

proc parseResourcesSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `resources:` body is a list of resource-constructor calls. Each
  ## call must be one of the resource constructor templates declared
  ## in `./resources.nim` or a user-authored template that takes a
  ## `targetResources` final parameter. The macro rewrites each call
  ## to pass the in-scope profile's `resources` seq through.
  ##
  ## A `when` chain is allowed as a child of `resources:` (and nests).
  ## With runtime predicates (`when linux():`, `elif macos():`, `else:`)
  ## each resource carries its branch's predicate as `guard`, evaluated
  ## by the planner against the target host — the idiomatic platform
  ## selection, because the intent then describes every platform. With
  ## compile-time conditions (`when defined(windows):`, M83 Phase F2) the
  ## compiler elides the unreached branches; reserve that for code that
  ## cannot compile elsewhere. See `lowerWhenChain`. A `for` loop over
  ## constructor calls is accepted as well.
  if body.kind != nnkStmtList:
    error("resources: expects an indented block of resource " &
          "constructor calls", body)
  result = rewriteResourcesBody(body, profileVar)

proc parseAdapterPreferenceSection(body: NimNode; profileVar: NimNode): NimNode =
  ## M2.5: `adapterPreference:` body is a list of `<os>: [kind, ...]`
  ## entries — same syntactic shape as `hosts:`. Per-OS keys are drawn
  ## from `{windows, linux, darwin, macos}`; entries are realization kinds
  ## drawn from `{tarball, builtin, scoop, nix, path}` (GM4b: the block is
  ## the profile's selection policy, Provisioning-Contributions.md
  ## §"Selection policy"; `builtin` is the former spelling of `tarball`).
  ## Unknown OS or kind names raise a compile-time error naming the
  ## offending token. `macos` is an alias for `darwin` and is canonicalized
  ## to `"darwin"` so a single resolve-time lookup suffices.
  const KnownOsKeys = ["windows", "linux", "darwin", "macos"]
  const KnownAdapters = ["tarball", "builtin", "scoop", "nix", "path"]
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("adapterPreference: expects an indented block of " &
          "`<os>: [adapter, ...]` entries", body)
  for entry in body:
    if entry.kind != nnkCall or entry.len != 2:
      error("adapterPreference entry must be `<os>: [adapter, ...]`",
            entry)
    var osKey: string
    case entry[0].kind
    of nnkIdent: osKey = $entry[0]
    of nnkStrLit: osKey = entry[0].strVal
    else:
      error("adapterPreference OS key must be an identifier or string " &
            "literal (one of: " & join(KnownOsKeys, ", ") & ")",
            entry[0])
    let osLc = toLowerAscii(osKey)
    if osLc notin KnownOsKeys:
      error("adapterPreference: unknown OS key '" & osKey &
            "' (allowed: " & join(KnownOsKeys, ", ") & ")", entry[0])
    let canonical = (if osLc == "macos": "darwin" else: osLc)
    let listSrc = entry[1]
    var bracketNode: NimNode
    case listSrc.kind
    of nnkStmtList:
      if listSrc.len != 1:
        error("adapterPreference entry body must be a single bracket list",
              listSrc)
      bracketNode = listSrc[0]
    else:
      bracketNode = listSrc
    if bracketNode.kind notin {nnkBracket, nnkPrefix}:
      error("adapterPreference entry value must be a `[adapter, ...]` " &
            "bracket list", bracketNode)
    let actualBracket =
      if bracketNode.kind == nnkPrefix and bracketNode.len == 2 and
         bracketNode[1].kind == nnkBracket:
        bracketNode[1]
      else:
        bracketNode
    var adapterNames: seq[string] = @[]
    for item in actualBracket:
      var aName: string
      case item.kind
      of nnkIdent: aName = $item
      of nnkStrLit: aName = item.strVal
      else:
        error("adapterPreference chain entry must be an identifier or " &
              "string literal (one of: " & join(KnownAdapters, ", ") &
              ")", item)
      let aLc = toLowerAscii(aName)
      if aLc notin KnownAdapters:
        error("adapterPreference: unknown adapter '" & aName &
              "' (allowed: " & join(KnownAdapters, ", ") & ")", item)
      adapterNames.add aLc
    let osLit = newStrLitNode(canonical)
    let tmpSym = genSym(nskVar, "adapterChain")
    let inner = newNimNode(nnkStmtList)
    inner.add quote do:
      var `tmpSym`: seq[string] = @[]
    for a in adapterNames:
      let aLit = newStrLitNode(a)
      inner.add quote do:
        `tmpSym`.add `aLit`
    inner.add quote do:
      `profileVar`.adapterPreference[`osLit`] = `tmpSym`
    let blk = newNimNode(nnkBlockStmt)
    blk.add newEmptyNode()
    blk.add inner
    result.add blk

proc parseAddOnSection(body: NimNode; profileVar: NimNode): NimNode =
  ## ReproOS add-on mode's profile-wide declaration
  ## (ReproOS-Add-On-Mode §4.4):
  ##
  ##   addOn:
  ##     managedEtcPrefixes:
  ##       "/etc/vaultwarden/"
  ##       "/etc/caddy/"
  ##     confirmTimeout: 30      # optional, seconds (§7.5)
  ##
  ## Each prefix is one string literal per line: `/etc/name/` for a subtree,
  ## `/etc/name` for that exact path. The macro records them
  ## (`ProfileIntent.addOn`); their validation is the text form's
  ## (`repro_infra.managedPrefixError`), applied when the compiled profile
  ## is rendered to it, so a hand-written and a compiled profile refuse the
  ## same prefixes.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("addOn: expects an indented block (managedEtcPrefixes: ...)", body)
  result.add quote do:
    `profileVar`.addOn.declared = true
  for entry in body:
    case entry.kind
    of nnkCommentStmt:
      continue
    of nnkCall:
      if entry[0].kind == nnkIdent and $entry[0] == "confirmTimeout":
        # `confirmTimeout: 30`: whole seconds. The range is the text
        # form's (`repro_infra.MaxConfirmTimeoutSec`), checked when the
        # compiled profile is rendered to it.
        if entry.len < 2 or entry[1].kind != nnkStmtList or
            entry[1].len != 1 or entry[1][0].kind notin {nnkIntLit .. nnkInt64Lit}:
          error("confirmTimeout: expects a whole number of seconds", entry)
        let secs = newIntLitNode(entry[1][0].intVal)
        result.add quote do:
          `profileVar`.addOn.confirmTimeoutSec = `secs`
        continue
      if entry[0].kind != nnkIdent or $entry[0] != "managedEtcPrefixes":
        error("addOn: unknown field " & entry[0].repr &
              " (known: managedEtcPrefixes, confirmTimeout)", entry)
      if entry.len < 2 or entry[1].kind != nnkStmtList:
        error("managedEtcPrefixes must be an indented block of string " &
              "literals", entry)
      var seen: seq[string] = @[]
      for p in entry[1]:
        case p.kind
        of nnkCommentStmt:
          continue
        of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
          let prefix = p.strVal
          if prefix in seen:
            error("managedEtcPrefixes: \"" & prefix & "\" is declared twice", p)
          seen.add prefix
          let lit = newStrLitNode(prefix)
          result.add quote do:
            `profileVar`.addOn.managedEtcPrefixes.add `lit`
        else:
          error("managedEtcPrefixes: expected a string literal, got " &
                $p.kind, p)
    else:
      error("addOn: expected `managedEtcPrefixes:`, got " & $entry.kind, entry)

proc parseDataSection(body: NimNode; profileVar: NimNode): NimNode =
  ## GM4: `data:` body is one string literal per line, each naming a
  ## plan-time data file relative to the profile directory:
  ##
  ##   data:
  ##     "data/apps.toml"
  ##
  ## The macro records REFERENCES only (`ProfileIntent.dataFiles`); it
  ## never reads the files, and neither does the profile binary, so a data
  ## edit cannot invalidate the profile compile. `repro home plan` /
  ## `apply` / `export` read and expand them
  ## (`repro_profile_compile/data_expansion`).
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("data: expects an indented block of data-file paths", body)
  var seen: seq[string] = @[]
  for entry in body:
    case entry.kind
    of nnkCommentStmt:
      continue
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      let path = entry.strVal
      let problem = dataFilePathProblem(path)
      if problem.len > 0:
        error("data: \"" & path & "\": " & problem, entry)
      if path in seen:
        error("data: \"" & path & "\" is declared twice", entry)
      seen.add path
      let pathLit = newStrLitNode(path)
      result.add quote do:
        `profileVar`.dataFiles.add `pathLit`
    else:
      error("data: entries must be string literals naming a data file " &
        "relative to the profile directory (e.g. \"data/apps.toml\"); got " &
        $entry.kind, entry)

proc parseCatalogsSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `catalogs:` body is one string literal per line, each naming the Nim
  ## module of a provisioning-contribution catalog relative to the profile
  ## directory -- the module a recipe would `import`:
  ##
  ##   catalogs:
  ##     "../reprobuild-scoop-packages/repro"
  ##
  ## The macro records the REFERENCES only (`ProfileIntent.catalogImports`);
  ## the profile binary never imports or reads them. `repro home apply`
  ## imports them into the recipe it extracts the profile's package
  ## references from (`repro_home_apply/catalog_projection`).
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("catalogs: expects an indented block of catalog module paths", body)
  var seen: seq[string] = @[]
  for entry in body:
    case entry.kind
    of nnkCommentStmt:
      continue
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      let path = entry.strVal
      let problem = catalogImportPathProblem(path)
      if problem.len > 0:
        error("catalogs: \"" & path & "\": " & problem, entry)
      if path in seen:
        error("catalogs: \"" & path & "\" is declared twice", entry)
      seen.add path
      let pathLit = newStrLitNode(path)
      result.add quote do:
        `profileVar`.catalogImports.add `pathLit`
    else:
      error("catalogs: entries must be string literals naming a catalog " &
        "module relative to the profile directory (e.g. " &
        "\"../reprobuild-scoop-packages/repro\"); got " & $entry.kind, entry)

proc findActionEdgeCall(n: NimNode): NimNode =
  ## The first action-edge call (`isProfileActionEdgeCall`) anywhere in `n`,
  ## or nil.
  if isProfileActionEdgeCall(n):
    return n
  for child in n:
    let found = findActionEdgeCall(child)
    if not found.isNil:
      return found
  nil

proc parseActivityResources(blk: NimNode; actName: string;
                            profileVar: NimNode): NimNode =
  ## GM9: a `resources:` block inside `activity <name>:`.
  ##
  ##   activity desktop_core:
  ##     hyprland
  ##     resources:
  ##       hyprlandConfig()          # a helper module's resource template
  ##       when linux():
  ##         fsUserFile(hostFile = "~/.config/foo", content = "...")
  ##
  ## The body is exactly a profile-level `resources:` body (constructor
  ## calls, helper templates, runtime `when` chains, compile-time
  ## `when defined(...)`, `for` loops) and is lowered by the same rewriter;
  ## every resource it declares then belongs to the activity
  ## (`ResourceIntent.activity`, `applyActivity`), so the planner plans it
  ## only on a host that selects the activity -- and, under a guard, only
  ## where the guard also holds.
  ##
  ## Action edges (`expandArchive.build`, `inlineExecCall`) are refused: they
  ## land in `buildActions`, which has no activity, so inside an activity
  ## they would run on every host.
  let edge = findActionEdgeCall(blk[1])
  if not edge.isNil:
    error("activity `" & actName & "`: an action edge (`expandArchive." &
      "build`, `inlineExecCall`) cannot sit in an activity's `resources:` " &
      "block; action edges carry no activity. Declare it in the " &
      "profile-level `resources:` block.", edge)
  let start = genSym(nskLet, "activityResourcesStart")
  let actionsBefore = genSym(nskLet, "activityActionsBefore")
  let lowered = parseResourcesSection(blk[1], profileVar)
  let nameLit = newStrLitNode(actName)
  let msg = newStrLitNode("activity `" & actName & "`: an action edge " &
    "cannot sit in an activity's `resources:` block; action edges carry " &
    "no activity")
  result = quote do:
    block:
      let `start` = `profileVar`.resources.len
      let `actionsBefore` = `profileVar`.buildActions.len
      `lowered`
      # A helper template could still add an action edge the AST check
      # above cannot see; refuse it rather than run it on every host.
      if `profileVar`.buildActions.len != `actionsBefore`:
        raise newException(ValueError, `msg`)
      applyActivity(`profileVar`.resources, `start`, `nameLit`)

proc parseActivityStowEntries(body: NimNode; actName: string;
                              profileVar, guardSym, guardAst: NimNode;
                              seen: var seq[(string, string)]): NimNode =
  ## The entries of a `stow:` block (or of a `when` inside one): string
  ## literals naming `stow/` packages, and single-branch `when <pred>:`
  ## blocks whose predicate conjoins into the guard of the entries under
  ## it. `guardSym` is the in-scope `PredicateExpr` of the enclosing guard
  ## (the empty expression at the top of the block); `guardAst` is that
  ## guard's source, used only to recognise a repeated claim at compile
  ## time.
  result = newNimNode(nnkStmtList)
  let stmts = if body.kind == nnkStmtList: toSeq(body.children) else: @[body]
  let nameLit = newStrLitNode(actName)
  for stmt in stmts:
    case stmt.kind
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      let pkg = stmt.strVal
      let problem = stowPackageNameProblem(pkg)
      if problem.len > 0:
        error("activity `" & actName & "`: stow: " & problem, stmt)
      let key = (pkg, repr(guardAst))
      if key in seen:
        error("activity `" & actName & "` claims stow package `" & pkg &
          "` twice", stmt)
      seen.add key
      let pkgLit = newStrLitNode(pkg)
      result.add quote do:
        `profileVar`.stowScopes.add StowScope(package: `pkgLit`,
          activity: `nameLit`, guard: `guardSym`)
    of nnkWhenStmt:
      if stmt.len != 1 or stmt[0].kind != nnkElifBranch:
        error("activity `" & actName & "`: a `when` in a `stow:` block " &
          "must have exactly one branch (no `elif` / `else`)", stmt)
      let predExpr = stmt[0][0]
      let innerGuard = genSym(nskLet, "stowGuard")
      let inner = newNimNode(nnkStmtList)
      # A runtime predicate only: `when defined(...)` (a bool) fails to type
      # as a `PredicateExpr` here, since a claim must describe every host
      # whatever platform compiled the profile.
      inner.add quote do:
        let `innerGuard`: PredicateExpr = conjoinGuard(`guardSym`,
          `predExpr`)
      let innerAst = newStmtList(guardAst.copyNimTree, predExpr.copyNimTree)
      inner.add parseActivityStowEntries(stmt[0][1], actName, profileVar,
        innerGuard, innerAst, seen)
      let blk = newNimNode(nnkBlockStmt)
      blk.add newEmptyNode()
      blk.add inner
      result.add blk
    of nnkCommentStmt, nnkDiscardStmt:
      discard
    else:
      error("activity `" & actName & "`: a `stow:` block lists `stow/` " &
        "package names as string literals (e.g. \"kitty\" for " &
        "stow/kitty/), optionally under `when <predicate>:`; got " &
        $stmt.kind, stmt)

proc parseActivityStow(blk: NimNode; actName: string;
                       profileVar: NimNode;
                       seen: var seq[(string, string)]): NimNode =
  ## GM11: a `stow:` block inside `activity <name>:` -- the `stow/`
  ## packages that belong to the activity (`repro_profile/stow_scopes`).
  ##
  ##   activity desktop_core:
  ##     stow:
  ##       "kitty"
  ##       when macos():
  ##         "ghostty"
  ##
  ## Each entry becomes a `StowScope` claim; the planner materializes a
  ## claimed package only on a host where one of its claims holds.
  let top = genSym(nskLet, "stowGuard")
  let inner = newNimNode(nnkStmtList)
  inner.add quote do:
    let `top` = PredicateExpr(expr: "")
  inner.add parseActivityStowEntries(blk[1], actName, profileVar, top,
    newStmtList(), seen)
  result = newNimNode(nnkBlockStmt)
  result.add newEmptyNode()
  result.add inner

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
  # GM9: `resources:` blocks directly in the activity body declare resources
  # that belong to this activity; everything else is the package body.
  var elements = newNimNode(nnkStmtList)
  var resourceBlocks: seq[NimNode]
  var stowBlocks: seq[NimNode]
  let stmts = if body.kind == nnkStmtList: toSeq(body.children) else: @[body]
  for stmt in stmts:
    if isActivityResourcesBlock(stmt):
      resourceBlocks.add stmt
    elif isActivityStowBlock(stmt):
      # GM11: the `stow/` packages that belong to this activity.
      stowBlocks.add stmt
    else:
      elements.add stmt
  let inner = newNimNode(nnkStmtList)
  inner.add quote do:
    var `bodySym`: seq[ActivityElement] = @[]
  inner.add parseActivityBody(elements, bodySym)
  inner.add quote do:
    `profileVar`.activities.add ActivityIntent(name: `nameLit`,
      body: `bodySym`)
  for blk in resourceBlocks:
    inner.add parseActivityResources(blk, actName, profileVar)
  var stowSeen: seq[(string, string)]
  for blk in stowBlocks:
    inner.add parseActivityStow(blk, actName, profileVar, stowSeen)
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

  var sawData = false
  var sawCatalogs = false
  var sawAddOn = false
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
        of "adapterPreference":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("adapterPreference must be `adapterPreference: <body>`",
                  stmt)
          stmts.add parseAdapterPreferenceSection(stmt[1], profSym)
        of "data":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("data must be `data: <body>`", stmt)
          if sawData:
            error("exactly one `data:` section per profile", stmt)
          sawData = true
          stmts.add parseDataSection(stmt[1], profSym)
        of "catalogs":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("catalogs must be `catalogs: <body>`", stmt)
          if sawCatalogs:
            error("exactly one `catalogs:` section per profile", stmt)
          sawCatalogs = true
          stmts.add parseCatalogsSection(stmt[1], profSym)
        of "addOn":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("addOn must be `addOn: <body>`", stmt)
          if sawAddOn:
            error("exactly one `addOn:` section per profile", stmt)
          sawAddOn = true
          stmts.add parseAddOnSection(stmt[1], profSym)
        else:
          error("unrecognised profile body form: " & $head, stmt)
      else:
        error("unrecognised profile body form", stmt)
    of nnkCommentStmt:
      discard
    else:
      error("unrecognised profile body form: " & $stmt.kind, stmt)

  # The intent is built by a proc of its own so it can be evaluated twice
  # over: natively, when the compiled profile binary runs (`main`, the
  # normal compile), and in Nim's compile-time VM when the profile is
  # checked for ANOTHER platform (`nim check --os:<os> --cpu:<cpu>
  # -d:reproProfilePlatformProbe`; see `repro_profile_compile/platforms`).
  # The probe is how `repro home export` learns whether a compile-time
  # `when defined(...)` anywhere in the profile -- in a section or in a
  # helper module -- changed what the profile declares: it evaluates the
  # same proc under each platform's definitions and compares the results.
  stmts.add quote do:
    result = `profSym`
  let buildSym = genSym(nskProc, "buildProfileIntent")
  let mainSym = ident("main")
  let probeDefine = ident(ProfilePlatformProbeDefine)
  result = newNimNode(nnkStmtList)
  result.add quote do:
    proc `buildSym`(): ProfileIntent =
      `stmts`
  # Wrap the emit in a `proc main()` so the macro doesn't pollute the
  # user's module scope. `quit 0` inside emitProfileIntent so control
  # never returns.
  result.add quote do:
    proc `mainSym`() =
      emitProfileIntent(`buildSym`())
  result.add quote do:
    when isMainModule:
      when defined(`probeDefine`):
        static:
          echo platformProbeRecord(emitProfileIntentJson(`buildSym`()))
      else:
        `mainSym`()
