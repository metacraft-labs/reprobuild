## Shared-Development-Services L2 — the dev-env ``activity`` constructor
## surface is enforced by the COMPILER, and a wrong member name is
## refused with a message naming the members the type has.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this
## repo is built with and asserts on its real output. See
## ``service_block_compile_probe.nim`` for why the in-process
## ``compiles`` spelling cannot be used here (short version: measured, it
## answers *false* for every ``package`` block — well-formed or not — so
## both a refusal and its control would be vacuous; filed as
## ``reprobuild-pm/issues/2026-10-08-package-macro-refusal-gates-are-
## vacuous-under-not-compiles.md``).
##
## Governing spec text:
##
## * ``Package-Model.md`` §"Activity declaration shape" — "Required
##   dependencies (``db``, ``assets``) are typed parameters of the
##   activity. The body uses them like ordinary Nim values —
##   ``db.connectionString``, ``assets.bucket`` — with full typechecking
##   and go-to-definition. Configurable defaults (``port``, ``logLevel``,
##   ``poolSize``) live in ``config:``; callers override them through the
##   ``enable`` block."
## * ``Package-Model.md`` §"Systems And Enable Composition" — "``enable
##   myApi(db = mainDb, assets = assets): <overrides>`` is a typed call
##   into the activity's generated entry point. Parameter names and types
##   are checked the same way Nim checks any function call."
## * ``Shared-Development-Services.milestones.org`` L2 ``:gate:`` — "a
##   wrong member name failing the project's recipe **compilation** with a
##   message naming the available members".
##
## WHY THE MEMBER CASE IS THE ONE THAT MATTERS. Nim already refuses
## ``db.connectionStrng`` on its own, with ``undeclared field:
## 'connectionStrng'``. That stops the build and names nothing the author
## could have written instead, so "it does not compile" is satisfied by
## the status quo and says nothing about the gate. The assertions below
## are therefore about the MESSAGE: the activity, the parameter, and the
## members that do exist.
##
## Every refusal is a one-line edit to ONE well-formed recipe, and that
## recipe's own compile is the first test in the file. Two guards, both
## taken from L1's equivalent file and both earned there: each case
## asserts the edit actually changed the source (a ``replace`` whose
## needle has drifted silently returns the input, which would turn a
## refusal test into a second run of the control), and the refusals assert
## on the DIAGNOSTIC rather than only on the exit code.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

type
  DemoDb = object
    connectionString: string
    host: string

const DemoDbValue = DemoDb(connectionString: "postgres://x", host: "h")

package activitySurfacePkg:
  executable apiBin:
    build:
      output("bin/api")

  devEnv:
    activity "default"

    activity api(db: DemoDb):
      ## A parameterised dev-env activity using every part of the shape.
      config:
        ## TCP port the API server binds.
        port: int = 8080
        issuer: string

      let cfg = renderConfigFile("etc/api/config.toml",
        "port = " & $port & "\nissuer = \"" & issuer & "\"\n" &
          "url = \"" & db.connectionString & "\"\n",
        packageName = "activitySurfacePkg")

      service api:
        executable apiBin
        args "--config", cfg.path, "--host", db.host

    activity solo:
      service solo:
        executable apiBin
        args "--solo"

    enable api(db = DemoDbValue):
      port 9090
      issuer "https://login.example.test"

    enable solo
"""

const NoBody = """
import repro_project_dsl

type
  DemoDb = object
    host: string

package activityNoBodyPkg:
  devEnv:
    activity api(db: DemoDb)
"""
  ## Its own source rather than an edit to ``WellFormed``: deleting the
  ## ``:`` from a declaration that HAS a body leaves the body dangling and
  ## Nim stops at ``invalid indentation`` before any macro runs, so the
  ## edit would have measured the parser instead of the walker.

proc editedSource(needle, replacement: string): string =
  ## One-line edit to ``WellFormed``. Raises rather than returning a
  ## misleading result when the needle is not present, so a drifted
  ## fixture is a red test and not a silently vacuous one.
  if not WellFormed.contains(needle):
    raise newException(ValueError,
      "fixture drift: WellFormed no longer contains " & needle)
  result = WellFormed.replace(needle, replacement)
  doAssert result != WellFormed

proc edited(needle, replacement, tag: string): ServiceCompileProbeResult =
  checkRecipeSource(editedSource(needle, replacement), tag)

proc anchorTag(source, statement: string; column: int): string =
  ## The ``recipe.nim(<line>, <column>)`` prefix Nim prints for the line
  ## of ``source`` whose text is ``statement``.
  ##
  ## Computed from the generated source rather than hard-coded, because a
  ## hard-coded line number turns every unrelated fixture edit into a
  ## failure that says nothing about the anchor. The COLUMN is the thing
  ## under test and stays literal.
  var lineNo = 0
  for line in source.splitLines():
    inc lineNo
    if line.strip() == statement:
      return "recipe.nim(" & $lineNo & ", " & $column & ")"
  raise newException(ValueError,
    "fixture drift: the generated source has no line `" & statement & "`")

suite "L2 — the recipe the activity surface is specified for compiles":

  test "the positive control: every part of the shape together":
    # The control for EVERY refusal below, and for the member check in
    # particular: a `when not compiles(...)` guard that fired
    # unconditionally would refuse this recipe too, which is how four
    # refusals could be passed by an implementation that refuses
    # everything. Typed parameter, a member of it in a rendered config
    # AND in a service's args, a `config:` key with a default and one
    # without, two services in two activity bodies, the parameterless
    # ident form, the bare string form, `enable` with an override body
    # and `enable` with none.
    let probe = checkRecipeSource(WellFormed, "activity-wellformed")
    checkpoint(probe.output)
    check probe.ok

suite "L2 — a wrong member name is refused, naming the available members":

  test "it does not compile, and the message names what the type has":
    let probe = edited("db.connectionString", "db.connectionStrng",
      "activity-bad-member")
    checkpoint(probe.output)
    check not probe.ok
    # The gate's clause, assertion by assertion.
    check probe.mentions("has no member `connectionStrng`")
    check probe.mentions("available members of `DemoDb`")
    check probe.mentions("connectionString, host")
    # And enough context to act on it: which activity, which parameter.
    check probe.mentions("activity `api`")
    check probe.mentions("parameter `db`")

  test "the refusal reports at the recipe's own line, not generated code":
    # A diagnostic that lands in `macros_b.nim` is one the author cannot
    # act on. This is measured rather than asserted in a comment because
    # the first implementation did land there: `error(msg)` with no node
    # reports at the macro's own definition site, which is why the
    # refusal takes the offending expression as an `untyped` anchor.
    let source = editedSource("db.connectionString", "db.connectionStrng")
    let probe = checkRecipeSource(source, "activity-bad-member-anchor")
    checkpoint(probe.output)
    check not probe.ok
    # Column 26 is the `.` of `db.connectionStrng` — Nim puts a dot
    # expression's line info on the operator, which is the token the
    # author has to look at.
    check probe.mentions(anchorTag(source,
      "\"url = \\\"\" & db.connectionStrng & \"\\\"\\n\",", 26))

  test "a member on the OTHER parameter use is refused too":
    # `db.host` is read in a service's `args`, several statements away
    # from the rendered config. The walk is over the whole activity body,
    # not over its first statement.
    let probe = edited("db.host", "db.hostname", "activity-bad-member-args")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no member `hostname`")
    check probe.mentions("connectionString, host")

suite "L2 — the `enable` override body is checked against `config:`":

  test "an unknown override key is refused, naming the keys that exist":
    let source = editedSource("      port 9090", "      prt 9090")
    let probe = checkRecipeSource(source, "activity-unknown-override")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no `config:` key named `prt`")
    check probe.mentions("available `config:` keys: port, issuer")
    # Anchored on the statement's own column rather than on the node Nim
    # hangs the line info from — the same correction L1's
    # `m5ServiceStmtAnchor` made for an `nnkAsgn` action.
    check probe.mentions(anchorTag(source, "prt 9090", 7))

  test "a CONSTRUCTOR PARAMETER in the override body is refused":
    # Nim would accept `db = ...` as a named argument, so this one is a
    # deliberate narrowing: the two lists are one parameter list on the
    # generated entry point, and an author who writes a dependency in the
    # override body has misread which half takes it.
    let probe = edited("      port 9090",
      "      db DemoDbValue", "activity-param-as-override")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a CONSTRUCTOR PARAMETER of activity `api`")
    check probe.mentions("enable api(db = ...)")

  test "an override body line that sets nothing is refused, not dropped":
    let probe = edited("      port 9090",
      "      somethingElse(1, 2)", "activity-override-junk")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not an override")
    check probe.mentions("<key> <value>")

suite "L2 — the declaration shapes the walker does not recognise":

  test "a parameter with no declared type is refused":
    let probe = edited("activity api(db: DemoDb):", "activity api(db):",
      "activity-untyped-param")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a typed parameter")
    check probe.mentions("<name>: <Type>")

  test "a `config:` entry that is not a key declaration is refused":
    # `port: 8080` — a value where a type belongs. Without the refusal
    # this lowers to a parameter whose "type" is `8080`, and the author
    # is told about generated code instead of about their own line.
    let probe = edited("        port: int = 8080", "        port: 8080",
      "activity-config-value-for-type")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`config:` key `port` is declared as `8080`")
    check probe.mentions("neither a type with a default nor a bare type")

  test "an activity with parameters but no body is refused by name":
    # Nim reports this as `undeclared identifier: 'api'` -- true of the
    # ACTIVITY NAME, and no help at all. An `nnkObjConstr` head can only
    # be a parameter list, so the refusal is unambiguous; an IDENT or
    # CALL head at the same arity is deliberately left alone, because
    # `activity someName` and `activity nameOf(x)` are legal uses of the
    # string-form proc this milestone must preserve.
    let probe = checkRecipeSource(NoBody, "activity-no-body")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("activity `api`")
    check probe.mentions("an activity with parameters needs a body")

  test "`enable` of an activity this package does not declare is refused":
    # Without this the author is told about `reproActivity_api`, an
    # identifier the generated entry point invented and they never wrote.
    let probe = edited("enable api(db", "enable apiTypo(db",
      "activity-enable-undeclared")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("declares no activity named `apiTypo`")
    check probe.mentions("declared above in this `devEnv:` block: api")
    check not probe.mentions("reproActivity")

  test "`enable` with `:` instead of `=` is refused by name":
    # As an `nnkObjConstr` this would otherwise be reported against a
    # type the author never named.
    let probe = edited("enable api(db = DemoDbValue):",
      "enable api(db: DemoDbValue):", "activity-enable-colon")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("passes its arguments with `=`, not `:`")
