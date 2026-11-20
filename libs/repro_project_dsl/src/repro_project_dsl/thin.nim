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
## ``package`` reads its body as structure: for each ``executable <name>``
## that has a ``cli:`` section it emits the exported template
## ``<name>CliDescription(generator, T)``, which a program instantiates with
## clispec's ``cliProgram`` or confutils' ``cliConfiguration``
## (``repro_project_dsl/cli_description``, where the template's name and the
## rules a ``cli:`` section follows for it are described). Those descriptions
## are what the thin mode exists to hand to a program; the other forms expand
## to nothing.
##
## Imports ``std/macros`` only.

import std/macros

import repro_project_dsl/mode
export mode
import repro_project_dsl/cli_description

macro package*(name: untyped; body: untyped): untyped =
  ## The thin ``package``: for each of its executables with a ``cli:``
  ## section, the exported ``<name>CliDescription`` template a program
  ## instantiates with its CLI library (``repro_project_dsl/cli_description``).
  ## Nothing else of the body is examined.
  discard name
  result = cliDescriptionTemplates(body)

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
