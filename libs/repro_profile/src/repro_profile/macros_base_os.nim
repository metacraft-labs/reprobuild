## The `baseOs:` section of a `profile` (ReproOS Add-On Mode §6.5.1):
## compile-time parsing into `ProfileIntent.baseOs`.
##
##   baseOs:
##     image: "https://.../2026-10-06-raspios-trixie-armhf-lite.img.xz"
##     sha256: "2c30...1632"
##     arch: "armhf"
##     buildBoot: "raspi2b"
##     diskSize: "8G"
##     hostname: "rpi2"
##     layout:                       # the `disko:` grammar of `hardware`
##       disks:
##         "sd":
##           type: "mbr"
##           partitions: ...
##     bootMountpoint: "/boot/firmware"
##     bootFiles:
##       "config.txt": configTxt     # any string expression
##       "cmdline.txt": """..."""
##     cloudInit:
##       seed: "bootPartition"
##       userData: """#cloud-config ..."""
##       metaData: "..."
##       networkConfig: "..."
##     bootstrap:
##       deploySigners: "deploy-signers.anchors"
##       cachePublishers: "cache-publishers.anchors"
##       cacheUrl: "https://..."
##       agentTarget: "rpi2"
##       agentSources: ["http://..."]
##       pollInterval: 600
##
## The pinning fields (`image`, `sha256`, `arch`, `buildBoot`, `diskSize`)
## must be string literals, so the macro checks them where the operator
## wrote them and a reviewer sees the pin in the source. File bodies may be
## any string expression (`staticRead(...)`, a `const`). What can only be
## judged once the section is built -- the layout's shape -- is checked by
## `base_os.baseOsProblem`, which `repro infra image` runs before it fetches.

import std/[macros, strutils]

import ./base_os
import ./macros_system

proc literalOf(entry: NimNode; field: string): string =
  ## The string literal a `field: "<value>"` entry carries.
  var v = entry[^1]
  if v.kind == nnkStmtList and v.len == 1: v = v[0]
  if v.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("baseOs." & field & " must be a string literal", v)
  v.strVal

proc exprOf(entry: NimNode; field: string): NimNode =
  ## The expression a `field: <expr>` entry carries (a body).
  var v = entry[^1]
  if v.kind == nnkStmtList:
    if v.len != 1:
      error("baseOs." & field & " expects one string expression", v)
    v = v[0]
  v

proc fieldName(entry: NimNode): string =
  if entry.kind notin {nnkCall, nnkCommand} or entry.len < 2:
    error("baseOs: expected `<field>: <value>`", entry)
  case entry[0].kind
  of nnkIdent, nnkSym: $entry[0]
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit: entry[0].strVal
  else:
    error("baseOs: expected a field name, got " & $entry[0].kind, entry[0])
    ""

proc stringListOf(entry: NimNode; field: string): seq[string] =
  ## `field: ["a", "b"]`, `field: @["a"]`, or an indented block with one
  ## string literal per line.
  var v = entry[^1]
  if v.kind == nnkStmtList and v.len == 1 and
      v[0].kind in {nnkBracket, nnkPrefix}:
    v = v[0]
  if v.kind == nnkStmtList:
    for it in v:
      case it.kind
      of nnkCommentStmt: continue
      of nnkStrLit, nnkRStrLit, nnkTripleStrLit: result.add it.strVal
      else: error("baseOs." & field & ": expected a string literal", it)
    return
  var b = v
  if b.kind == nnkPrefix and b.len == 2 and $b[0] == "@": b = b[1]
  if b.kind != nnkBracket:
    error("baseOs." & field & " expects a list of string literals", v)
  for it in b:
    if it.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error("baseOs." & field & ": expected a string literal", it)
    result.add it.strVal

proc requireOk(problem: string; n: NimNode) =
  if problem.len > 0: error(problem, n)

proc parseBootFiles(body, profileVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("baseOs.bootFiles expects an indented block of " &
          "`\"<name>\": <content>` entries", body)
  var seen: seq[string]
  for entry in body:
    if entry.kind == nnkCommentStmt: continue
    let name = fieldName(entry)
    requireOk(bootFileNameProblem(name), entry[0])
    if name in seen:
      error("baseOs.bootFiles: \"" & name & "\" is declared twice", entry)
    seen.add name
    let nameLit = newStrLitNode(name)
    let content = exprOf(entry, "bootFiles." & name)
    result.add quote do:
      `profileVar`.baseOs.bootFiles.add BaseOsBootFile(name: `nameLit`,
        content: `content`)

proc parseCloudInit(body, profileVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("baseOs.cloudInit expects an indented block", body)
  result.add quote do:
    `profileVar`.baseOs.cloudInit.declared = true
  var seen: seq[string]
  for entry in body:
    if entry.kind == nnkCommentStmt: continue
    let f = fieldName(entry)
    if f in seen: error("baseOs.cloudInit." & f & " is declared twice", entry)
    seen.add f
    case f
    of "seed":
      let s = literalOf(entry, "cloudInit.seed")
      requireOk(cloudInitSeedProblem(s), entry)
      let lit = newStrLitNode(s)
      result.add quote do:
        `profileVar`.baseOs.cloudInit.seed = `lit`
    of "userData", "metaData", "networkConfig":
      let e = exprOf(entry, "cloudInit." & f)
      let fld = ident(f)
      result.add quote do:
        `profileVar`.baseOs.cloudInit.`fld` = `e`
    else:
      error("baseOs.cloudInit: unknown field " & f &
            " (known: seed, userData, metaData, networkConfig)", entry[0])
  if "seed" notin seen:
    error("baseOs.cloudInit needs `seed:` (rootSeedDir or bootPartition)",
          body)

proc parseBootstrap(body, profileVar: NimNode): NimNode =
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("baseOs.bootstrap expects an indented block", body)
  var seen: seq[string]
  for entry in body:
    if entry.kind == nnkCommentStmt: continue
    let f = fieldName(entry)
    if f in seen: error("baseOs.bootstrap." & f & " is declared twice", entry)
    seen.add f
    case f
    of "deploySigners", "cachePublishers":
      let s = literalOf(entry, "bootstrap." & f)
      requireOk(anchorPathProblem(f, s), entry)
      let lit = newStrLitNode(s)
      let fld = ident(f)
      result.add quote do:
        `profileVar`.baseOs.bootstrap.`fld` = `lit`
    of "cacheUrl", "agentTarget":
      # Any string expression: rpi2 derives its hub address from the fleet's
      # lease pins at compile time. Checked by `baseOsProblem`.
      let e = exprOf(entry, "bootstrap." & f)
      let fld = ident(f)
      result.add quote do:
        `profileVar`.baseOs.bootstrap.`fld` = `e`
    of "agentSources":
      var v = entry[^1]
      if v.kind == nnkStmtList and v.len == 1 and v[0].kind == nnkBracket:
        v = v[0]
      if v.kind == nnkBracket:
        for it in v:
          result.add quote do:
            `profileVar`.baseOs.bootstrap.agentSources.add `it`
      else:
        for s in stringListOf(entry, "bootstrap.agentSources"):
          let lit = newStrLitNode(s)
          result.add quote do:
            `profileVar`.baseOs.bootstrap.agentSources.add `lit`
    of "pollInterval":
      var v = entry[^1]
      if v.kind == nnkStmtList and v.len == 1: v = v[0]
      if v.kind notin {nnkIntLit .. nnkInt64Lit} or v.intVal <= 0:
        error("baseOs.bootstrap.pollInterval expects a positive whole " &
              "number of seconds", v)
      let lit = newIntLitNode(v.intVal)
      result.add quote do:
        `profileVar`.baseOs.bootstrap.pollIntervalSec = `lit`
    else:
      error("baseOs.bootstrap: unknown field " & f & " (known: " &
            "deploySigners, cachePublishers, cacheUrl, agentTarget, " &
            "agentSources, pollInterval)", entry[0])

proc parseBaseOsSection*(body: NimNode; profileVar: NimNode): NimNode =
  ## The `baseOs:` body: emits assignments into `profileVar.baseOs`.
  result = newNimNode(nnkStmtList)
  if body.kind != nnkStmtList:
    error("baseOs: expects an indented block (image: ..., sha256: ...)", body)
  result.add quote do:
    `profileVar`.baseOs.declared = true
  var seen: seq[string]
  for entry in body:
    if entry.kind == nnkCommentStmt: continue
    let f = fieldName(entry)
    if f in seen: error("baseOs." & f & " is declared twice", entry)
    seen.add f
    case f
    of "image", "sha256", "arch", "buildBoot", "diskSize", "hostname",
       "bootMountpoint":
      let s = literalOf(entry, f)
      requireOk(baseOsScalarProblem(f, s), entry)
      let lit = newStrLitNode(s)
      let fld = ident(f)
      result.add quote do:
        `profileVar`.baseOs.`fld` = `lit`
    of "layout":
      let tmp = genSym(nskVar, "baseOsLayout")
      let fill = parseHardwareDiskoBody(entry[^1], tmp)
      result.add quote do:
        block:
          var `tmp` = SystemHardwareSpec()
          `fill`
          `profileVar`.baseOs.layout = `tmp`.disko.get()
    of "bootFiles":
      result.add parseBootFiles(entry[^1], profileVar)
    of "cloudInit":
      result.add parseCloudInit(entry[^1], profileVar)
    of "bootstrap":
      result.add parseBootstrap(entry[^1], profileVar)
    else:
      error("baseOs: unknown field " & f & " (known: image, sha256, arch, " &
            "buildBoot, diskSize, hostname, layout, bootMountpoint, " &
            "bootFiles, cloudInit, bootstrap)", entry[0])
  for required in ["image", "sha256", "arch", "buildBoot", "layout"]:
    if required notin seen:
      error("baseOs needs `" & required & ":`", body)
