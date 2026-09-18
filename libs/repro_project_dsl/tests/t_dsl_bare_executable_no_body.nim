## The bare ``executable foo`` form (a Command node with no body) parses.
##
## ``parseLibrary``'s docstring says it "Mirrors ``parseExecutable``" and
## that both accept a bare, body-less command; ``test_library_macro.nim``
## covers that shape for ``library`` as its "Case 1". The executable side
## never had either the guard or the test, so ``parseExecutable`` ran
## ``let body = node[2]`` unconditionally and a bare ``executable foo``
## aborted compilation with
##
##   Error: index 2 not in 0 .. 1
##
## pointing into ``macros_a.nim`` — an internal macro index error naming
## neither the offending declaration nor the requirement it violated.
##
## WHY THIS TEST CANNOT SILENTLY SELF-PASS. The defect was a COMPILE-TIME
## macro abort, so the bug's signature is "this module does not build".
## Any assertion below therefore only executes in a world where the guard
## is present: with the fix reverted this file does not reach ``suite`` at
## all, and the test binary fails to compile rather than reporting green.
## That makes the compile itself the primary arm; the runtime checks exist
## to pin the PARSED SHAPE, which a mere arity guard could still get wrong
## (e.g. by returning before ``exportName`` / the source location are set).
##
## The ``binaryName == exportName`` check is the one to read carefully. It
## is not aspirational — it documents that a bare declaration names the
## artifact after the NIM IDENT. That is why recipes whose on-disk
## basename is hyphenated or snake_case must still write ``name:``, and
## why making the bare form parse is not the same as making it advisable.
##
## Build it with a PLAIN ``nim c`` — no ``-d:reproProviderMode``, which is
## how it is enrolled in ``repro_tests.nim``. The neighbouring DSL macro
## tests carry a docstring line telling you to pass that define; it is
## stale, and their own enrolments do not pass it. Measured here: with the
## define the binary becomes a provider and exits on "provider protocol
## request/response arguments are required" without running a single
## check, which is a silent-green shape worth not copying.

import std/[unittest]

import repro_project_dsl

package bareExecutableTestPackage:
  uses:
    "nim >=2.2 <3.0"

  # Case 1: bare ``executable foo`` — no body at all. THE REGRESSION ARM.
  executable bare_exe_no_body

  # Case 2: ``executable foo:`` with a ``discard`` body — the shape that
  # already worked, kept adjacent so a future change cannot fix one form
  # by breaking the other.
  executable exe_discard_body:
    discard

  # Case 3: ``name:`` still overrides the ident-derived default.
  executable exe_named:
    name: "some-binary"

  build:
    discard

suite "DSL bare executable (no body)":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "bareExecutableTestPackage":
      pkg = p
      break

  proc exeByName(name: string): ExecutableDef =
    for exe in pkg.executables:
      if exe.exportName == name:
        return exe
    raise newException(ValueError, "executable not found: " & name)

  test "registry sees the test package and all three executables":
    check pkg.packageName == "bareExecutableTestPackage"
    check pkg.executables.len == 3

  test "a bare `executable foo` parses (this compiling at all is the fix)":
    let exe = exeByName("bare_exe_no_body")
    check exe.exportName == "bare_exe_no_body"

  test "a bare executable defaults binaryName to the Nim ident":
    # Not aspirational: this is WHY a hyphenated/snake_case on-disk name
    # still needs an explicit `name:`.
    check exeByName("bare_exe_no_body").binaryName == "bare_exe_no_body"

  test "a bare executable still carries its source location":
    # Guards against an arity fix that returns before these are assigned.
    let exe = exeByName("bare_exe_no_body")
    check exe.sourceFile.len > 0
    check exe.sourceLine > 0

  test "a bare executable declares no CLI commands":
    check exeByName("bare_exe_no_body").commands.len == 0

  test "the `discard` body form is unchanged":
    let exe = exeByName("exe_discard_body")
    check exe.exportName == "exe_discard_body"
    check exe.binaryName == "exe_discard_body"

  test "`name:` still overrides the ident-derived default":
    let exe = exeByName("exe_named")
    check exe.exportName == "exe_named"
    check exe.binaryName == "some-binary"
