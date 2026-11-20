## The command line a ``repro.nim`` declares, handed to the program it
## describes.
##
## An ``executable`` with a ``cli:`` section declares that program's command
## line. The ``package`` macro emits, for each one, in every mode
## (``repro_project_dsl/mode``), an exported template
##
## .. code-block:: nim
##   template <name>CliDescription*(generator, T: untyped): untyped
##
## which expands to ``generator(T, "<program>", exported = true):`` followed by
## the ``cli:`` section's body, verbatim. The program supplies the generator,
## so ``repro.nim`` needs no CLI library of its own: clispec's ``cliProgram``,
## confutils' ``cliConfiguration`` (``confutils/clispec_config``) and
## nim-entrypoints' ``cliProgramWithEntryPoint`` (``entrypoints/clispec``) all
## take these arguments:
##
## .. code-block:: nim
##   import clispec
##   import ../repro              # the thin mode: no define
##
##   myprogCliDescription(cliProgram, MyProg)
##
##   let conf = MyProg.load()
##
## What a program has to know:
##
## * **The template's name.** ``<name>`` is the executable's name as written
##   (``executable myprog``, an accent-quoted ``create-dmg``, or
##   ``executable "g++"``) with every run of characters other than ASCII
##   letters and digits turned into one ``_``, the ``_`` at either end
##   dropped, and ``exe_`` put in front of a name that would begin with a
##   digit. Nim compares identifiers ignoring case after the first character
##   and ignoring ``_``, so ``create-dmg`` gives ``create_dmgCliDescription``,
##   which a program may write ``createDmgCliDescription``; ``g++`` gives
##   ``gCliDescription``. A name with no letter or digit is refused.
## * **Two executables whose names map to the same identifier** cannot both
##   have a template. Within one ``package`` that is a compile error naming
##   both. Across two ``package`` blocks of one module, or against any
##   declaration of the name earlier in that module, it is a compile error at
##   the second executable (Nim itself would let the second template replace
##   the first with only a warning). A declaration after the ``package`` is
##   not checked: Nim treats it as an overload of the template. A template of the same name imported from
##   another module is not a collision: the module's own is the one its
##   importers see first, as for any overloaded name.
## * **The program name** passed to the generator (what help and errors
##   print) is the executable's ``name:`` when that is a string literal, the
##   binary the package builds, else the executable's name.
## * **Names the ``cli:`` section uses must be exported from ``repro.nim``.**
##   The template is ``dirty``: its body is resolved where the program
##   expands it, not in ``repro.nim``. Clispec also keeps a ``default``,
##   ``values``, ``optionalValue``, ``implies`` or ``complete`` value as
##   text and parses it again where the generator expands, so even a name
##   that resolved in ``repro.nim`` would be looked up in the program's
##   module. A constant or procedure the section names is therefore written
##   ``DefaultJobs*``, ``defaultJobs*``; an unexported one fails the
##   program's compile, naming the parameter.
## * **Reprobuild's own ``cli:`` words do nothing in a plain generator.**
##   Clispec offers a statement or named argument it does not know to the
##   consumer's extension and ignores it when none claims it, so ``outputs``,
##   ``role``, ``subTools`` and the rest compile under ``cliProgram``; the
##   engine's modes validate them.
## * **The template's parameters are named ``reproCliGenerator`` and
##   ``reproCliType``**, and a template substitutes its parameters wherever
##   they occur in its body: a ``cli:`` section must not use those two names.
##
## Only ``executable`` sections written directly in the ``package`` body are
## read, and only the first ``cli:`` section written directly in an
## executable's body: a section under a ``when`` is not seen. The reading is structural
## (a section is recognized by its head) and examines nothing else, so the
## thin mode can use it without compiling any of the engine.
##
## Imports ``std/macros`` only.

import std/macros

type
  ThinCliSection* = object
    ## One ``executable`` of a ``package`` body that declares a ``cli:``
    ## section.
    executable*: NimNode
      ## The executable's name node, as written.
    program*: string
      ## The program's name: the ``name:`` string literal, else the
      ## executable's name.
    cli*: NimNode
      ## The ``cli:`` section's body, verbatim.

proc isForm(node: NimNode; name: string): bool {.compileTime.} =
  node.kind in {nnkCall, nnkCommand} and node.len > 0 and
    node[0].kind == nnkIdent and node[0].eqIdent(name)

proc nameText(node: NimNode): string {.compileTime.} =
  ## The text of an executable's name: an identifier's spelling (the parts of
  ## an accent-quoted one joined), or a string literal's value.
  case node.kind
  of nnkIdent, nnkSym:
    result = node.strVal
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    result = node.strVal
  of nnkAccQuoted:
    for part in node:
      result.add(nameText(part))
  else:
    result = node.repr

proc stringLiteralOf(node: NimNode): string {.compileTime.} =
  ## The value of a ``name: "x"`` or ``name "x"`` section, or "" when it is
  ## not a string literal.
  var value = node
  if value.kind == nnkStmtList and value.len == 1:
    value = value[0]
  if value.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    value.strVal
  else:
    ""

proc thinCliSections*(body: NimNode): seq[ThinCliSection] {.compileTime.} =
  ## The executables of a ``package`` body that have a ``cli:`` section, in
  ## source order. Only the structure is read: a section is recognized by its
  ## head, and its contents are not examined.
  if body.kind != nnkStmtList:
    return
  for section in body:
    # ``executable <name>:`` -- the head, the name and the block.
    if section.isForm("executable") and section.len == 3 and
        section[2].kind == nnkStmtList:
      var program = nameText(section[1])
      var cli: NimNode = nil
      for item in section[2]:
        if item.isForm("name") and item.len == 2:
          let literal = stringLiteralOf(item[1])
          if literal.len > 0:
            program = literal
        elif item.isForm("cli") and item.len == 2 and
            item[1].kind == nnkStmtList and cli == nil:
          cli = item[1]
      if cli != nil:
        result.add(ThinCliSection(executable: section[1], program: program,
          cli: cli))

proc cliDescriptionName*(executable: string): string {.compileTime.} =
  ## The name of the template that describes ``executable``'s command line
  ## (see the module documentation), or "" when the name has no letter or
  ## digit.
  var pendingSeparator = false
  for ch in executable:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
      if pendingSeparator and result.len > 0:
        result.add('_')
      pendingSeparator = false
      result.add(ch)
    else:
      pendingSeparator = true
  if result.len == 0:
    return
  if result[0] in {'0' .. '9'}:
    result = "exe_" & result
  result.add("CliDescription")

proc identifierKey(name: string): string {.compileTime.} =
  ## Nim's identifier equality: the first character exactly, the rest
  ## ignoring case and ``_``.
  for i, ch in name:
    if i == 0:
      result.add(ch)
    elif ch != '_':
      result.add(if ch in {'A' .. 'Z'}: chr(ord(ch) + 32) else: ch)

proc cliDescriptionTemplates*(body: NimNode): NimNode {.compileTime.} =
  ## The ``<name>CliDescription`` templates of a ``package`` body: one per
  ## executable with a ``cli:`` section (``thinCliSections``).
  result = newStmtList()
  var seen: seq[tuple[key, executable: string]]
  for section in thinCliSections(body):
    let executable = nameText(section.executable)
    let name = cliDescriptionName(executable)
    if name.len == 0:
      error("executable `" & executable & "`: its name has no letter or " &
        "digit, so it cannot name the template that describes its " &
        "command line (`<name>CliDescription`)", section.executable)
    let key = identifierKey(name)
    for earlier in seen:
      if earlier.key == key:
        error("executables `" & earlier.executable & "` and `" & executable &
          "` would both describe their command line as `" & name &
          "` (Nim identifiers ignore case after the first letter and " &
          "`_`, and every run of other characters becomes `_`); rename one",
          section.executable)
    seen.add((key, executable))
    # The call holds the ``cli:`` body itself (one statement list): splicing
    # it into a ``quote`` under a colon would nest one statement list in
    # another, and clispec drops the first parameter of a nested one. The
    # parameters are plain identifiers, the ones the call names.
    let generator = ident"reproCliGenerator"
    let typ = ident"reproCliType"
    let call = newCall(generator, typ, newLit(section.program),
      nnkExprEqExpr.newTree(ident"exported", ident"true"), section.cli)
    let templateName = ident(name)
    templateName.copyLineInfo(section.executable)
    # Nim lets a template silently replace an earlier one of the same
    # signature (a warning, ``ImplicitTemplateRedefinition``), so a second
    # ``package`` of this module declaring the same name is refused here.
    # ``declaredInScope`` at the top level sees this module's own
    # declarations, not imported ones.
    let refusal = nnkPragma.newTree(nnkExprColonExpr.newTree(ident"error",
      newLit("executable `" & executable & "`: `" & name & "`, the " &
        "template that describes its command line, is already declared in " &
        "this module (another executable whose name maps to it, or another " &
        "declaration); rename one")))
    refusal.copyLineInfo(section.executable)
    refusal[0].copyLineInfo(section.executable)
    result.add nnkWhenStmt.newTree(nnkElifBranch.newTree(
      newCall(ident"declaredInScope", ident(name)), newStmtList(refusal)))
    result.add nnkTemplateDef.newTree(
      nnkPostfix.newTree(ident"*", templateName),
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(ident"untyped",
        nnkIdentDefs.newTree(generator, typ, ident"untyped", newEmptyNode())),
      nnkPragma.newTree(ident"dirty"),
      newEmptyNode(),
      newStmtList(call))
