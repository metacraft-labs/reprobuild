## ``pinned:`` — the package-body block that names lock-pinned siblings a
## recipe only CLONES (Unified-Locking-And-Hooks.md §14.2 item 4).
##
## What this file pins down:
##   * a ``pinned:`` entry reaches ``PackageDef.pinnedSiblings`` and is NOT a
##     tool use: it must never become a ``uses:`` selector, because a
##     selector imports the sibling's recipe into the consumer's compile;
##   * the block's name rules (``pinnedSiblingNameProblem``);
##   * the refusals, at the author's own line: an empty block, an empty or
##     malformed name, a non-literal, a repeated name, and a name the same
##     package also ``uses:``.
##
## The refusals compile real modules out of process: ``package`` cannot
## expand inside ``compiles``, so ``not compiles(...)`` would pass with or
## without the refusal (see ``dsl_port/service_block_compile_probe``). The
## accepted recipe in each group is the positive control: the compiler takes
## the matching legal spelling before the refusal's text is inspected.
##
## Test-double policy: NO mocks, doubles or fakes. The real ``package`` macro,
## the real registry, and the real ``nim`` on real files.

import std/unittest

import repro_project_dsl
import ./dsl_port/service_block_compile_probe

package pinnedRecipe:
  ## A real recipe, so the assertions below are about the real expansion.
  uses:
    "nim >=2.0"
  pinned:
    "codetracer"
    "codetracer-vscode-extension"

package pinnedInlineRecipe:
  ## No dependency block at all: a recipe whose only declaration is a pin.
  pinned: "only-cloned"

suite "pinned: reaches the package and nothing else":

  test "entries land in pinnedSiblings, in order, and are not tool uses":
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName != "pinnedRecipe": continue
      found = true
      check pkg.pinnedSiblings ==
        @["codetracer", "codetracer-vscode-extension"]
      check pkg.toolUses.len == 1
      check pkg.toolUses[0].packageSelector == "nim"
      for use in pkg.allToolUses():
        check use.packageSelector notin pkg.pinnedSiblings
    check found

  test "a recipe may declare nothing but a pin":
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName != "pinnedInlineRecipe": continue
      found = true
      check pkg.pinnedSiblings == @["only-cloned"]
      check pkg.allToolUses().len == 0
    check found

suite "pinned: names are repository names":

  test "pinnedSiblingNameProblem accepts what a repository is called":
    for name in ["codetracer", "codetracer-vscode-extension", "a",
                 "repo.with.dots", "UPPER_snake-9"]:
      check pinnedSiblingNameProblem(name) == ""

  test "pinnedSiblingNameProblem refuses what is not a repository name":
    for name in ["", " ", " codetracer", "codetracer ", "code tracer",
                 "codetracer >=0", "codetracer>=0", "a=b", "a<b", "a,b",
                 "a:b", "a@b", "../codetracer", "deps/codetracer",
                 "a\\b", ".", ".."]:
      checkpoint "name: '" & name & "'"
      check pinnedSiblingNameProblem(name).len > 0

const Head = "import repro_project_dsl\n"

suite "pinned: refusals name the author's line":

  test "a well-formed block compiles (the control for the refusals)":
    let accepted = checkRecipeSource(Head & """
package pinnedControl:
  uses:
    "nim >=2.0"
  pinned:
    "codetracer"
    "codetracer-vscode-extension"
""", "pinned-valid")
    checkpoint accepted.output
    check accepted.ok

  test "a block with no sibling name in it is refused":
    let rejected = checkRecipeSource(Head & """
package pinnedEmpty:
  pinned:
    discard
""", "pinned-empty-block")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: an entry must be a string literal")

  test "an empty name is refused":
    let rejected = checkRecipeSource(Head & """
package pinnedEmptyName:
  pinned:
    ""
""", "pinned-empty-name")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: the sibling name is empty")

  test "a name with a version constraint is refused":
    let rejected = checkRecipeSource(Head & """
package pinnedRange:
  pinned:
    "codetracer >=0"
""", "pinned-range")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: 'codetracer >=0' contains whitespace")

  test "a name that is not a literal is refused":
    let rejected = checkRecipeSource(Head & """
const sibling = "codetracer"
package pinnedExpression:
  pinned:
    sibling
""", "pinned-non-literal")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: an entry must be a string literal")

  test "a name listed twice is refused":
    let rejected = checkRecipeSource(Head & """
package pinnedTwice:
  pinned:
    "codetracer"
    "codetracer"
""", "pinned-twice")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: 'codetracer' is listed twice")

  test "a name the package also uses is refused":
    let rejected = checkRecipeSource(Head & """
package pinnedAndUsed:
  uses:
    "codetracer >=0"
  pinned:
    "codetracer"
""", "pinned-and-used")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("pinned: 'codetracer' is also a `uses:` dependency")
