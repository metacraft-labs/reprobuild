## Pure parsing + drift-classification logic for the M69 Phase-B
## `windows.vsInstaller` driver.
##
## Per System-Profile-And-Infra-Apply.md "windows.vsInstaller": the
## driver invokes the bootstrapped installer (`vs_<edition>.exe`) and
## queries state through `vswhere.exe`. Per the M68/M69 Phase-A
## precedent every real shell-out lives behind `when defined(windows)`
## in `windows_vs_installer_driver.nim`; the PURE logic — parsing
## `vswhere.exe -format json` output, the installed-vs-desired
## workload/component diff, and the drift classification — is isolated
## HERE so it is unit-tested cross-platform without touching the host.
##
## No `import std/os`, no `osproc`, no Win32 — platform-pure by
## construction.
##
## Drift-classification contract (the spec's three explicitly-accepted
## caveats):
##
##   * component VERSION drift is benign — `vswhere` reports a product
##     version, but the resource pins workload/component MEMBERSHIP,
##     not versions; a version difference is never reported as drift.
##   * a workload/component PRESENT on disk but NOT in the resource is
##     reported as drift; the default policy is `leave-alone` (it is
##     user intent), with a warning.
##   * `strict = true` flips the policy: an out-of-spec workload/
##     component is REMOVED on the next apply (it is added to the
##     installer's `--remove` set).

import std/[algorithm, strutils]

# ===========================================================================
# vswhere.exe `-format json` output parsing.
#
# `vswhere.exe -products * -format json` emits a JSON array of installed
# VS products. Reprobuild ships an embedded `vswhere`; the driver runs
# it with the additional flags that surface the per-product
# workload/component package list, so the JSON the driver hands this
# parser is the array of product objects each carrying a `packages`
# array. Rather than depend on a JSON library in this platform-pure
# module we parse the small, well-known shape ourselves with a tiny
# tokenizer — the only fields we read are `installationPath`,
# `productId`, `catalog_productLineVersion` and the `packages[].id` /
# `packages[].type` list. The tokenizer is deliberately strict: a
# malformed document yields a `VsWhereParseError`.
# ===========================================================================

type
  VsPackageType* = enum
    ## The relevant `packages[].type` values vswhere reports. A VS
    ## installation lists every installed package; for membership-drift
    ## purposes only `Workload` and `Component` packages matter.
    vsptWorkload = "Workload"
    vsptComponent = "Component"
    vsptOther = "Other"

  VsInstalledPackage* = object
    ## One entry of a product's `packages` array.
    id*: string
    packageType*: VsPackageType

  VsInstalledProduct* = object
    ## One installed Visual Studio product as reported by vswhere.
    instanceId*: string
    installationPath*: string
    productId*: string                 ## e.g. Microsoft.VisualStudio.Product.Community
    channelId*: string                 ## e.g. VisualStudio.17.Release
    packages*: seq[VsInstalledPackage]

  VsWhereParseError* = object of CatchableError
    ## A malformed vswhere JSON document.

proc vsPackageTypeFromString*(s: string): VsPackageType =
  case s
  of "Workload": vsptWorkload
  of "Component": vsptComponent
  else: vsptOther

# ---------------------------------------------------------------------------
# A tiny, strict JSON scanner. It supports exactly the subset vswhere
# emits: an array of objects, string / number / bool / null scalars,
# nested arrays/objects. It is NOT a general JSON parser — but it is
# pure, dependency-free, and total over its input (it raises on
# anything it does not understand).
# ---------------------------------------------------------------------------

type
  JsonKind = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject
  JsonNode = ref object
    case kind: JsonKind
    of jkNull: discard
    of jkBool: boolVal: bool
    of jkNumber: numVal: string
    of jkString: strVal: string
    of jkArray: elems: seq[JsonNode]
    of jkObject: fields: seq[(string, JsonNode)]

  JsonScanner = object
    text: string
    pos: int

proc raiseVsWhere(msg: string) {.noreturn.} =
  raise newException(VsWhereParseError,
    "vswhere JSON parse failed: " & msg)

proc skipWs(s: var JsonScanner) =
  while s.pos < s.text.len and s.text[s.pos] in {' ', '\t', '\r', '\n'}:
    inc s.pos

proc parseValue(s: var JsonScanner): JsonNode

proc parseString(s: var JsonScanner): string =
  if s.pos >= s.text.len or s.text[s.pos] != '"':
    raiseVsWhere("expected a string at offset " & $s.pos)
  inc s.pos
  var buf = ""
  while s.pos < s.text.len:
    let c = s.text[s.pos]
    if c == '"':
      inc s.pos
      return buf
    elif c == '\\':
      inc s.pos
      if s.pos >= s.text.len:
        raiseVsWhere("unterminated escape")
      let e = s.text[s.pos]
      case e
      of '"': buf.add('"')
      of '\\': buf.add('\\')
      of '/': buf.add('/')
      of 'b': buf.add('\b')
      of 'f': buf.add('\f')
      of 'n': buf.add('\n')
      of 'r': buf.add('\r')
      of 't': buf.add('\t')
      of 'u':
        # \uXXXX — decode the BMP code point; surrogate pairs are not
        # expected in vswhere identifiers but are tolerated as two
        # separate units (good enough for a diagnostic-only path).
        if s.pos + 4 >= s.text.len:
          raiseVsWhere("truncated \\u escape")
        let hex = s.text[s.pos + 1 .. s.pos + 4]
        var cp = 0
        for h in hex:
          cp = cp * 16 + (
            case h
            of '0'..'9': int(ord(h) - ord('0'))
            of 'a'..'f': int(ord(h) - ord('a') + 10)
            of 'A'..'F': int(ord(h) - ord('A') + 10)
            else: raiseVsWhere("bad hex digit in \\u escape"))
        s.pos += 4
        if cp < 0x80:
          buf.add(char(cp))
        elif cp < 0x800:
          buf.add(char(0xC0 or (cp shr 6)))
          buf.add(char(0x80 or (cp and 0x3F)))
        else:
          buf.add(char(0xE0 or (cp shr 12)))
          buf.add(char(0x80 or ((cp shr 6) and 0x3F)))
          buf.add(char(0x80 or (cp and 0x3F)))
      else:
        raiseVsWhere("unknown escape '\\" & e & "'")
      inc s.pos
    else:
      buf.add(c)
      inc s.pos
  raiseVsWhere("unterminated string literal")

proc parseArray(s: var JsonScanner): JsonNode =
  inc s.pos                             # consume '['
  result = JsonNode(kind: jkArray)
  s.skipWs()
  if s.pos < s.text.len and s.text[s.pos] == ']':
    inc s.pos
    return
  while true:
    s.skipWs()
    result.elems.add(parseValue(s))
    s.skipWs()
    if s.pos >= s.text.len:
      raiseVsWhere("unterminated array")
    if s.text[s.pos] == ',':
      inc s.pos
    elif s.text[s.pos] == ']':
      inc s.pos
      return
    else:
      raiseVsWhere("expected ',' or ']' in array")

proc parseObject(s: var JsonScanner): JsonNode =
  inc s.pos                             # consume '{'
  result = JsonNode(kind: jkObject)
  s.skipWs()
  if s.pos < s.text.len and s.text[s.pos] == '}':
    inc s.pos
    return
  while true:
    s.skipWs()
    let key = parseString(s)
    s.skipWs()
    if s.pos >= s.text.len or s.text[s.pos] != ':':
      raiseVsWhere("expected ':' after object key")
    inc s.pos
    s.skipWs()
    result.fields.add((key, parseValue(s)))
    s.skipWs()
    if s.pos >= s.text.len:
      raiseVsWhere("unterminated object")
    if s.text[s.pos] == ',':
      inc s.pos
    elif s.text[s.pos] == '}':
      inc s.pos
      return
    else:
      raiseVsWhere("expected ',' or '}' in object")

proc parseValue(s: var JsonScanner): JsonNode =
  s.skipWs()
  if s.pos >= s.text.len:
    raiseVsWhere("unexpected end of document")
  let c = s.text[s.pos]
  case c
  of '"':
    JsonNode(kind: jkString, strVal: parseString(s))
  of '[':
    parseArray(s)
  of '{':
    parseObject(s)
  of 't':
    if s.text.continuesWith("true", s.pos):
      s.pos += 4
      JsonNode(kind: jkBool, boolVal: true)
    else: raiseVsWhere("bad literal")
  of 'f':
    if s.text.continuesWith("false", s.pos):
      s.pos += 5
      JsonNode(kind: jkBool, boolVal: false)
    else: raiseVsWhere("bad literal")
  of 'n':
    if s.text.continuesWith("null", s.pos):
      s.pos += 4
      JsonNode(kind: jkNull)
    else: raiseVsWhere("bad literal")
  of '-', '0'..'9':
    var num = ""
    while s.pos < s.text.len and
        s.text[s.pos] in {'-', '+', '.', 'e', 'E', '0'..'9'}:
      num.add(s.text[s.pos])
      inc s.pos
    JsonNode(kind: jkNumber, numVal: num)
  else:
    raiseVsWhere("unexpected character '" & c & "' at offset " & $s.pos)

proc getField(node: JsonNode; key: string): JsonNode =
  if node.kind != jkObject:
    return nil
  for (k, v) in node.fields:
    if k == key:
      return v
  return nil

proc strField(node: JsonNode; key: string): string =
  let f = node.getField(key)
  if f != nil and f.kind == jkString:
    f.strVal
  else:
    ""

# ---------------------------------------------------------------------------
# The public vswhere parser.
# ---------------------------------------------------------------------------

proc parseVsWhereOutput*(rawJson: string): seq[VsInstalledProduct] =
  ## Parse `vswhere.exe -format json` output into the typed product
  ## list. An EMPTY array (`[]`) — vswhere's output when no VS product
  ## is installed — yields an empty seq, NOT an error. A genuinely
  ## malformed document raises `VsWhereParseError`.
  let trimmed = rawJson.strip()
  if trimmed.len == 0:
    return @[]
  var s = JsonScanner(text: trimmed, pos: 0)
  let root = parseValue(s)
  s.skipWs()
  if s.pos != s.text.len:
    raiseVsWhere("trailing content after the JSON document")
  if root.kind != jkArray:
    raiseVsWhere("expected a top-level array of products")
  for productNode in root.elems:
    if productNode.kind != jkObject:
      raiseVsWhere("a product entry is not an object")
    var product = VsInstalledProduct(
      instanceId: strField(productNode, "instanceId"),
      installationPath: strField(productNode, "installationPath"),
      productId: strField(productNode, "productId"),
      channelId: strField(productNode, "channelId"))
    let pkgs = productNode.getField("packages")
    if pkgs != nil:
      if pkgs.kind != jkArray:
        raiseVsWhere("'packages' is not an array")
      for pkgNode in pkgs.elems:
        if pkgNode.kind != jkObject:
          raiseVsWhere("a packages[] entry is not an object")
        product.packages.add(VsInstalledPackage(
          id: strField(pkgNode, "id"),
          packageType: vsPackageTypeFromString(
            strField(pkgNode, "type"))))
    result.add(product)

# ---------------------------------------------------------------------------
# Product selection — pick the product the resource targets.
# ---------------------------------------------------------------------------

proc productIdForEdition*(edition: string): string =
  ## The `productId` vswhere reports for a given edition string. The
  ## `system.nim` resource authors a short edition (`Community`,
  ## `Professional`, `Enterprise`, `BuildTools`); vswhere reports the
  ## fully-qualified product id.
  "Microsoft.VisualStudio.Product." & edition

proc selectProduct*(products: seq[VsInstalledProduct];
                     edition, installPath: string): int =
  ## Return the index of the installed product that matches the
  ## resource, or -1 when none matches (the product is not installed).
  ## Matching is by `installationPath` first (the most precise key) and
  ## falls back to `productId == productIdForEdition(edition)`.
  let wantProductId = productIdForEdition(edition)
  let wantPath = installPath.strip()
  # Path match wins — an operator can have several editions installed.
  if wantPath.len > 0:
    for i, p in products:
      if cmpIgnoreCase(p.installationPath.strip(), wantPath) == 0:
        return i
  for i, p in products:
    if cmpIgnoreCase(p.productId, wantProductId) == 0:
      return i
  return -1

# ===========================================================================
# Workload / component membership diff + drift classification.
# ===========================================================================

type
  VsInstallerDesiredState* = object
    ## The desired state a `windows.vsInstaller` resource declares.
    edition*: string
    channel*: string
    installPath*: string
    workloads*: seq[string]
    components*: seq[string]
    strict*: bool

  VsMembershipDiff* = object
    ## The result of comparing the installed workload/component set
    ## against the resource's desired set.
    productInstalled*: bool
      ## Whether a matching VS product is installed at all.
    missingWorkloads*: seq[string]
      ## In the resource, NOT installed — `--add` on the next apply.
    missingComponents*: seq[string]
    extraWorkloads*: seq[string]
      ## Installed, NOT in the resource — DRIFT. The default policy is
      ## leave-alone (a warning); `strict` flips it to `--remove`.
    extraComponents*: seq[string]

  VsDriftClass* = enum
    ## The classification of a `windows.vsInstaller` observation.
    vsdInSync = "in-sync"
      ## Installed and the workload/component membership matches.
    vsdNeedsInstall = "needs-install"
      ## No matching product is installed — a fresh install.
    vsdNeedsModify = "needs-modify"
      ## Installed but missing one or more declared workloads/
      ## components — an installer `modify --add`.
    vsdMembershipDrift = "membership-drift"
      ## Installed; the declared set is satisfied but EXTRA out-of-spec
      ## workloads/components are present. With `strict = false` this is
      ## the leave-alone (warn) outcome; with `strict = true` the extra
      ## set is removed (the apply still mutates).

proc normalizeId(s: string): string =
  ## VS workload / component ids are case-insensitive; canonicalize so
  ## the set diff is not fooled by a casing difference.
  s.strip().toLowerAscii()

proc containsId(ids: openArray[string]; want: string): bool =
  let w = normalizeId(want)
  for id in ids:
    if normalizeId(id) == w:
      return true
  return false

proc installedWorkloadIds*(product: VsInstalledProduct): seq[string] =
  ## The `Workload`-typed package ids of an installed product.
  for pkg in product.packages:
    if pkg.packageType == vsptWorkload:
      result.add(pkg.id)

proc installedComponentIds*(product: VsInstalledProduct): seq[string] =
  ## The `Component`-typed package ids of an installed product.
  for pkg in product.packages:
    if pkg.packageType == vsptComponent:
      result.add(pkg.id)

proc diffMembership*(desired: VsInstallerDesiredState;
                     products: seq[VsInstalledProduct]): VsMembershipDiff =
  ## Compare the desired workload/component set against the installed
  ## product. Pure set arithmetic — component VERSION is never
  ## consulted, so a component that auto-updated its version is NOT
  ## reported as a difference (the spec's "version drift is benign"
  ## caveat is satisfied by construction: this function only ever
  ## compares package IDS).
  let idx = selectProduct(products, desired.edition, desired.installPath)
  if idx < 0:
    result.productInstalled = false
    result.missingWorkloads = desired.workloads
    result.missingComponents = desired.components
    return
  result.productInstalled = true
  let product = products[idx]
  let haveWorkloads = installedWorkloadIds(product)
  let haveComponents = installedComponentIds(product)
  # Missing = desired but not installed.
  for w in desired.workloads:
    if not containsId(haveWorkloads, w):
      result.missingWorkloads.add(w)
  for c in desired.components:
    if not containsId(haveComponents, c):
      result.missingComponents.add(c)
  # Extra = installed but not desired.
  for w in haveWorkloads:
    if not containsId(desired.workloads, w):
      result.extraWorkloads.add(w)
  for c in haveComponents:
    if not containsId(desired.components, c):
      result.extraComponents.add(c)

proc classifyDrift*(diff: VsMembershipDiff): VsDriftClass =
  ## Reduce a membership diff to a single drift class.
  ##
  ##   * not installed                       -> needs-install
  ##   * missing workloads/components         -> needs-modify
  ##   * only extra (out-of-spec) present     -> membership-drift
  ##   * nothing missing, nothing extra       -> in-sync
  if not diff.productInstalled:
    return vsdNeedsInstall
  if diff.missingWorkloads.len > 0 or diff.missingComponents.len > 0:
    return vsdNeedsModify
  if diff.extraWorkloads.len > 0 or diff.extraComponents.len > 0:
    return vsdMembershipDrift
  return vsdInSync

proc requiresMutation*(diff: VsMembershipDiff; strict: bool): bool =
  ## Whether an apply must actually run the VS installer:
  ##
  ##   * always when a workload/component is missing or the product is
  ##     not installed (an `--add` / install);
  ##   * additionally when `strict` and there is an extra out-of-spec
  ##     workload/component (a `--remove`).
  ##
  ## With `strict = false` an extra workload/component is left alone
  ## (the spec's default leave-alone policy) — no mutation, just a
  ## warning.
  case classifyDrift(diff)
  of vsdNeedsInstall, vsdNeedsModify:
    true
  of vsdMembershipDrift:
    strict
  of vsdInSync:
    false

proc canonicalVsInstallerState*(diff: VsMembershipDiff; strict: bool): string =
  ## Render the observed `windows.vsInstaller` state to a stable
  ## canonical string the broker's re-observe / drift digest covers.
  ## Component version is deliberately NOT part of the canonical string
  ## (version drift is benign); only product-presence and the
  ## ACTIONABLE membership delta are.
  ##
  ## With `strict = false` an extra (out-of-spec) workload/component is
  ## NOT actionable — it does not change the canonical state, so a
  ## re-apply over a user-added workload is a cache-hit, not an endless
  ## modify loop. With `strict = true` an extra is actionable, so it is
  ## included.
  if not diff.productInstalled:
    return "vsInstaller:absent"
  var parts: seq[string]
  parts.add("vsInstaller:present")
  for w in diff.missingWorkloads:
    parts.add("missingWorkload=" & normalizeId(w))
  for c in diff.missingComponents:
    parts.add("missingComponent=" & normalizeId(c))
  if strict:
    for w in diff.extraWorkloads:
      parts.add("extraWorkload=" & normalizeId(w))
    for c in diff.extraComponents:
      parts.add("extraComponent=" & normalizeId(c))
  parts.sort()
  return parts.join(";")

proc canonicalVsInstallerDesired*(): string =
  ## The desired canonical state is always "installed with the declared
  ## membership and no actionable delta" — i.e. an in-sync product.
  "vsInstaller:present"

# ---------------------------------------------------------------------------
# Installer argument construction. The VS bootstrapper (`vs_<edition>.exe`
# / the resident `vs_installer.exe`) takes `--add` / `--remove` flag
# sequences. These helpers build the argument LIST from typed fields;
# the actual `osproc` exec is in `windows_vs_installer_driver.nim`.
# A list (not a joined string) so the driver passes argv directly and
# never interpolates an operator string into a shell line.
# ---------------------------------------------------------------------------

proc buildInstallerArgs*(desired: VsInstallerDesiredState;
                         diff: VsMembershipDiff): seq[string] =
  ## Build the `vs_installer` argv for the action `classifyDrift`
  ## selects:
  ##
  ##   * needs-install : `install --add <every desired w/c>`
  ##   * needs-modify  : `modify --add <each missing w/c>`
  ##   * membership-drift + strict : `modify --remove <each extra w/c>`
  ##
  ## Always includes `--quiet --wait --norestart`; the driver surfaces
  ## a reboot requirement separately, it never auto-reboots. Returns an
  ## EMPTY seq when no mutation is required (in-sync, or non-strict
  ## membership-drift).
  let cls = classifyDrift(diff)
  case cls
  of vsdInSync:
    return @[]
  of vsdMembershipDrift:
    if not desired.strict:
      return @[]                        # leave-alone policy
    result.add("modify")
    result.add("--installPath")
    result.add(desired.installPath)
    for w in diff.extraWorkloads:
      result.add("--remove")
      result.add(w)
    for c in diff.extraComponents:
      result.add("--remove")
      result.add(c)
  of vsdNeedsInstall:
    result.add("install")
    result.add("--productId")
    result.add(productIdForEdition(desired.edition))
    result.add("--channelId")
    result.add(desired.channel)
    if desired.installPath.len > 0:
      result.add("--installPath")
      result.add(desired.installPath)
    for w in desired.workloads:
      result.add("--add")
      result.add(w)
    for c in desired.components:
      result.add("--add")
      result.add(c)
  of vsdNeedsModify:
    result.add("modify")
    result.add("--installPath")
    result.add(desired.installPath)
    for w in diff.missingWorkloads:
      result.add("--add")
      result.add(w)
    for c in diff.missingComponents:
      result.add("--add")
      result.add(c)
  # Common, non-interactive, never-auto-reboot flags.
  result.add("--quiet")
  result.add("--wait")
  result.add("--norestart")

proc buildUninstallArgs*(desired: VsInstallerDesiredState): seq[string] =
  ## Build the `vs_installer uninstall` argv (the resource's destroy /
  ## rollback direction).
  result.add("uninstall")
  result.add("--productId")
  result.add(productIdForEdition(desired.edition))
  result.add("--channelId")
  result.add(desired.channel)
  if desired.installPath.len > 0:
    result.add("--installPath")
    result.add(desired.installPath)
  result.add("--quiet")
  result.add("--wait")
  result.add("--norestart")

proc vsInstallerRestartNeeded*(installerExitCode: int): bool =
  ## The VS installer signals a pending reboot through its EXIT CODE:
  ## `3010` (ERROR_SUCCESS_REBOOT_REQUIRED) is the documented
  ## "succeeded, reboot required" code. `1641` is the
  ## reboot-initiated code — Reprobuild passes `--norestart` so it
  ## should not see 1641, but it is treated as reboot-needed too.
  installerExitCode == 3010 or installerExitCode == 1641

proc vsInstallerSucceeded*(installerExitCode: int): bool =
  ## The installer's success codes: `0` (clean) and `3010` (clean,
  ## reboot pending). Any other code is a failure.
  installerExitCode == 0 or installerExitCode == 3010
