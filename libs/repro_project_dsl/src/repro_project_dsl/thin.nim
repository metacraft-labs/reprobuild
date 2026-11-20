## The thin mode of the project DSL: what ``import reprobuild`` provides
## when no mode define is given (``repro_project_dsl/mode``).
##
## A program imports its project's ``repro.nim`` to read the command line its
## ``executable`` sections declare, and must not compile the engine to do
## so. In this mode every top-level DSL form exists as an ``untyped`` macro,
## so a ``repro.nim`` still parses and resolves its forms, but nothing inside
## them is type-checked: ``uses:``, ``build:``, ``config:`` and the other
## sections are never looked at, and their code may name procedures and types
## that only the full modes define.
##
## ``package`` reads its body as structure: it finds each ``executable <name>``
## that has a ``cli:`` section. Those are the descriptions the thin mode exists
## to hand to a program; the other forms expand to nothing.
##
## Imports ``std/macros`` only.

import std/macros

import repro_project_dsl/mode
export mode

type
  ThinCliSection* = object
    ## One ``executable`` of a ``package`` body that declares a ``cli:``
    ## section: the executable's name and the section's body, verbatim.
    executable*: NimNode
    cli*: NimNode

proc isForm(node: NimNode; name: string): bool {.compileTime.} =
  node.kind in {nnkCall, nnkCommand} and node.len > 0 and
    node[0].kind == nnkIdent and node[0].eqIdent(name)

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
      for item in section[2]:
        if item.isForm("cli") and item.len == 2 and
            item[1].kind == nnkStmtList:
          result.add(ThinCliSection(executable: section[1], cli: item[1]))

macro package*(name: untyped; body: untyped): untyped =
  ## The thin ``package``: it finds the ``cli:`` sections of its
  ## executables (``thinCliSections``) and nothing else. It does not register
  ## them yet, so for now it expands to nothing.
  discard name
  discard thinCliSections(body)
  result = newStmtList()

# Every other top-level form of the full DSL, with nothing to keep in this
# mode. Each takes whatever arguments the full form takes, unexamined.

macro defineCliInterface*(args: varargs[untyped]): untyped =
  ## A tool's command-line interface for the engine's typed tool calls.
  discard args
  result = newStmtList()

macro resourceModule*(args: varargs[untyped]): untyped =
  ## The module declaring a project's resource types.
  discard args
  result = newStmtList()

macro provisioningFor*(args: varargs[untyped]): untyped =
  ## Tool provisioning contributed for a target.
  discard args
  result = newStmtList()

macro projectExtension*(args: varargs[untyped]): untyped =
  ## An extension of another project.
  discard args
  result = newStmtList()

macro depends_on*(args: varargs[untyped]): untyped =
  ## A package's dependencies, declared outside its ``package`` block.
  discard args
  result = newStmtList()

macro lockFile*(args: varargs[untyped]): untyped =
  ## A named lock-file declaration.
  discard args
  result = newStmtList()
