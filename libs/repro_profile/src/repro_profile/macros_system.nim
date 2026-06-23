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

import std/[macros, strutils]

import ./types
import ./emit

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
