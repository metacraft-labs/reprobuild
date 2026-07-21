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

proc nodeLineInfo(n: NimNode): tuple[file: string; line: int] =
  ## RP8 (LSP go-to-definition): the compile-time source location of a
  ## ``NimNode``, mirroring ``macros_a.nim``'s ``lineFile`` helper. The
  ## ``resourceType`` macro records this onto the emitted
  ## ``ResourceTypeInterfaceDef`` (the block's location) and each
  ## ``ResourceAttrDef`` (the attribute declaration's own location) so the
  ## interface artifact carries a real definition site for go-to-def — the
  ## same file/line surface an ``executable … cli:`` decl already ships.
  ## ``filename`` is used verbatim (as the ``executable``/``command``/``param``
  ## captures do); the lift compiles the producer module by the absolute path
  ## the ``resourceModule`` decl resolves, so ``file`` resolves to the producer
  ## module for the extractor's ``sameSourceFile`` / a caller's ``sameFile``.
  let info = n.lineInfoObj()
  (info.filename, info.line)

# NOTE: this module emits code that references ``resource``,
# ``ResourceRef`` (from ``repro_resources/collect``),
# ``ResourceProviderDef`` (from ``repro_resources/instance``),
# ``registerExtension`` (from ``repro_project_dsl``), and
# ``ResourceAttrDef`` / ``ResourceTypeInterfaceDef`` /
# ``registerResourceTypeInterface`` (also from ``repro_project_dsl``).
# Those symbols resolve at the macro's EXPANSION site through the
# ``repro_resources`` umbrella's ``export``s, so this module needs no
# imports of its own beyond ``std/macros`` + ``std/strutils``.

macro resourceType*(typeIdNode: untyped; body: untyped): untyped =
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
  var attrLocs: seq[tuple[file: string; line: int]] = @[]

  # The typeId is the ``resourceType "<id>":`` header expression. Taken as an
  # ``untyped`` node (not ``static string``) so its OWN line info is the
  # header's line — the ``resourceType`` decl's definition site — for RP8
  # go-to-def. (A ``static string`` param carries no callsite line info, and
  # ``body``'s line info is the first BODY statement, one line too low.)
  #
  # Two callsite forms are accepted, matching the old ``static string`` param's
  # runtime semantics (which folded both to the same string value):
  #   * a string literal — ``resourceType "vm_harness.container":``
  #   * a ``const`` identifier bound to a string — ``resourceType TypeContainer:``
  # For BOTH we pass the node THROUGH into the emitted code wherever the runtime
  # typeId VALUE is needed, so a const resolves at compile/runtime exactly as it
  # did under ``static string``. Only the go-to-def location uses the node's
  # lineinfo (which is correct for a literal AND an ident callsite), not its
  # value. ``typeIdExpr`` is that pass-through value node.
  case typeIdNode.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit,
     nnkIdent, nnkSym, nnkAccQuoted, nnkDotExpr:
    discard
  else:
    error("resourceType: the type id must be a string literal or a const " &
      "bound to a string, e.g. resourceType \"vm_harness.container\": or " &
      "resourceType TypeContainer:", typeIdNode)
  let typeIdExpr = copyNimTree(typeIdNode)

  proc entrypointExpr(suffix: string): NimNode =
    ## ``<typeId> & "<suffix>"`` as an emitted runtime expression, so a
    ## const-ident typeId folds to its string value at compile/runtime just as
    ## a string literal does — no macro-time ``strVal`` of the (possibly
    ## non-literal) node is needed.
    nnkInfix.newTree(ident("&"), copyNimTree(typeIdExpr), newLit(suffix))

  # RP8: the ``resourceType`` block's own source location — the header line
  # (the ``resourceType "<id>":`` decl), captured from the type-id literal's
  # node so go-to-def on the wrapper/typeId lands on the decl, not its body.
  let typeLoc = nodeLineInfo(typeIdNode)

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
      # RP8: capture THIS attribute declaration's own line info so an attr's
      # go-to-def points at the ``attr <name>: <type>`` line, not the block.
      attrLocs.add(nodeLineInfo(stmt))
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
      copyNimTree(typeIdExpr),
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
        newLit(attrTypes[i].repr.strip())),
      # RP8: this attribute's own declaration location.
      nnkExprColonExpr.newTree(ident("sourceFile"),
        newLit(attrLocs[i].file)),
      nnkExprColonExpr.newTree(ident("sourceLine"),
        newLit(attrLocs[i].line))))
  let attrDefSeq = nnkPrefix.newTree(ident("@"), attrDefEntries)

  let regBody = newStmtList(
    # registerResourceProvider(ResourceProviderDef(typeId, determinism, driver))
    nnkCall.newTree(
      ident("registerResourceProvider"),
      nnkObjConstr.newTree(
        ident("ResourceProviderDef"),
        nnkExprColonExpr.newTree(ident("typeId"), copyNimTree(typeIdExpr)),
        nnkExprColonExpr.newTree(ident("determinism"), determinismExpr),
        nnkExprColonExpr.newTree(ident("driver"), driverExpr))),
    # registerExtension[<Attrs>](typeId)
    nnkCall.newTree(
      nnkBracketExpr.newTree(ident("registerExtension"), attrsTypeIdent),
      copyNimTree(typeIdExpr)),
    # registerResourceTypeInterface(ResourceTypeInterfaceDef(...))
    nnkCall.newTree(
      ident("registerResourceTypeInterface"),
      nnkObjConstr.newTree(
        ident("ResourceTypeInterfaceDef"),
        nnkExprColonExpr.newTree(ident("typeId"), copyNimTree(typeIdExpr)),
        nnkExprColonExpr.newTree(ident("determinismOrd"),
          nnkCall.newTree(ident("int"),
            nnkCall.newTree(ident("ord"), determinismExpr))),
        nnkExprColonExpr.newTree(ident("attributes"), attrDefSeq),
        # ``<typeId>.<op>`` entrypoint ids: emit a runtime ``&`` against the
        # typeId node so a const-ident typeId resolves at compile/runtime
        # (matching the old ``static string`` folding) rather than requiring a
        # macro-time literal.
        nnkExprColonExpr.newTree(ident("identityEntrypoint"),
          entrypointExpr(".identity")),
        nnkExprColonExpr.newTree(ident("digestEntrypoint"),
          entrypointExpr(".digest")),
        nnkExprColonExpr.newTree(ident("observeEntrypoint"),
          entrypointExpr(".observe")),
        nnkExprColonExpr.newTree(ident("planEntrypoint"),
          entrypointExpr(".plan")),
        nnkExprColonExpr.newTree(ident("applyEntrypoint"),
          entrypointExpr(".apply")),
        # RP8: the ``resourceType`` block's own declaration location, so
        # go-to-def on the wrapper/typeId lands on the producer decl. Flows
        # through the extractor verbatim (repro_interface_artifacts) and is
        # normalized out of the fingerprint (TI3 ``forFingerprint`` path).
        nnkExprColonExpr.newTree(ident("sourceFile"), newLit(typeLoc.file)),
        nnkExprColonExpr.newTree(ident("sourceLine"),
          newLit(typeLoc.line)))))
  let regProc = newProc(determinismInterfaceDefIdent, @[newEmptyNode()], regBody)

  result = newStmtList(
    wrapperProc,
    regProc,
    newCall(determinismInterfaceDefIdent))
