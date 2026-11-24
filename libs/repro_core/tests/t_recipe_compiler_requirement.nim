## The recipe-compiler floor of the 2026-11-24 operator decision: Nim 2.2.10.
##
## The cases that matter are the ones a string compare gets wrong
## ("2.2.4" > "2.2.10" as text) and the ones that must NOT be refused: a
## newer fork, and output that is not a Nim compiler's at all (a test stub).
## Pure functions over strings; nothing is mocked because nothing is run.
import std/[strutils, unittest]
import repro_core/recipe_compiler_requirement

suite "recipe compiler requirement":
  test "2.2.10 is newer than 2.2.4, numerically":
    check nimVersionAtLeast("2.2.10", "2.2.4")
    check not nimVersionAtLeast("2.2.4", "2.2.10")
    check nimVersionAtLeast("2.2.10", "2.2.10")
    check nimVersionAtLeast("2.3.1", "2.2.10")
    check not nimVersionAtLeast("2.2.9", "2.2.10")
    check not nimVersionAtLeast("2.0.16", "2.2.10")
    check nimVersionAtLeast("3.0.0", "2.2.10")

  test "versions that do not parse are never 'at least'":
    check not nimVersionAtLeast("", "2.2.10")
    check not nimVersionAtLeast("garbage", "2.2.10")
    check not nimVersionAtLeast("2.2", "2.2.10")

  test "the release is read from nim --version output":
    check parseNimCompilerVersionOutput(
      "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at 2026\n") ==
      "2.2.10"
    check parseNimCompilerVersionOutput(
      "Nim Compiler Version 2.3.1 [Linux: amd64]") == "2.3.1"
    check parseNimCompilerVersionOutput("fake nim 9.9.9") == ""
    check parseNimCompilerVersionOutput("") == ""

  test "an older compiler is refused with the requirement named":
    let refusal = recipeCompilerRefusal("2.2.4", "REPRO_NIM_COMPILER names")
    check "2.2.10" in refusal
    check "2.2.4" in refusal
    check "REPRO_NIM_COMPILER names" in refusal
    check "operator decision of 2026-11-24" in refusal
    check "2026-10-20-interface-extraction-nimcache-name-exceeds" in refusal
    expect RecipeCompilerTooOldError:
      requireRecipeCompilerVersion("2.2.4", "the lock pins")

  test "2.2.10, a newer fork and an unknown version are not refused":
    check recipeCompilerRefusal("2.2.10", "x") == ""
    check recipeCompilerRefusal("2.3.1", "x") == ""
    check recipeCompilerRefusal("", "x") == ""
    requireRecipeCompilerVersion("2.3.1", "x")
