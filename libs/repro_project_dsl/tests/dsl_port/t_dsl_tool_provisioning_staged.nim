## `defaultToolProvisioning` takes an expression, not a literal.
##
## Staged the way `DSL-Macro-Authoring-Guide.md` prescribes and `platforms`
## already is: stage 1 wraps the argument in `withToolProvisioningVocabulary`
## and hands it to the compiler, stage 2 receives the resulting value through a
## `static string` parameter. The macro never inspects what the author wrote.
##
## The point of doing it this way rather than reading the argument as text is
## that a computed mode then costs nothing. A recipe can pick its mode per host
## with an ordinary `when`, and the macro cannot tell that from a literal --
## which is what lets the metacraft workspace stop pinning one mode for every
## host it runs on.
##
## The alternative -- a macro that reads the `when` itself -- means
## re-implementing a Nim expression evaluator inside a macro. The understood
## grammar is always a subset of the language's, and the gap is silent.

import std/unittest

import repro_project_dsl

# The pre-existing literal form. Unchanged behaviour is the compatibility
# contract: every shipped recipe writes this.
package provLiteralPkg:
  defaultToolProvisioning "path"
  build:
    discard

# The vocabulary form. `tarball` here is a real const bound for exactly this
# expression, so a typo is the compiler's undeclared-identifier error.
package provVocabPkg:
  defaultToolProvisioning tarball
  build:
    discard

# `fromSource` is the vocabulary spelling of the model's `from-source`, which
# cannot be an identifier because of the hyphen.
package provFromSourcePkg:
  defaultToolProvisioning fromSource
  build:
    discard

# The motivating form: the mode chosen per host, by Nim, before the macro sees
# it.
package provWhenPkg:
  defaultToolProvisioning(when defined(windows): tarball else: nix)
  build:
    discard

# A mode computed further out still. Stage 2 cannot distinguish this from a
# literal -- the guide's "does `form someComputedValue` work, without a second
# code path?" checklist item.
const ComputedMode = withToolProvisioningVocabulary(
  when defined(windows): tarball else: scoop)
package provComputedPkg:
  defaultToolProvisioning ComputedMode
  build:
    discard

# A package that declares nothing keeps the zero value.
package provAbsentPkg:
  build:
    discard

proc provisioningOf(packageName: string): string =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return pkg.defaultToolProvisioning
  "<package not registered>"

suite "defaultToolProvisioning is a staged expression":

  test "the literal form still works":
    check provisioningOf("provLiteralPkg") == "path"

  test "the vocabulary form resolves to the same model value":
    check provisioningOf("provVocabPkg") == "tarball"

  test "fromSource carries the model's hyphenated spelling":
    # The identifier cannot contain the hyphen the CLI and the model use, so
    # the vocabulary is the one place the two spellings are reconciled.
    check provisioningOf("provFromSourcePkg") == "from-source"

  test "a when-expression selects the mode per host":
    when defined(windows):
      check provisioningOf("provWhenPkg") == "tarball"
    else:
      check provisioningOf("provWhenPkg") == "nix"

  test "a mode computed outside the package works with no second path":
    when defined(windows):
      check provisioningOf("provComputedPkg") == "tarball"
    else:
      check provisioningOf("provComputedPkg") == "scoop"

  test "an undeclared mode leaves the zero value":
    check provisioningOf("provAbsentPkg") == ""

  test "every fixture package registered":
    # Without this, a lookup typo would return the sentinel and the equality
    # checks above would be comparing two wrong things.
    for name in ["provLiteralPkg", "provVocabPkg", "provFromSourcePkg",
                 "provWhenPkg", "provComputedPkg", "provAbsentPkg"]:
      check provisioningOf(name) != "<package not registered>"

suite "the vocabulary stays scoped to the expression":

  test "importing the DSL does not bind the mode names":
    # The guide requires this assertion by name: without it the design
    # silently regresses to module-level consts and nothing notices. `import
    # repro_project_dsl` must not put `tarball` (or `path`, or `nix`) into
    # every consumer's namespace.
    check not declared(path)
    check not declared(nix)
    check not declared(tarball)
    check not declared(scoop)
    check not declared(fromSource)

  test "but they are bound inside the vocabulary scope":
    check withToolProvisioningVocabulary(tarball) == "tarball"
    check withToolProvisioningVocabulary(fromSource) == "from-source"
