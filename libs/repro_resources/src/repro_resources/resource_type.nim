## RP4 (Provider-Runtime-Protocol-v1 §5): the ``resourceType`` DSL macro
## — the slice-2 deferred piece of ``Composable-Resource-Types.md``.
##
## A block of the form::
##
##   resourceType "mock.thing", determinism = rdVolatile:
##     wrapper: mockThing
##     attr value: string
##     attr note: string
##     driver: myDriver
##
## lowers to (in one module-init emission):
##
##   1. an attribute record type ``<Wrapper>Attrs`` with one field per
##      ``attr <name>: <type>`` line;
##   2. ``registerResourceProvider(ResourceProviderDef(...))`` — the
##      slice-2 generic-lane registration (so the runtime reconciler can
##      drive it);
##   3. ``registerExtension[<Wrapper>Attrs](typeId)`` — the marshaller
##      (so the attrs box crosses the provider->client boundary);
##   4. a typed wrapper proc ``<wrapper>(address; <attrs...>;
##      dependsOn): ResourceRef`` that lowers to ``resource(...)`` — the
##      composable, strongly-typed surface a consumer binds;
##   5. ``registerResourceTypeInterface(ResourceTypeInterfaceDef(...))``
##      — the InterfaceResource contribution, so the resource type
##      participates in interface lifting exactly as ``executable …
##      cli:`` does (SC-8). ``toProjectInterface`` folds this into
##      ``ProjectInterface.publicResources``.
##
## The five entry-point descriptors (identity/digest/observe/plan/apply)
## are derived as ``<typeId>.<op>`` — the ``providerEntrypointId`` a
## consumer's resource op lowers to an ``InvokeEntryPoint`` against
## (RP5). ``plan`` is a first-class protocol op even though the native
## generic driver folds planning into ``reconcileResources``; the
## contract carries the full protocol surface.

import std/[macros, strutils]

# NOTE: this module emits code that references ``resource``,
# ``ResourceRef`` (from ``repro_resources/collect``),
# ``ResourceProviderDef`` (from ``repro_resources/instance``),
# ``registerExtension`` (from ``repro_project_dsl``), and
# ``ResourceAttrDef`` / ``ResourceTypeInterfaceDef`` /
# ``registerResourceTypeInterface`` (also from ``repro_project_dsl``).
# Those symbols resolve at the macro's EXPANSION site through the
# ``repro_resources`` umbrella's ``export``s, so this module needs no
# imports of its own beyond ``std/macros`` + ``std/strutils``.

macro resourceType*(typeIdArg: static string; body: untyped): untyped =
  ## The RP4 resource-type declaration macro. The header is
  ## ``resourceType "<typeId>":`` and the body carries:
  ##
  ##   * ``attrs: <TypeName>``  — the USER-DEFINED attribute record type
  ##     the driver operates on (referenced verbatim by the emitted
  ##     ``registerExtension`` + wrapper). Keeping the attrs type
  ##     user-owned (rather than macro-synthesised) is what lets the
  ##     hand-written ``{.nimcall.}`` driver unbox
  ##     ``TypedExtensionBox[<TypeName>]`` — the same type the wrapper
  ##     boxes — matching the slice-2 lane exactly.
  ##   * ``wrapper: <ident>``   — the name of the emitted typed wrapper.
  ##   * ``determinism: <rd..>``— the provider's determinism class.
  ##   * ``driver: <expr>``     — a ``ResourceProviderDriver`` value.
  ##   * ``attr <name>: <type>``— one per public attribute; these lines
  ##     are the INTERFACE schema (they must mirror the ``attrs`` type's
  ##     fields). Renaming one shifts the exported ``InterfaceResource``.
  var wrapperName = ""
  var attrsTypeIdent: NimNode = nil
  var determinismExpr: NimNode = nil
  var driverExpr: NimNode = nil
  var attrNames: seq[string] = @[]
  var attrTypes: seq[NimNode] = @[]

  proc unwrapBody(n: NimNode): NimNode =
    ## A ``key: value`` line inside a block parses as a StmtList holding
    ## the value; unwrap a single-statement StmtList to its inner expr.
    if n.kind == nnkStmtList and n.len == 1: n[0] else: n

  for stmt in body:
    # ``attr <name>: <type>`` parses as Command(attr, name, StmtList(type)).
    if stmt.kind == nnkCommand and stmt.len == 3 and
        stmt[0].kind == nnkIdent and stmt[0].strVal == "attr":
      attrNames.add(stmt[1].strVal)
      attrTypes.add(unwrapBody(stmt[2]))
      continue
    # ``attrs: <T>`` / ``wrapper: <ident>`` / ``driver: <expr>`` /
    # ``determinism: <expr>`` parse as Call(<key>, StmtList(<value>)).
    if stmt.kind == nnkCall and stmt.len == 2 and
        stmt[0].kind == nnkIdent:
      let key = stmt[0].strVal
      let val = unwrapBody(stmt[1])
      case key
      of "attrs": attrsTypeIdent = val
      of "wrapper": wrapperName = val.strVal
      of "driver": driverExpr = val
      of "determinism": determinismExpr = val
      else: error("resourceType: unknown field '" & key & "'", stmt)
      continue
    error("resourceType: unexpected statement — expected 'attr <name>: " &
      "<type>', 'attrs: <Type>', 'wrapper: <ident>', 'determinism: " &
      "<expr>', or 'driver: <expr>'", stmt)

  if attrsTypeIdent == nil:
    error("resourceType: an 'attrs: <Type>' line is required", body)
  if determinismExpr == nil:
    error("resourceType: a 'determinism: rd...' line is required", body)
  if driverExpr == nil:
    error("resourceType: a 'driver: <ResourceProviderDriver>' line is " &
      "required", body)
  if wrapperName.len == 0:
    error("resourceType: a 'wrapper: <ident>' line is required", body)

  let wrapperIdent = ident(wrapperName)
  let determinismInterfaceDefIdent = genSym(nskProc, "resourceTypeInterfaceDef")

  # ── the typed wrapper proc ───────────────────────────────────────
  # proc <wrapper>(address: string; <attr>: <type>...; dependsOn: seq[string] = @[]): ResourceRef =
  #   resource(<typeId>, address, <AttrsType>(<attr>: <attr>...), dependsOn)
  var wrapperParams = @[ident("ResourceRef")]
  wrapperParams.add(newIdentDefs(ident("address"), ident("string")))
  for i in 0 ..< attrNames.len:
    wrapperParams.add(newIdentDefs(ident(attrNames[i]), attrTypes[i]))
  wrapperParams.add(newIdentDefs(
    ident("dependsOn"),
    nnkBracketExpr.newTree(ident("seq"), ident("string")),
    nnkPrefix.newTree(ident("@"), nnkBracket.newTree())))
  var attrsCtor = nnkObjConstr.newTree(attrsTypeIdent)
  for i in 0 ..< attrNames.len:
    attrsCtor.add(nnkExprColonExpr.newTree(
      ident(attrNames[i]), ident(attrNames[i])))
  let wrapperBody = newStmtList(
    nnkCall.newTree(
      ident("resource"),
      newLit(typeIdArg),
      ident("address"),
      attrsCtor,
      ident("dependsOn")))
  let wrapperProc = newProc(
    postfix(wrapperIdent, "*"),
    wrapperParams,
    wrapperBody)

  # ── 2/3/5. the module-init registrations ─────────────────────────
  # Emit an init proc that registers the provider, the marshaller, and
  # the interface record, then call it once at module init.
  var attrDefEntries = newNimNode(nnkBracket)
  for i in 0 ..< attrNames.len:
    attrDefEntries.add(nnkObjConstr.newTree(
      ident("ResourceAttrDef"),
      nnkExprColonExpr.newTree(ident("name"), newLit(attrNames[i])),
      nnkExprColonExpr.newTree(ident("nimType"),
        newLit(attrTypes[i].repr.strip()))))
  let attrDefSeq = nnkPrefix.newTree(ident("@"), attrDefEntries)

  let regBody = newStmtList(
    # registerResourceProvider(ResourceProviderDef(typeId, determinism, driver))
    nnkCall.newTree(
      ident("registerResourceProvider"),
      nnkObjConstr.newTree(
        ident("ResourceProviderDef"),
        nnkExprColonExpr.newTree(ident("typeId"), newLit(typeIdArg)),
        nnkExprColonExpr.newTree(ident("determinism"), determinismExpr),
        nnkExprColonExpr.newTree(ident("driver"), driverExpr))),
    # registerExtension[<Attrs>](typeId)
    nnkCall.newTree(
      nnkBracketExpr.newTree(ident("registerExtension"), attrsTypeIdent),
      newLit(typeIdArg)),
    # registerResourceTypeInterface(ResourceTypeInterfaceDef(...))
    nnkCall.newTree(
      ident("registerResourceTypeInterface"),
      nnkObjConstr.newTree(
        ident("ResourceTypeInterfaceDef"),
        nnkExprColonExpr.newTree(ident("typeId"), newLit(typeIdArg)),
        nnkExprColonExpr.newTree(ident("determinismOrd"),
          nnkCall.newTree(ident("int"),
            nnkCall.newTree(ident("ord"), determinismExpr))),
        nnkExprColonExpr.newTree(ident("attributes"), attrDefSeq),
        nnkExprColonExpr.newTree(ident("identityEntrypoint"),
          newLit(typeIdArg & ".identity")),
        nnkExprColonExpr.newTree(ident("digestEntrypoint"),
          newLit(typeIdArg & ".digest")),
        nnkExprColonExpr.newTree(ident("observeEntrypoint"),
          newLit(typeIdArg & ".observe")),
        nnkExprColonExpr.newTree(ident("planEntrypoint"),
          newLit(typeIdArg & ".plan")),
        nnkExprColonExpr.newTree(ident("applyEntrypoint"),
          newLit(typeIdArg & ".apply")))))
  let regProc = newProc(determinismInterfaceDefIdent, @[newEmptyNode()], regBody)

  result = newStmtList(
    wrapperProc,
    regProc,
    newCall(determinismInterfaceDefIdent))
