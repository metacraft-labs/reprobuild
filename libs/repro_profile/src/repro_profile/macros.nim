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

proc parseConfigSection(body: NimNode; profileVar: NimNode): NimNode =
  ## `config:` body is a list of `<pkg>: <subblock>` entries where the
  ## subblock contains `key = value` assignments, OR a helper-call
  ## statement (M83 Phase F1 convention) that contributes config
  ## overrides via a user-authored sibling-module template. The helper
  ## is invoked as `helper(profileVar.configOverrides, args...)` —
  ## matching the resource-constructor convention — so the helper's
  ## body can append `ConfigOverride` records directly to the in-scope
  ## list.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("config: expects an indented block of per-package overrides",
          body)
  for entry in body:
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
      result.add newCall
      continue
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
    # Nim compile-time `when defined(...):` guard. The branches
    # contain resource-constructor calls; we recurse and rewrite each
    # branch's body in place so the standard Nim compile-time
    # selection still elides the unreached branches.
    result = newNimNode(nnkWhenStmt)
    for branch in stmt:
      case branch.kind
      of nnkElifBranch, nnkElifExpr:
        let cond = branch[0]
        let inner = rewriteResourcesBody(branch[1], profileVar)
        let newBranch = newNimNode(branch.kind)
        newBranch.add cond
        newBranch.add inner
        result.add newBranch
      of nnkElse, nnkElseExpr:
        let inner = rewriteResourcesBody(branch[0], profileVar)
        let newBranch = newNimNode(branch.kind)
        newBranch.add inner
        result.add newBranch
      else:
        error("resources: unsupported `when` branch shape " &
              $branch.kind, branch)
  of nnkCommentStmt, nnkDiscardStmt:
    result = newEmptyNode()
  else:
    error("resources: block expects constructor calls (e.g. " &
          "`fsUserFile(...)`) optionally wrapped in `when " &
          "defined(...)`; got " & $stmt.kind, stmt)

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
  ## M83 Phase F2 extension: a `when defined(<os>):` block is allowed
  ## as a child of `resources:`. The macro rewrites each branch's
  ## body in place so Nim's compile-time selection still elides the
  ## unreached branches. This mirrors the legacy parser's
  ## `when <predicate>:` shape for compile-time host gates and is the
  ## migration target for fixtures that need OS-gated resources.
  if body.kind != nnkStmtList:
    error("resources: expects an indented block of resource " &
          "constructor calls", body)
  result = rewriteResourcesBody(body, profileVar)

proc parseAdapterPreferenceSection(body: NimNode; profileVar: NimNode): NimNode =
  ## M2.5: `adapterPreference:` body is a list of `<os>: [adapter, ...]`
  ## entries — same syntactic shape as `hosts:`. Per-OS keys are drawn
  ## from `{windows, linux, darwin, macos}`; chain entries are drawn
  ## from `{builtin, scoop, nix, path}`. Unknown OS or adapter names
  ## raise a compile-time error naming the offending token. `macos` is
  ## an alias for `darwin` and is canonicalized to `"darwin"` so a
  ## single resolve-time lookup suffices.
  const KnownOsKeys = ["windows", "linux", "darwin", "macos"]
  const KnownAdapters = ["builtin", "scoop", "nix", "path"]
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
        of "adapterPreference":
          if stmt.len < 2 or stmt[1].kind != nnkStmtList:
            error("adapterPreference must be `adapterPreference: <body>`",
                  stmt)
          stmts.add parseAdapterPreferenceSection(stmt[1], profSym)
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
