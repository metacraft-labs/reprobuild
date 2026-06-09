## M83 Phase D — `ProfileIntent -> Profile` (home-scope) adapter.
##
## The Phase A `repro_profile` macro library builds a `ProfileIntent`
## value at compile-time (encoded into the RBPI envelope by Phase B /
## the Phase C compile edge). The home-apply pipeline (M63-M82) was
## written before the compile-then-apply pipeline existed and consumes
## a parsed `Profile` (the M60 intent layer's source-line-oriented IR
## from `libs/repro_home_intent/`).
##
## This adapter builds a `Profile` value that is BYTE-EQUIVALENT —
## under the apply pipeline's reads — to what `loadProfile` would have
## produced from the equivalent legacy text. Only the structural
## fields the pipeline reads are populated:
##
##   - `profile.path` — the absolute profile root path.
##   - `profile.root` (nkProfileRoot) — name + children.
##   - per-activity `nkActivity` nodes with `activityChildren` of
##     `nkPackageRef` + `nkCondBlock` (predicate guards).
##   - `nkConfigBlock` -> `nkConfigPackage` -> `nkConfigEntry`.
##   - `nkHostsBlock` -> `nkHostsEntry`.
##   - `nkResourcesBlock` -> `nkResourceEntry` -> `nkResourceAttr`.
##
## Line-range / indent fields are left at their defaults (0). The
## apply pipeline does NOT read them; the structural editor (which
## DOES) is never invoked on an adapted profile — the editor operates
## on the user's source text directly.
##
## Resource-kind mapping (macro side -> apply parser side):
##
##   windows.registryValueHKCU  ->  windows.registryValue
##
## Other kinds pass through unchanged.

import std/[tables]

import repro_profile
import repro_home_intent

proc predicateExprToCondBlock(expr: string): IntentNode

proc renderFieldValueAsAttrSource(v: FieldValue): string =
  ## Render a `FieldValue` into the textual form the apply pipeline's
  ## `resourceAttrValue` decoder expects for `resourceAttrValueSource`.
  ## Mirrors the legacy parser's `setValueSource` shape:
  ##   - string value -> `"<escaped>"` (double-quoted, with `\\` / `\"`
  ##     escapes).
  ##   - int / bool / expr -> bare textual form.
  ##   - list of strings -> comma-joined bare text (the legacy parser
  ##     splits on `,` for `env.userPath.entries`).
  case v.kind
  of fvkString:
    var escaped = newStringOfCap(v.s.len + 2)
    escaped.add('"')
    for c in v.s:
      case c
      of '\\': escaped.add("\\\\")
      of '"': escaped.add("\\\"")
      else: escaped.add(c)
    escaped.add('"')
    escaped
  of fvkInt:
    $v.i
  of fvkBool:
    if v.b: "true" else: "false"
  of fvkExpr:
    v.expr
  of fvkList:
    # Legacy parser convention: comma-separated entries (used for
    # `env.userPath.entries`). Items are not individually quoted —
    # they are the raw entries (PATH segments).
    var s = ""
    for i, item in v.items:
      if i > 0:
        s.add(',')
      s.add(item)
    s

proc renderDependsOnAsAttrSource(deps: seq[ResourceAddress]): string =
  ## Build the `depends_on = ["kind:name", ...]` literal source. The
  ## home parser's `parseDependsOnAttr` reads exactly this shape.
  var s = "["
  for i, d in deps:
    if i > 0:
      s.add(", ")
    s.add('"')
    s.add($d)
    s.add('"')
  s.add(']')
  s

proc mapResourceKind(kind: string): string =
  ## Macro-side kind tag -> apply-side kind tag. Phase A's resource
  ## constructors emit `windows.registryValueHKCU` for the home-scope
  ## HKCU registry value; the apply parser (M68) calls it
  ## `windows.registryValue`. The system-scope `windows.registryValueHKLM`
  ## is handled by the system adapter.
  case kind
  of "windows.registryValueHKCU": "windows.registryValue"
  else: kind

proc buildActivityElement(elem: ActivityElement): IntentNode =
  case elem.kind
  of aekPackageRef:
    result = IntentNode(kind: nkPackageRef,
      packageName: elem.pkgName,
      packageVersion: elem.pkgVersion,
      packageBinaries: elem.pkgBinaries,
      packageLine: 0,
      startLine: 0, endLine: 0, indent: 0)
  of aekWhenGuard:
    result = predicateExprToCondBlock(elem.predicate.expr)
    for inner in elem.guardedBody:
      result.condChildren.add(buildActivityElement(inner))

proc predicateExprToCondBlock(expr: string): IntentNode =
  let ast = parsePredicate("", expr, 0)
  let canon = canonicalize(expr, "", 0)
  result = IntentNode(kind: nkCondBlock,
    keyword: ckWhen,
    predicateSource: expr,
    predicateAst: ast,
    canonicalPredicate: canon,
    condHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)

proc buildActivity(act: ActivityIntent): IntentNode =
  result = IntentNode(kind: nkActivity,
    activityName: act.name,
    activityHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  for elem in act.body:
    result.activityChildren.add(buildActivityElement(elem))

proc buildConfigBlock(overrides: seq[ConfigOverride]): IntentNode =
  result = IntentNode(kind: nkConfigBlock,
    configHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  # Group overrides by package, preserving first-occurrence order.
  var pkgOrder: seq[string]
  var byPkg: Table[string, seq[ConfigOverride]]
  for ov in overrides:
    if ov.pkg notin byPkg:
      pkgOrder.add(ov.pkg)
      byPkg[ov.pkg] = @[]
    byPkg[ov.pkg].add(ov)
  for pkgName in pkgOrder:
    var pkgNode = IntentNode(kind: nkConfigPackage,
      configPackageName: pkgName,
      configPackageHeaderLine: 0,
      startLine: 0, endLine: 0, indent: 0)
    for ov in byPkg[pkgName]:
      let valueSource =
        case ov.value.kind
        of cvkString:
          var s = newStringOfCap(ov.value.s.len + 2)
          s.add('"')
          for c in ov.value.s:
            case c
            of '\\': s.add("\\\\")
            of '"': s.add("\\\"")
            else: s.add(c)
          s.add('"')
          s
        of cvkInt: $ov.value.i
        of cvkBool: (if ov.value.b: "true" else: "false")
        of cvkExpr: ov.value.expr
      pkgNode.configEntries.add(IntentNode(kind: nkConfigEntry,
        configKey: ov.key,
        configValueSource: valueSource,
        configEntryLine: 0,
        startLine: 0, endLine: 0, indent: 0))
    result.configPackages.add(pkgNode)

proc buildHostsBlock(hosts: Table[string, seq[string]]): IntentNode =
  result = IntentNode(kind: nkHostsBlock,
    hostsHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  for hostName, acts in hosts.pairs:
    result.hostsEntries.add(IntentNode(kind: nkHostsEntry,
      hostName: hostName,
      hostActivities: acts,
      hostEntryLine: 0,
      startLine: 0, endLine: 0, indent: 0))

proc mapHomeFieldName(resourceKind, fieldName: string): string =
  ## The Phase A `windowsRegistryValueHKCU` macro stores the typed
  ## REG_* value kind under the field name `kind`, while the apply
  ## parser reads `valueKind`. Rename on the way out so the apply
  ## pipeline finds the attribute under the expected key. Other
  ## resource kinds use the same field name on both sides; the
  ## switch is a no-op for them.
  if resourceKind == "windows.registryValueHKCU" and fieldName == "kind":
    return "valueKind"
  fieldName

proc buildResourceEntry(r: ResourceIntent): IntentNode =
  result = IntentNode(kind: nkResourceEntry,
    resourceKind: mapResourceKind(r.kind),
    resourceAddress: r.address,
    resourceHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  for fieldName, fieldValue in r.fields.pairs:
    result.resourceAttrs.add(IntentNode(kind: nkResourceAttr,
      resourceAttrKey: mapHomeFieldName(r.kind, fieldName),
      resourceAttrValueSource: renderFieldValueAsAttrSource(fieldValue),
      resourceAttrLine: 0,
      startLine: 0, endLine: 0, indent: 0))
  if r.dependsOn.len > 0:
    result.resourceAttrs.add(IntentNode(kind: nkResourceAttr,
      resourceAttrKey: "depends_on",
      resourceAttrValueSource: renderDependsOnAsAttrSource(r.dependsOn),
      resourceAttrLine: 0,
      startLine: 0, endLine: 0, indent: 0))

proc isHomeScopeResource(kind: string): bool =
  ## Home-scope resource kinds. The system-scope kinds (capability,
  ## optionalFeature, service, vsInstaller, systemDefault, systemdSystemUnit,
  ## launchdSystemDaemon, fsSystemFile, envSystemVariable, passwdUser,
  ## windows.registryValueHKLM) are filtered out of the home adapter's
  ## resources block and surface in the system adapter instead.
  ##
  ## M83 step 4b: `systemd.userUnit` + `launchd.userAgent` are POSIX
  ## per-user services — home-scope, NOT system-scope. They live
  ## under `~/.config/systemd/user/` / `~/Library/LaunchAgents/`
  ## respectively and are reconciled by `systemctl --user` /
  ## `launchctl bootstrap gui/<uid>` unelevated. The system-scope
  ## peers `systemd.systemUnit` + `launchd.systemDaemon` (under
  ## `/etc/systemd/system/` / `/Library/LaunchDaemons/`) are
  ## elevated and live in `adapter_system.nim`.
  case kind
  of "env.userPath", "env.userVariable", "fs.managedBlock",
     "shell.integration", "windows.registryValueHKCU",
     "windows.startup", "fs.userFile", "vscode.extension",
     "systemd.userUnit", "launchd.userAgent",
     "linux.dconfKey", "linux.kdeConfigKey",
     "pkg.homebrewFormula", "pkg.homebrewCask":
    true
  else:
    false

proc buildResourcesBlock(resources: seq[ResourceIntent]): IntentNode =
  result = IntentNode(kind: nkResourcesBlock,
    resourcesHeaderLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  for r in resources:
    if not isHomeScopeResource(r.kind):
      continue
    result.resourcesEntries.add(buildResourceEntry(r))

proc profileIntentToHomeProfile*(p: ProfileIntent;
                                 profilePath: string): Profile =
  ## Build a `Profile` value equivalent to what
  ## `repro_home_intent.loadProfile(profilePath)` would return for the
  ## same logical profile. The adapted profile carries only the
  ## structural fields the apply pipeline reads; `lines`, `lineEnding`,
  ## `indentStep`, etc. are left at sensible defaults (the apply
  ## pipeline never touches them, and the structural editor is never
  ## invoked on an adapted profile).
  ##
  ## Mapping:
  ##   ProfileIntent.name        -> nkProfileRoot.name
  ##   ProfileIntent.activities  -> seq[nkActivity] children
  ##     ActivityElement of aekPackageRef -> nkPackageRef child
  ##     ActivityElement of aekWhenGuard  -> nkCondBlock with predicate AST
  ##   ProfileIntent.configOverrides -> nkConfigBlock with per-pkg sub-blocks
  ##   ProfileIntent.hosts       -> nkHostsBlock with "<host>": [activities]
  ##   ProfileIntent.resources   -> nkResourcesBlock with home-scope kinds
  ##     ResourceIntent.fields   -> nkResourceAttr children
  ##     ResourceIntent.dependsOn-> the depends_on attribute
  let root = IntentNode(kind: nkProfileRoot,
    name: p.name,
    headerLine: 0,
    startLine: 0, endLine: 0, indent: 0)
  for act in p.activities:
    root.children.add(buildActivity(act))
  if p.configOverrides.len > 0:
    root.children.add(buildConfigBlock(p.configOverrides))
  if p.hosts.len > 0:
    root.children.add(buildHostsBlock(p.hosts))
  # The resources block is always present (even if empty) so the
  # apply pipeline's `findResourcesBlock` returns a stable shape; an
  # empty block degenerates to a no-op desired set just like an
  # empty `resources:` in legacy text.
  root.children.add(buildResourcesBlock(p.resources))
  result = Profile(path: profilePath,
    lines: @[],
    lineEnding: "\n",
    hasTrailingNewline: true,
    root: root,
    indentStep: 2,
    adapterPreference: p.adapterPreference)
  ## M2.5: thread the per-OS adapter preference through the macro->text
  ## adapter so both code paths feed the same field into the apply
  ## pipeline downstream.
