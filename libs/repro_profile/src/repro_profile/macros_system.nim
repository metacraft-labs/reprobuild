## M9.R.20: system-scope macros — ``system "<hostname>":``,
## ``hardware "<id>":``, and ``activity "<name>":`` at the system scope.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md``
## §§ 2-4. The macros are the user-editable entry point for ReproOS
## configuration (parallel to ``profile "X":`` for the home scope).
##
## Surface (per spec §2.2):
##
## ```
## system "myDesktop":
##   imports:
##     "./hardware.nim"
##     "modules/activities/development.nim"
##     "modules/de/plasma.nim"
##
##   config:
##     preferredDE: variant enum["sway", "gnome", "plasma"] = "plasma"
##     timezone: string = "Europe/Sofia"
##     locale: string = "en_US.UTF-8"
##     hostname: string = "myDesktop"
##     defaultUser: string = "zahary"
##
##   users:
##     "zahary":
##       groups: @["wheel", "audio", "video"]
##       homeIntent: import "./home.nim"
##
##   services:
##     enable: @["NetworkManager", "sshd", "sddm"]
##     disable: @["systemd-resolved"]
##
##   packages:
##     extra: @["firefox", "vim"]
##
##   bootloader:
##     type: grub
##     device: "/dev/sda"
## ```
##
## v0.1 behaviour:
##   * Parse-and-store. The macro produces a ``SystemIntent`` value at
##     runtime and emits it as JSON via ``emitSystemIntent`` (mirrors
##     the home-side ``emitProfileIntent``).
##   * Variants are recognised at the syntactic level (``isVariant``
##     flag on ``SystemConfigEntry``); full Configurable-runtime
##     threading is delegated to a follow-up milestone alongside the
##     ``repro infra apply`` integration.
##   * ``validate:`` body lines are captured verbatim (closure-form
##     lambdas, identifier references, comparison expressions).
##
## The macro is intentionally simple-and-permissive — the M9.R.20
## scope is to demonstrate the user-facing surface compiles +
## round-trips through JSON, so the installer can write a ``system.nim``
## that the macro parses back into the same SystemIntent.

import std/[macros, options, strutils]

import ./types
import ./emit

export options  # users of `hardware`/`buildHardwareSpec` need `some`/`none`
                # in scope to author `disko:` body expressions.

const SystemIntentVar* = "systemIntentBuilder"
const HardwareIntentVar* = "hardwareIntentBuilder"
const ActivityIntentVar* = "activityIntentBuilder"

# ---------------------------------------------------------------------
# Helpers: stringify identifier / literal nodes.
# ---------------------------------------------------------------------

proc identOrStr(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym: $n
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit: n.strVal
  of nnkAccQuoted:
    var s = ""
    for child in n: s.add $child
    s
  else: ""

proc collectStrLitList(n: NimNode): seq[string] =
  ## Accepts ``@["a", "b"]`` (Prefix '@' over Bracket) or a bare
  ## ``["a", "b"]`` Bracket node and harvests the string literals.
  result = @[]
  var bracketNode: NimNode = n
  if n.kind == nnkPrefix and n.len == 2 and
     n[0].kind == nnkIdent and $n[0] == "@" and
     n[1].kind == nnkBracket:
    bracketNode = n[1]
  if bracketNode.kind != nnkBracket:
    error("expected a `@[\"...\", ...]` string list, got " & $n.kind, n)
  for child in bracketNode:
    case child.kind
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit: result.add child.strVal
    of nnkIdent: result.add $child
    else:
      error("string-list entry must be a string literal or identifier, " &
            "got " & $child.kind, child)

proc collectDocComment(n: NimNode): string =
  ## Pull out the ``## ...`` comment lines attached to a config entry.
  ## Nim attaches comment statements as adjacent siblings in the
  ## statement list; we currently surface only the comment-stmt node's
  ## ``strVal`` since that's the only shape the spec depicts.
  if n.kind == nnkCommentStmt:
    return n.strVal
  result = ""

# ---------------------------------------------------------------------
# Sub-block parsers: `imports:`, `config:`, `users:`, `services:`,
# `packages:`, `bootloader:`, `validate:`.
# ---------------------------------------------------------------------

proc parseImportsBody(body: NimNode; sysVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("imports: expects an indented block of relative module paths",
          body)
  for entry in body:
    case entry.kind
    of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
      let pathLit = newStrLitNode(entry.strVal)
      result.add quote do:
        `sysVar`.imports.add `pathLit`
    of nnkCommentStmt, nnkDiscardStmt:
      discard
    else:
      error("imports entry must be a string literal (relative path), got " &
            $entry.kind, entry)

proc parseConfigBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `config:` body is a list of `<ident>: <typeExpr> = <default>`
  ## entries, optionally preceded by a `## ...` doc comment.
  ##
  ## v0.1 captures each entry as a SystemConfigEntry; full Configurable
  ## wiring happens in a follow-up milestone.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("config: expects an indented block of `key: type = default` " &
          "entries", body)
  var pendingDoc = ""
  for entry in body:
    case entry.kind
    of nnkCommentStmt:
      if pendingDoc.len > 0: pendingDoc.add "\n"
      pendingDoc.add entry.strVal
    of nnkCall:
      # Standard call: `<key>: <typeExpr> = <default>`. Nim parses
      # this as `Call(<key>, StmtList(Asgn(<typeExpr>, <default>)))` or
      # similar shapes depending on the type and default literal.
      if entry.len < 2 or entry[1].kind != nnkStmtList:
        error("config entry must be `<key>: <type> = <default>`, got " &
              repr(entry), entry)
      let key = identOrStr(entry[0])
      if key.len == 0:
        error("config entry key must be an identifier or string literal",
              entry[0])
      # The StmtList wraps either an Asgn (type = default) or just the
      # type (no default). We accept both shapes; v0.1 captures the
      # verbatim source repr of each side.
      let inner = entry[1]
      var typeRepr = ""
      var defaultExpr = ""
      var isVariant = false
      if inner.len >= 1:
        case inner[0].kind
        of nnkAsgn:
          typeRepr = repr(inner[0][0])
          defaultExpr = repr(inner[0][1])
          # M9.R.20 syntax: ``variant enum[...]`` marker — captured as
          # ``isVariant`` flag. The parser keeps the verbatim repr so a
          # follow-up milestone can lower it into the M9.E
          # ``variant: arm-dispatch`` registry.
          if typeRepr.startsWith("variant "): isVariant = true
        else:
          typeRepr = repr(inner[0])
          if typeRepr.startsWith("variant "): isVariant = true
      let keyLit = newStrLitNode(key)
      let typeLit = newStrLitNode(typeRepr)
      let defaultLit = newStrLitNode(defaultExpr)
      let docLit = newStrLitNode(pendingDoc)
      let variantLit = newLit(isVariant)
      result.add quote do:
        `sysVar`.configs.add SystemConfigEntry(
          key: `keyLit`,
          typeRepr: `typeLit`,
          defaultExpr: `defaultLit`,
          docComment: `docLit`,
          isVariant: `variantLit`)
      pendingDoc = ""
    of nnkDiscardStmt:
      discard
    else:
      error("config entry must be `<key>: <type> = <default>`, got " &
            $entry.kind, entry)

proc parseUsersBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `users:` body is a list of `"<name>": <subblock>` entries where
  ## the subblock contains `groups: @[...]`, `homeIntent: import "..."`,
  ## and optionally `fullName: "..."`.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("users: expects an indented block of `\"<name>\": <subblock>` " &
          "entries", body)
  for entry in body:
    if entry.kind notin {nnkCall, nnkCommand} or entry.len < 2 or
       entry[^1].kind != nnkStmtList:
      if entry.kind in {nnkCommentStmt, nnkDiscardStmt}:
        continue
      error("users entry must be `\"<name>\": <subblock>`, got " &
            $entry.kind, entry)
    let nameKey = identOrStr(entry[0])
    if nameKey.len == 0:
      error("users entry name must be a string literal or identifier",
            entry[0])
    let sub = entry[^1]
    var fullName = ""
    var groups: seq[string] = @[]
    var homeImport = ""
    for kv in sub:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        if kv.len < 2:
          error("users sub-entry must be `<key>: <value>`", kv)
        let k = identOrStr(kv[0])
        let valWrap = kv[^1]
        # `valWrap` is either a StmtList wrapping the value or the
        # value itself depending on Nim's parser. Unwrap a single-elem
        # StmtList.
        var val = valWrap
        if val.kind == nnkStmtList and val.len == 1:
          val = val[0]
        case k
        of "fullName":
          case val.kind
          of nnkStrLit, nnkRStrLit, nnkTripleStrLit: fullName = val.strVal
          else:
            error("users.fullName must be a string literal", val)
        of "groups":
          groups = collectStrLitList(val)
        of "homeIntent":
          # `homeIntent: import "./home.nim"` shape. Nim's parser
          # recognises `import "..."` at this position as an
          # `nnkImportStmt` whose child is the path literal. Older
          # grammar shapes deliver `Command(import, StrLit)` or
          # `Call(import, StrLit)` — accept both.
          if val.kind == nnkImportStmt:
            # nnkImportStmt children are import paths; pick the first.
            if val.len < 1:
              error("users.homeIntent import statement has no path", val)
            let p = val[0]
            case p.kind
            of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
              homeImport = p.strVal
            of nnkInfix:
              # `./foo` parses to an infix tree under nnkImportStmt
              # in some Nim versions; fall back to repr.
              homeImport = repr(p)
            else:
              error("users.homeIntent import argument must be a string " &
                    "literal, got " & $p.kind, p)
          elif val.kind in {nnkCall, nnkCommand} and val.len >= 2 and
               val[0].kind == nnkIdent and $val[0] == "import":
            case val[1].kind
            of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
              homeImport = val[1].strVal
            else:
              error("users.homeIntent import argument must be a string " &
                    "literal", val[1])
          elif val.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
            # Permissive: a bare string literal is also accepted.
            homeImport = val.strVal
          else:
            error("users.homeIntent must be `import \"<path>\"` or a " &
                  "string literal, got " & $val.kind, val)
        else:
          error("unknown users sub-entry: " & k, kv[0])
      else:
        error("users sub-entry must be `<key>: <value>`, got " & $kv.kind,
              kv)
    let nameLit = newStrLitNode(nameKey)
    let fullLit = newStrLitNode(fullName)
    let homeLit = newStrLitNode(homeImport)
    let tmpSym = genSym(nskVar, "userGroups")
    let blk = newNimNode(nnkBlockStmt)
    let inner = newNimNode(nnkStmtList)
    inner.add quote do:
      var `tmpSym`: seq[string] = @[]
    for g in groups:
      let gLit = newStrLitNode(g)
      inner.add quote do:
        `tmpSym`.add `gLit`
    inner.add quote do:
      `sysVar`.users.add SystemUserEntry(
        name: `nameLit`,
        fullName: `fullLit`,
        groups: `tmpSym`,
        homeIntentImport: `homeLit`)
    blk.add newEmptyNode()
    blk.add inner
    result.add blk

proc parseServicesBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `services:` body is `enable: @[...]` + optional `disable: @[...]`.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("services: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      if entry.len < 2:
        error("services entry must be `<key>: <list>`", entry)
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      let items = collectStrLitList(val)
      let tmpSym = genSym(nskVar, "svcList")
      let blk = newNimNode(nnkBlockStmt)
      let inner = newNimNode(nnkStmtList)
      inner.add quote do:
        var `tmpSym`: seq[string] = @[]
      for it in items:
        let itLit = newStrLitNode(it)
        inner.add quote do:
          `tmpSym`.add `itLit`
      case k
      of "enable":
        inner.add quote do:
          `sysVar`.services.enableList = `tmpSym`
      of "disable":
        inner.add quote do:
          `sysVar`.services.disableList = `tmpSym`
      else:
        error("services sub-entry must be `enable:` or `disable:`, got " &
              k, entry[0])
      blk.add newEmptyNode()
      blk.add inner
      result.add blk
    else:
      error("services entry must be `<key>: <list>`, got " & $entry.kind,
            entry)

proc parsePackagesBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `packages:` body is `extra: @[...]`. v0.1 supports only the
  ## extra-packages shape; the closure-affecting package set flows
  ## through the imported activity modules.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("packages: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      if entry.len < 2:
        error("packages entry must be `extra: @[...]`", entry)
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      if k != "extra":
        error("packages sub-entry must be `extra:`, got " & k, entry[0])
      let items = collectStrLitList(val)
      let tmpSym = genSym(nskVar, "pkgList")
      let blk = newNimNode(nnkBlockStmt)
      let inner = newNimNode(nnkStmtList)
      inner.add quote do:
        var `tmpSym`: seq[string] = @[]
      for it in items:
        let itLit = newStrLitNode(it)
        inner.add quote do:
          `tmpSym`.add `itLit`
      inner.add quote do:
        `sysVar`.extraPackages = `tmpSym`
      blk.add newEmptyNode()
      blk.add inner
      result.add blk
    else:
      error("packages entry must be `extra: @[...]`, got " & $entry.kind,
            entry)

proc parseBootloaderBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `bootloader:` body is `type: <ident>` + `device: "..."`.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("bootloader: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      if entry.len < 2:
        error("bootloader entry must be `<key>: <value>`", entry)
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      case k
      of "type":
        let s = identOrStr(val)
        if s.len == 0:
          error("bootloader.type must be an identifier or string literal",
                val)
        let lit = newStrLitNode(s)
        result.add quote do:
          `sysVar`.bootloader.kind = `lit`
      of "device":
        let s = identOrStr(val)
        if s.len == 0:
          error("bootloader.device must be a string literal " &
                "(or unquoted ident)", val)
        let lit = newStrLitNode(s)
        result.add quote do:
          `sysVar`.bootloader.device = `lit`
      else:
        error("bootloader sub-entry must be `type:` or `device:`, got " &
              k, entry[0])
    else:
      error("bootloader entry must be `<key>: <value>`, got " &
            $entry.kind, entry)

proc parseValidateBody(body: NimNode; sysVar: NimNode): NimNode =
  ## `validate:` body is a list of expressions; v0.1 captures each as
  ## its verbatim source repr so a follow-up milestone can wire them
  ## into the M9.E ``registerValidateExpr`` registry.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("validate: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    else:
      let exprRepr = repr(entry)
      let lit = newStrLitNode(exprRepr)
      result.add quote do:
        `sysVar`.validateExprs.add `lit`

# ---------------------------------------------------------------------
# The top-level `system "<hostname>":` macro.
# ---------------------------------------------------------------------

macro system*(name: static[string]; body: untyped): untyped =
  ## ReproOS user-editable system configuration entry point. Lifts the
  ## proven ``profile`` macro pipeline to system scope per
  ## ``ReproOS-Configuration-Architecture.md`` §2.2.
  let sysSym = genSym(nskVar, SystemIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `sysSym`: SystemIntent
    `sysSym`.hostname = `name`

  if body.kind != nnkStmtList:
    error("system body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised system body form", stmt)
      if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
        error("system body section `" & $head & "` must be `" & $head &
              ": <body>`", stmt)
      case $head
      of "imports":
        stmts.add parseImportsBody(stmt[^1], sysSym)
      of "config":
        stmts.add parseConfigBody(stmt[^1], sysSym)
      of "users":
        stmts.add parseUsersBody(stmt[^1], sysSym)
      of "services":
        stmts.add parseServicesBody(stmt[^1], sysSym)
      of "packages":
        stmts.add parsePackagesBody(stmt[^1], sysSym)
      of "bootloader":
        stmts.add parseBootloaderBody(stmt[^1], sysSym)
      of "validate":
        stmts.add parseValidateBody(stmt[^1], sysSym)
      else:
        error("unrecognised system body section: " & $head, stmt)
    of nnkCommentStmt, nnkDiscardStmt: discard
    else:
      error("unrecognised system body form: " & $stmt.kind, stmt)

  stmts.add quote do:
    emitSystemIntent(`sysSym`)

  let mainSym = ident("main")
  result = newNimNode(nnkStmtList)
  result.add quote do:
    proc `mainSym`() =
      `stmts`
  result.add quote do:
    when isMainModule:
      `mainSym`()

# ---------------------------------------------------------------------
# `buildSystemIntent` — programmatic builder for tests + tooling that
# need the SystemIntent without running the full main() emit-and-quit.
# ---------------------------------------------------------------------

macro buildSystemIntent*(name: static[string]; body: untyped): untyped =
  ## Same surface as `system "<name>":` but yields a `SystemIntent`
  ## expression instead of an `emitSystemIntent` + `quit`. Used by
  ## unit tests that want to assert against the in-memory shape.
  let sysSym = genSym(nskVar, SystemIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `sysSym`: SystemIntent
    `sysSym`.hostname = `name`

  if body.kind != nnkStmtList:
    error("buildSystemIntent body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised buildSystemIntent body form", stmt)
      if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
        error("buildSystemIntent body section `" & $head &
              "` must be `" & $head & ": <body>`", stmt)
      case $head
      of "imports": stmts.add parseImportsBody(stmt[^1], sysSym)
      of "config":  stmts.add parseConfigBody(stmt[^1], sysSym)
      of "users":   stmts.add parseUsersBody(stmt[^1], sysSym)
      of "services": stmts.add parseServicesBody(stmt[^1], sysSym)
      of "packages": stmts.add parsePackagesBody(stmt[^1], sysSym)
      of "bootloader": stmts.add parseBootloaderBody(stmt[^1], sysSym)
      of "validate": stmts.add parseValidateBody(stmt[^1], sysSym)
      else:
        error("unrecognised buildSystemIntent body section: " & $head,
              stmt)
    of nnkCommentStmt, nnkDiscardStmt: discard
    else:
      error("unrecognised buildSystemIntent body form: " & $stmt.kind,
            stmt)

  stmts.add sysSym
  result = newNimNode(nnkBlockStmt)
  result.add newEmptyNode()
  result.add stmts

# ---------------------------------------------------------------------
# Hardware macro.
# ---------------------------------------------------------------------

proc parseHardwareCpuBody(body: NimNode; hwVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList: return
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      let s = identOrStr(val)
      let lit = newStrLitNode(s)
      case k
      of "arch":
        result.add quote do:
          `hwVar`.cpuArch = `lit`
      of "microcode":
        result.add quote do:
          `hwVar`.cpuMicrocode = `lit`
      else: error("hardware.cpu sub-entry must be `arch:` or `microcode:`, got " & k, entry[0])
    else: error("hardware.cpu entry must be `<key>: <value>`", entry)

proc parseHardwareBootBody(body: NimNode; hwVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList: return
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      case k
      of "kernelModules":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "kmList")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `hwVar`.kernelModules = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        result.add blk
      of "loaderDevice":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        result.add quote do:
          `hwVar`.loaderDevice = `lit`
      else: error("hardware.boot sub-entry: " & k, entry[0])
    else: error("hardware.boot entry must be `<key>: <value>`", entry)

proc parseHardwareFsBody(body: NimNode; hwVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList: return
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let mp = identOrStr(entry[0])
      if mp.len == 0:
        error("filesystems entry key must be a string literal", entry[0])
      let sub = entry[^1]
      var device = ""
      var fsType = ""
      var options: seq[string] = @[]
      if sub.kind == nnkStmtList:
        for kv in sub:
          case kv.kind
          of nnkCommentStmt, nnkDiscardStmt: continue
          of nnkCall, nnkCommand:
            let k = identOrStr(kv[0])
            var val = kv[^1]
            if val.kind == nnkStmtList and val.len == 1: val = val[0]
            case k
            of "device": device = identOrStr(val)
            of "fsType": fsType = identOrStr(val)
            of "options": options = collectStrLitList(val)
            else: error("filesystems.<mp> sub-entry: " & k, kv[0])
          else: error("filesystems.<mp> entry must be `<key>: <value>`", kv)
      let mpLit = newStrLitNode(mp)
      let devLit = newStrLitNode(device)
      let fsLit = newStrLitNode(fsType)
      let tmpSym = genSym(nskVar, "opts")
      let blk = newNimNode(nnkBlockStmt)
      let inner = newNimNode(nnkStmtList)
      inner.add quote do:
        var `tmpSym`: seq[string] = @[]
      for o in options:
        let oLit = newStrLitNode(o)
        inner.add quote do:
          `tmpSym`.add `oLit`
      inner.add quote do:
        `hwVar`.filesystems.add SystemHardwareFs(
          mountPoint: `mpLit`,
          device: `devLit`,
          fsType: `fsLit`,
          options: `tmpSym`)
      blk.add newEmptyNode(); blk.add inner
      result.add blk
    else: error("filesystems entry: " & $entry.kind, entry)

# ---------------------------------------------------------------------
# M9.R.22: disko `disko:` block parser.
# ---------------------------------------------------------------------
#
# Spec: ``reprobuild-specs/ReproOS-Disko-Port.md`` §2.
#
# The `disko:` block declares the create-from-scratch partition intent
# the installer uses to rebuild the system on bare metal. The shape is
# recursive (LUKS-on-LVM-on-RAID composes naturally) so the parser is
# a small set of mutually-recursive helpers.
#
# Top-level shape::
#
#   disko:
#     disks:
#       "<diskName>":
#         device: "/dev/disk/by-id/..."
#         type: gpt
#         partitions:
#           "<partName>":
#             type: esp
#             size: "512M"
#             bootable: true
#             content:
#               filesystem:    # | encrypted: | lvm: | zfs: | swap:
#                 format: "vfat"
#                 mountpoint: "/boot"
#     pools:
#       "rpool":
#         devices: @["/dev/disk/by-id/..."]
#         layout: "stripe"
#         options: @["ashift=12"]

proc parseContentDecl(node: NimNode): NimNode

proc collectStrLitListExpr(n: NimNode): NimNode =
  ## Same shape as collectStrLitList but returns a Nim expression node
  ## that constructs the seq[string] at runtime — works for the cases
  ## where the macro builder needs to emit ``@["a", "b"]`` verbatim
  ## inside an object constructor argument slot.
  let items = collectStrLitList(n)
  let pref = newNimNode(nnkPrefix)
  pref.add ident("@")
  let bracket = newNimNode(nnkBracket)
  for it in items: bracket.add newStrLitNode(it)
  pref.add bracket
  pref

proc parseBtrfsSubvolsExpr(body: NimNode): NimNode =
  ## ``subvols:`` body is an indented block of ``"<name>": <subblock>``
  ## entries where the subblock has ``path:`` + ``options:``. Returns a
  ## Nim expression that constructs a ``seq[BtrfsSubvolSpec]``.
  if body.kind != nnkStmtList:
    error("subvols: expects an indented block", body)
  let pref = newNimNode(nnkPrefix)
  pref.add ident("@")
  let bracket = newNimNode(nnkBracket)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let key {.used.} = identOrStr(entry[0])  # subvol-decl name (e.g. "@home")
      let sub = entry[^1]
      var path = ""
      var opts: NimNode = nil
      if sub.kind == nnkStmtList:
        for kv in sub:
          case kv.kind
          of nnkCommentStmt, nnkDiscardStmt: continue
          of nnkCall, nnkCommand:
            let k = identOrStr(kv[0])
            var val = kv[^1]
            if val.kind == nnkStmtList and val.len == 1: val = val[0]
            case k
            of "path": path = identOrStr(val)
            of "options": opts = collectStrLitListExpr(val)
            else: error("subvols.<name> sub-entry: " & k, kv[0])
          else: error("subvols.<name> entry must be `<key>: <value>`", kv)
      let pathLit = newStrLitNode(path)
      let optsExpr =
        if opts == nil:
          let p = newNimNode(nnkPrefix)
          p.add ident("@")
          p.add newNimNode(nnkBracket)
          p
        else: opts
      bracket.add quote do:
        BtrfsSubvolSpec(path: `pathLit`, options: `optsExpr`)
    else: error("subvols entry must be `\"<name>\": <subblock>`", entry)
  pref.add bracket
  pref

proc parseEncryptionExpr(body: NimNode): NimNode =
  ## ``encryption:`` sub-block — returns an ``EncryptionSpec(...)`` expr.
  if body.kind != nnkStmtList:
    error("encryption: expects an indented block", body)
  var typ = "luks2"
  var keyFile = ""
  var cipher = ""
  var allowDiscards = false
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      case k
      of "type", "kind":
        # ``type:`` matches disko's Nix vocabulary; ``kind:`` works
        # around Nim's ``type`` keyword if the user prefers an unquoted
        # identifier (see the disk-level note above).
        typ = identOrStr(val)
      of "keyFile": keyFile = identOrStr(val)
      of "cipher": cipher = identOrStr(val)
      of "allowDiscards":
        case val.kind
        of nnkIdent:
          let s = $val
          allowDiscards = (s == "true")
        else: error("encryption.allowDiscards must be true/false", val)
      else: error("encryption sub-entry: " & k, entry[0])
    else: error("encryption entry must be `<key>: <value>`", entry)
  let typLit = newStrLitNode(typ)
  let kfLit = newStrLitNode(keyFile)
  let cipherLit = newStrLitNode(cipher)
  let adLit = newLit(allowDiscards)
  # The `type` field is a reserved Nim keyword; we can't write it as a
  # bare identifier in the object-constructor sugar. Build the
  # constructor node by hand so the `type` field name is wrapped in
  # accented identifiers.
  result = newNimNode(nnkObjConstr)
  result.add ident("EncryptionSpec")
  let typExpr = newNimNode(nnkExprColonExpr)
  let typIdent = newNimNode(nnkAccQuoted)
  typIdent.add ident("type")
  typExpr.add typIdent
  typExpr.add typLit
  result.add typExpr
  let kfExpr = newNimNode(nnkExprColonExpr)
  kfExpr.add ident("keyFile")
  kfExpr.add kfLit
  result.add kfExpr
  let cipherExpr = newNimNode(nnkExprColonExpr)
  cipherExpr.add ident("cipher")
  cipherExpr.add cipherLit
  result.add cipherExpr
  let adExpr = newNimNode(nnkExprColonExpr)
  adExpr.add ident("allowDiscards")
  adExpr.add adLit
  result.add adExpr

proc parseLvmVolumesExpr(body: NimNode): NimNode =
  ## ``volumes:`` body — ``"<lvname>":`` entries, each with ``size:`` +
  ## ``content:``. Returns a ``seq[LvmVolumeSpec]`` expr.
  if body.kind != nnkStmtList:
    error("volumes: expects an indented block", body)
  let pref = newNimNode(nnkPrefix)
  pref.add ident("@")
  let bracket = newNimNode(nnkBracket)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let lvName = identOrStr(entry[0])
      let sub = entry[^1]
      var size = ""
      var contentExpr: NimNode = nil
      if sub.kind == nnkStmtList:
        for kv in sub:
          case kv.kind
          of nnkCommentStmt, nnkDiscardStmt: continue
          of nnkCall, nnkCommand:
            let k = identOrStr(kv[0])
            var val = kv[^1]
            case k
            of "size":
              if val.kind == nnkStmtList and val.len == 1: val = val[0]
              size = identOrStr(val)
            of "content":
              if val.kind != nnkStmtList:
                error("volumes.<name>.content expects an indented block",
                      val)
              contentExpr = parseContentDecl(val)
            else: error("volumes.<name> sub-entry: " & k, kv[0])
          else: error("volumes.<name> entry must be `<key>: <value>`", kv)
      let nameLit = newStrLitNode(lvName)
      let sizeLit = newStrLitNode(size)
      let cExpr =
        if contentExpr == nil:
          quote do: ContentSpec(kind: cfsNone)
        else: contentExpr
      bracket.add quote do:
        block:
          var lv = LvmVolumeSpec(name: `nameLit`, size: `sizeLit`)
          lv.content = new(ContentSpec)
          lv.content[] = `cExpr`
          lv
    else: error("volumes entry must be `\"<name>\": <subblock>`", entry)
  pref.add bracket
  pref

proc parseContentDecl(node: NimNode): NimNode =
  ## ``content:`` body — exactly one of ``filesystem:`` / ``encrypted:``
  ## / ``lvm:`` / ``zfs:`` / ``swap:``. Returns a Nim expression that
  ## evaluates to a ``ContentSpec`` value.
  if node.kind != nnkStmtList:
    error("content: expects an indented block", node)
  var chosen: NimNode = nil
  var chosenKind = ""
  for entry in node:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      if chosen != nil:
        error("content: must contain exactly one of " &
              "filesystem/encrypted/lvm/zfs/swap", entry)
      let head = identOrStr(entry[0])
      if entry.len < 2 or entry[^1].kind != nnkStmtList:
        error("content.<kind> must be a sub-block: `" & head & ":`", entry)
      chosenKind = head
      chosen = entry[^1]
    else: error("content entry must be `<kind>: <subblock>`", entry)
  if chosen == nil:
    return quote do: ContentSpec(kind: cfsNone)
  let body = chosen
  case chosenKind
  of "filesystem":
    var format = ""
    var mountpoint = ""
    var mountOpts: NimNode = nil
    var label = ""
    var subvols: NimNode = nil
    for kv in body:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let k = identOrStr(kv[0])
        var val = kv[^1]
        case k
        of "format":
          if val.kind == nnkStmtList and val.len == 1: val = val[0]
          format = identOrStr(val)
        of "mountpoint":
          if val.kind == nnkStmtList and val.len == 1: val = val[0]
          mountpoint = identOrStr(val)
        of "label":
          if val.kind == nnkStmtList and val.len == 1: val = val[0]
          label = identOrStr(val)
        of "mountOptions":
          if val.kind == nnkStmtList and val.len == 1: val = val[0]
          mountOpts = collectStrLitListExpr(val)
        of "subvols":
          if val.kind != nnkStmtList:
            error("filesystem.subvols expects an indented block", val)
          subvols = parseBtrfsSubvolsExpr(val)
        else: error("filesystem sub-entry: " & k, kv[0])
      else: error("filesystem entry must be `<key>: <value>`", kv)
    let fmtLit = newStrLitNode(format)
    let mpLit = newStrLitNode(mountpoint)
    let labelLit = newStrLitNode(label)
    let optsExpr =
      if mountOpts == nil:
        let p = newNimNode(nnkPrefix); p.add ident("@")
        p.add newNimNode(nnkBracket); p
      else: mountOpts
    let svExpr =
      if subvols == nil:
        let p = newNimNode(nnkPrefix); p.add ident("@")
        p.add newNimNode(nnkBracket); p
      else: subvols
    result = quote do:
      ContentSpec(kind: cfsFilesystem, format: `fmtLit`,
        mountpoint: `mpLit`, mountOptions: `optsExpr`,
        label: `labelLit`, subvols: `svExpr`)
  of "encrypted":
    var encExpr: NimNode = nil
    var innerExpr: NimNode = nil
    for kv in body:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let k = identOrStr(kv[0])
        let val = kv[^1]
        case k
        of "encryption":
          if val.kind != nnkStmtList:
            error("encrypted.encryption expects an indented block", val)
          encExpr = parseEncryptionExpr(val)
        of "inner":
          if val.kind != nnkStmtList:
            error("encrypted.inner expects an indented block", val)
          innerExpr = parseContentDecl(val)
        else: error("encrypted sub-entry: " & k, kv[0])
      else: error("encrypted entry must be `<key>: <value>`", kv)
    if encExpr == nil:
      encExpr = quote do: EncryptionSpec()
    if innerExpr == nil:
      innerExpr = quote do: ContentSpec(kind: cfsNone)
    result = quote do:
      block:
        var c = ContentSpec(kind: cfsEncrypted, encryption: `encExpr`)
        c.inner = new(ContentSpec)
        c.inner[] = `innerExpr`
        c
  of "lvm":
    var vg = ""
    var volsExpr: NimNode = nil
    for kv in body:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let k = identOrStr(kv[0])
        var val = kv[^1]
        case k
        of "vg":
          if val.kind == nnkStmtList and val.len == 1: val = val[0]
          vg = identOrStr(val)
        of "volumes":
          if val.kind != nnkStmtList:
            error("lvm.volumes expects an indented block", val)
          volsExpr = parseLvmVolumesExpr(val)
        else: error("lvm sub-entry: " & k, kv[0])
      else: error("lvm entry must be `<key>: <value>`", kv)
    let vgLit = newStrLitNode(vg)
    let vExpr =
      if volsExpr == nil:
        let p = newNimNode(nnkPrefix); p.add ident("@")
        p.add newNimNode(nnkBracket); p
      else: volsExpr
    result = quote do:
      ContentSpec(kind: cfsLvm, vg: `vgLit`, volumes: `vExpr`)
  of "zfs":
    var pool = ""
    var dataset = ""
    var mountpoint = ""
    for kv in body:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let k = identOrStr(kv[0])
        var val = kv[^1]
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        case k
        of "pool": pool = identOrStr(val)
        of "dataset": dataset = identOrStr(val)
        of "mountpoint": mountpoint = identOrStr(val)
        else: error("zfs sub-entry: " & k, kv[0])
      else: error("zfs entry must be `<key>: <value>`", kv)
    let pLit = newStrLitNode(pool)
    let dsLit = newStrLitNode(dataset)
    let mpLit = newStrLitNode(mountpoint)
    result = quote do:
      ContentSpec(kind: cfsZfs, pool: `pLit`, dataset: `dsLit`,
                  zfsMountpoint: `mpLit`)
  of "swap":
    var priority = 0
    var policy = ""
    for kv in body:
      case kv.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let k = identOrStr(kv[0])
        var val = kv[^1]
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        case k
        of "priority":
          if val.kind == nnkIntLit: priority = val.intVal.int
          else: error("swap.priority must be int literal", val)
        of "discardPolicy": policy = identOrStr(val)
        else: error("swap sub-entry: " & k, kv[0])
      else: error("swap entry must be `<key>: <value>`", kv)
    let prLit = newLit(priority)
    let polLit = newStrLitNode(policy)
    result = quote do:
      ContentSpec(kind: cfsSwap, swapPriority: `prLit`,
                  swapDiscardPolicy: `polLit`)
  else:
    error("unknown content kind: `" & chosenKind &
          "` (expected filesystem/encrypted/lvm/zfs/swap)", body)

proc parsePartitionDecl(body: NimNode): NimNode =
  ## ``"<name>": <sub>`` partition entry — produces a ``PartitionSpec``
  ## expression suitable for object-constructor use.
  if body.kind != nnkStmtList:
    error("partition entry expects an indented block", body)
  var typ = ""
  var size = ""
  var bootable = false
  var contentExpr: NimNode = nil
  for kv in body:
    case kv.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(kv[0])
      var val = kv[^1]
      case k
      of "type", "kind":
        # Both names accepted: ``type:`` matches the disko Nix
        # vocabulary, ``kind:`` is the Nim-friendly alternative the
        # spec §2.2 example uses (avoids Nim's ``type`` keyword
        # collision at parse time without backticks).
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        typ = identOrStr(val)
      of "size":
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        size = identOrStr(val)
      of "bootable":
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        case val.kind
        of nnkIdent:
          let s = $val
          bootable = (s == "true")
        else: error("partition.bootable must be true/false", val)
      of "content":
        if val.kind != nnkStmtList:
          error("partition.content expects an indented block", val)
        contentExpr = parseContentDecl(val)
      else: error("partition sub-entry: " & k, kv[0])
    else: error("partition entry must be `<key>: <value>`", kv)
  let typLit = newStrLitNode(typ)
  let sizeLit = newStrLitNode(size)
  let bLit = newLit(bootable)
  let cExpr =
    if contentExpr == nil:
      quote do: ContentSpec(kind: cfsNone)
    else: contentExpr
  # Manual object-constructor build to use the accent-quoted `type`
  # field name.
  result = newNimNode(nnkObjConstr)
  result.add ident("PartitionSpec")
  block:
    let e = newNimNode(nnkExprColonExpr)
    let tq = newNimNode(nnkAccQuoted); tq.add ident("type")
    e.add tq; e.add typLit
    result.add e
  block:
    let e = newNimNode(nnkExprColonExpr)
    e.add ident("size"); e.add sizeLit
    result.add e
  block:
    let e = newNimNode(nnkExprColonExpr)
    e.add ident("content"); e.add cExpr
    result.add e
  block:
    let e = newNimNode(nnkExprColonExpr)
    e.add ident("bootable"); e.add bLit
    result.add e

proc parseDiskDecl(diskName: string; body: NimNode; hwVar: NimNode):
    NimNode =
  ## ``"<diskname>":`` disk entry — emits assignments into a fresh
  ## DiskSpec then registers it into ``hwVar.disko.get().disks``.
  if body.kind != nnkStmtList:
    error("disk entry expects an indented block", body)
  var device = ""
  var table = "gpt"
  var partsBody: NimNode = nil
  for kv in body:
    case kv.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(kv[0])
      var val = kv[^1]
      case k
      of "device":
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        device = identOrStr(val)
      of "type", "table":
        # ``type:`` matches disko's Nix vocabulary; ``table:`` is the
        # Nim-friendly alternative the spec §2.2 example recommends.
        if val.kind == nnkStmtList and val.len == 1: val = val[0]
        table = identOrStr(val)
      of "partitions":
        if val.kind != nnkStmtList:
          error("disk.partitions expects an indented block", val)
        partsBody = val
      else: error("disk sub-entry: " & k, kv[0])
    else: error("disk entry must be `<key>: <value>`", kv)
  let nameLit = newStrLitNode(diskName)
  let devLit = newStrLitNode(device)
  let tabLit = newStrLitNode(table)
  let diskSym = genSym(nskVar, "diskSpec")
  # Build DiskSpec(...) with accent-quoted `type` field.
  let diskCtor = newNimNode(nnkObjConstr)
  diskCtor.add ident("DiskSpec")
  block:
    let e = newNimNode(nnkExprColonExpr)
    e.add ident("device"); e.add devLit
    diskCtor.add e
  block:
    let e = newNimNode(nnkExprColonExpr)
    let tq = newNimNode(nnkAccQuoted); tq.add ident("type")
    e.add tq; e.add tabLit
    diskCtor.add e
  let inner = newNimNode(nnkStmtList)
  inner.add quote do:
    var `diskSym` = `diskCtor`
  if partsBody != nil:
    for partEntry in partsBody:
      case partEntry.kind
      of nnkCommentStmt, nnkDiscardStmt: continue
      of nnkCall, nnkCommand:
        let pName = identOrStr(partEntry[0])
        if pName.len == 0:
          error("partition name must be a string literal", partEntry[0])
        let pSub = partEntry[^1]
        let pExpr = parsePartitionDecl(pSub)
        let pLit = newStrLitNode(pName)
        inner.add quote do:
          `diskSym`.partitions[`pLit`] = `pExpr`
      else: error("partition entry: " & $partEntry.kind, partEntry)
  inner.add quote do:
    `hwVar`.disko.get().disks[`nameLit`] = `diskSym`
  let blk = newNimNode(nnkBlockStmt)
  blk.add newEmptyNode(); blk.add inner
  result = blk

proc parseZfsPoolsBody(body: NimNode; hwVar: NimNode): NimNode =
  ## ``pools:`` body — ``"<poolname>":`` entries with ``devices:`` +
  ## ``layout:`` + ``options:``. Each appends a ZfsPoolSpec to
  ## ``hwVar.disko.get().pools``.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("pools: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let pName = identOrStr(entry[0])
      let sub = entry[^1]
      var devices: NimNode = nil
      var layout = ""
      var opts: NimNode = nil
      if sub.kind == nnkStmtList:
        for kv in sub:
          case kv.kind
          of nnkCommentStmt, nnkDiscardStmt: continue
          of nnkCall, nnkCommand:
            let k = identOrStr(kv[0])
            var val = kv[^1]
            case k
            of "devices":
              if val.kind == nnkStmtList and val.len == 1: val = val[0]
              devices = collectStrLitListExpr(val)
            of "layout":
              if val.kind == nnkStmtList and val.len == 1: val = val[0]
              layout = identOrStr(val)
            of "options":
              if val.kind == nnkStmtList and val.len == 1: val = val[0]
              opts = collectStrLitListExpr(val)
            else: error("pools.<name> sub-entry: " & k, kv[0])
          else: error("pools.<name> entry must be `<key>: <value>`", kv)
      let nameLit = newStrLitNode(pName)
      let layoutLit = newStrLitNode(layout)
      let devExpr =
        if devices == nil:
          let p = newNimNode(nnkPrefix); p.add ident("@")
          p.add newNimNode(nnkBracket); p
        else: devices
      let optsExpr =
        if opts == nil:
          let p = newNimNode(nnkPrefix); p.add ident("@")
          p.add newNimNode(nnkBracket); p
        else: opts
      result.add quote do:
        `hwVar`.disko.get().pools.add ZfsPoolSpec(
          name: `nameLit`, devices: `devExpr`,
          layout: `layoutLit`, options: `optsExpr`)
    else: error("pools entry must be `\"<name>\": <subblock>`", entry)

proc parseHardwareDiskoBody(body: NimNode; hwVar: NimNode): NimNode =
  ## Top-level ``disko:`` body parser. Initialises ``disko = some(...)``
  ## with an empty DiskLayout, then handles ``disks:`` and ``pools:``.
  result = newNimNode(nnkStmtList)
  result.add quote do:
    `hwVar`.disko = some(DiskLayout())
  if body.kind != nnkStmtList:
    error("disko: expects an indented block", body)
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let head = identOrStr(entry[0])
      let sub = entry[^1]
      case head
      of "disks":
        if sub.kind != nnkStmtList:
          error("disko.disks expects an indented block", sub)
        for dEntry in sub:
          case dEntry.kind
          of nnkCommentStmt, nnkDiscardStmt: continue
          of nnkCall, nnkCommand:
            let dName = identOrStr(dEntry[0])
            if dName.len == 0:
              error("disk entry name must be a string literal",
                    dEntry[0])
            result.add parseDiskDecl(dName, dEntry[^1], hwVar)
          else: error("disko.disks entry: " & $dEntry.kind, dEntry)
      of "pools":
        if sub.kind != nnkStmtList:
          error("disko.pools expects an indented block", sub)
        result.add parseZfsPoolsBody(sub, hwVar)
      else: error("disko sub-section: " & head, entry[0])
    else: error("disko entry: " & $entry.kind, entry)

proc parseHardwareSimpleListBody(body: NimNode; hwVar: NimNode;
                                  field: string): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList: return
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      let items = collectStrLitList(val)
      let tmpSym = genSym(nskVar, "lst")
      let blk = newNimNode(nnkBlockStmt)
      let inner = newNimNode(nnkStmtList)
      inner.add quote do:
        var `tmpSym`: seq[string] = @[]
      for it in items:
        let lit = newStrLitNode(it)
        inner.add quote do:
          `tmpSym`.add `lit`
      if field == "graphics" and k == "drivers":
        inner.add quote do:
          `hwVar`.graphicsDrivers = `tmpSym`
      elif field == "audio" and k == "cards":
        inner.add quote do:
          `hwVar`.audioCards = `tmpSym`
      else:
        error("hardware." & field & " sub-entry: " & k, entry[0])
      blk.add newEmptyNode(); blk.add inner
      result.add blk
    else: error("hardware." & field & " entry: " & $entry.kind, entry)

macro hardware*(id: static[string]; body: untyped): untyped =
  ## v0.1 hardware-block macro per ``ReproOS-Configuration-Architecture.md``
  ## §3.3. Captures CPU + boot + filesystems + graphics + audio. The
  ## probe driver (``repro hardware probe``) lands in M9.R.21.
  let hwSym = genSym(nskVar, HardwareIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `hwSym`: SystemHardwareSpec
    `hwSym`.id = `id`

  if body.kind != nnkStmtList:
    error("hardware body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised hardware body form", stmt)
      if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
        error("hardware body section must be `" & $head & ": <body>`", stmt)
      case $head
      of "cpu":         stmts.add parseHardwareCpuBody(stmt[^1], hwSym)
      of "boot":        stmts.add parseHardwareBootBody(stmt[^1], hwSym)
      of "filesystems": stmts.add parseHardwareFsBody(stmt[^1], hwSym)
      of "graphics":    stmts.add parseHardwareSimpleListBody(stmt[^1], hwSym, "graphics")
      of "audio":       stmts.add parseHardwareSimpleListBody(stmt[^1], hwSym, "audio")
      of "disko":       stmts.add parseHardwareDiskoBody(stmt[^1], hwSym)
      else: error("unrecognised hardware body section: " & $head, stmt)
    of nnkCommentStmt, nnkDiscardStmt: discard
    else: error("unrecognised hardware body form: " & $stmt.kind, stmt)

  stmts.add quote do:
    echo emitSystemHardwareJson(`hwSym`)
    quit(0)

  let mainSym = ident("main")
  result = newNimNode(nnkStmtList)
  result.add quote do:
    proc `mainSym`() =
      `stmts`
  result.add quote do:
    when isMainModule:
      `mainSym`()

macro buildHardwareSpec*(id: static[string]; body: untyped): untyped =
  ## Programmatic-builder form of `hardware`. Yields a
  ## `SystemHardwareSpec` expression.
  let hwSym = genSym(nskVar, HardwareIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `hwSym`: SystemHardwareSpec
    `hwSym`.id = `id`

  if body.kind != nnkStmtList:
    error("buildHardwareSpec body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised hardware body form", stmt)
      if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
        error("hardware body section must be `" & $head & ": <body>`", stmt)
      case $head
      of "cpu":         stmts.add parseHardwareCpuBody(stmt[^1], hwSym)
      of "boot":        stmts.add parseHardwareBootBody(stmt[^1], hwSym)
      of "filesystems": stmts.add parseHardwareFsBody(stmt[^1], hwSym)
      of "graphics":    stmts.add parseHardwareSimpleListBody(stmt[^1], hwSym, "graphics")
      of "audio":       stmts.add parseHardwareSimpleListBody(stmt[^1], hwSym, "audio")
      of "disko":       stmts.add parseHardwareDiskoBody(stmt[^1], hwSym)
      else: error("unrecognised hardware body section: " & $head, stmt)
    of nnkCommentStmt, nnkDiscardStmt: discard
    else: error("unrecognised hardware body form: " & $stmt.kind, stmt)

  stmts.add hwSym
  result = newNimNode(nnkBlockStmt)
  result.add newEmptyNode()
  result.add stmts

# ---------------------------------------------------------------------
# Activity macro (system scope).
# ---------------------------------------------------------------------
#
# Lifts the home-side `~/dotfiles/modules/activities.nim` pattern to
# system scope per `ReproOS-Configuration-Architecture.md` §4.2. The
# difference from the home-side activity helpers (which return
# `seq[ActivityElement]`) is that the system-scope activity macro
# yields a structured `SystemActivitySpec` with `systemPackages`,
# `systemServices`, `groups`, and `homeContributions` slots.

proc parseHomeContribBody(body: NimNode; actVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList: return
  for entry in body:
    case entry.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let k = identOrStr(entry[0])
      var val = entry[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      if k == "activities":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "homeContribs")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actVar`.homeContributions = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        result.add blk
      else:
        error("homeContributions sub-entry must be `activities:`, got " & k,
              entry[0])
    else:
      error("homeContributions entry must be `<key>: <list>`, got " &
            $entry.kind, entry)

macro activity*(name: static[string]; body: untyped): untyped =
  ## System-scope activity macro per
  ## ``ReproOS-Configuration-Architecture.md`` §4.2.
  let actSym = genSym(nskVar, ActivityIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `actSym`: SystemActivitySpec
    `actSym`.name = `name`

  if body.kind != nnkStmtList:
    error("activity body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised activity body form", stmt)
      let k = $head
      # Single-value `displayName: "..."`, `description: "..."`, `icon: "..."`.
      var val = stmt[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      case k
      of "displayName":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.displayName = `lit`
      of "description":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.description = `lit`
      of "icon":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.icon = `lit`
      of "systemPackages":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "pkgs")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.systemPackages = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "systemServices":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "svcs")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.systemServices = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "groups":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "grps")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.groups = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "homeContributions":
        # Re-fetch the StmtList body
        if stmt[^1].kind != nnkStmtList:
          error("homeContributions: expects an indented sub-block", stmt)
        stmts.add parseHomeContribBody(stmt[^1], actSym)
      else:
        error("unrecognised activity body section: " & k, stmt)
    else:
      error("unrecognised activity body form: " & $stmt.kind, stmt)

  stmts.add quote do:
    echo emitSystemActivityJson(`actSym`)
    quit(0)

  let mainSym = ident("main")
  result = newNimNode(nnkStmtList)
  result.add quote do:
    proc `mainSym`() =
      `stmts`
  result.add quote do:
    when isMainModule:
      `mainSym`()

macro buildActivitySpec*(name: static[string]; body: untyped): untyped =
  ## Programmatic-builder form of `activity` — yields a
  ## `SystemActivitySpec` expression.
  let actSym = genSym(nskVar, ActivityIntentVar)
  let stmts = newNimNode(nnkStmtList)
  stmts.add quote do:
    var `actSym`: SystemActivitySpec
    `actSym`.name = `name`

  if body.kind != nnkStmtList:
    error("buildActivitySpec body must be an indented block", body)

  for stmt in body:
    case stmt.kind
    of nnkCommentStmt, nnkDiscardStmt: continue
    of nnkCall, nnkCommand:
      let head = stmt[0]
      if head.kind != nnkIdent:
        error("unrecognised activity body form", stmt)
      let k = $head
      var val = stmt[^1]
      if val.kind == nnkStmtList and val.len == 1: val = val[0]
      case k
      of "displayName":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.displayName = `lit`
      of "description":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.description = `lit`
      of "icon":
        let s = identOrStr(val)
        let lit = newStrLitNode(s)
        stmts.add quote do:
          `actSym`.icon = `lit`
      of "systemPackages":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "pkgs")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.systemPackages = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "systemServices":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "svcs")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.systemServices = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "groups":
        let items = collectStrLitList(val)
        let tmpSym = genSym(nskVar, "grps")
        let blk = newNimNode(nnkBlockStmt)
        let inner = newNimNode(nnkStmtList)
        inner.add quote do:
          var `tmpSym`: seq[string] = @[]
        for it in items:
          let lit = newStrLitNode(it)
          inner.add quote do:
            `tmpSym`.add `lit`
        inner.add quote do:
          `actSym`.groups = `tmpSym`
        blk.add newEmptyNode(); blk.add inner
        stmts.add blk
      of "homeContributions":
        if stmt[^1].kind != nnkStmtList:
          error("homeContributions: expects an indented sub-block", stmt)
        stmts.add parseHomeContribBody(stmt[^1], actSym)
      else:
        error("unrecognised activity body section: " & k, stmt)
    else:
      error("unrecognised activity body form: " & $stmt.kind, stmt)

  stmts.add actSym
  result = newNimNode(nnkBlockStmt)
  result.add newEmptyNode()
  result.add stmts
