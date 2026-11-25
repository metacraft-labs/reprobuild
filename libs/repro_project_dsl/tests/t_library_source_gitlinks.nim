## Cross-Repo-Source-Consumption §4.2a.2a: the bounded ``sourceGitlinks``
## form of a ``library`` body.
##
## What is checked:
##
## * a declared literal sequence reaches the runtime ``LibraryDef`` as typed
##   ``GitlinkSourceRequirement`` values, in order, and a library without
##   the form carries none (the SC-12 default);
## * the parser REJECTS, at compile time, everything the spec excludes:
##   an action, command, script, pool, environment, output, branch or
##   revision field inside the form, a non-literal expression, an absolute
##   or traversing path, a backslash, an empty form, a duplicate and a
##   portable case collision. Each refusal is paired with the accepted
##   positive control below it, so a probe that fails for an unrelated
##   reason (a broken fixture, a missing import) cannot pass as a refusal.
##
## Test-double policy: NO mocks. The positive half inspects the real
## registry the real ``package`` macro filled; the refusals run the real
## compiler on real fixture files (``checkRecipeSource``; see its module
## note for why ``compiles`` cannot probe a ``package`` macro).

import std/[strutils, unittest]

import repro_project_dsl
import ./dsl_port/service_block_compile_probe

package librarySourceGitlinksTestPackage:
  uses:
    "nim >=2.2 <3.0"

  library with_gitlinks:
    exportedPath "src"
    sourceGitlinks:
      "src/vendor/yoga"
      "src/vendor/other"

  library one_gitlink:
    sourceGitlinks: "src/third_party/lib"

  library without_gitlinks

proc libByName(name: string): LibraryDef =
  for pkg in registeredPackages():
    if pkg.packageName == "librarySourceGitlinksTestPackage":
      for lib in pkg.libraries:
        if lib.name == name:
          return lib
  raise newException(ValueError, "library not found: " & name)

proc recipeWith(body: string): string =
  "import repro_project_dsl\n" &
    "package probeGitlinks:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  library probe:\n" &
    body

suite "library sourceGitlinks (§4.2a.2a)":
  test "declared paths reach the runtime LibraryDef in order":
    let lib = libByName("with_gitlinks")
    check lib.exportedPath == "src"
    check lib.sourceGitlinks == @[
      GitlinkSourceRequirement(relativePath: "src/vendor/yoga"),
      GitlinkSourceRequirement(relativePath: "src/vendor/other")]
    check libByName("one_gitlink").sourceGitlinks ==
      @[GitlinkSourceRequirement(relativePath: "src/third_party/lib")]

  test "a library without the form carries no requirement":
    check libByName("without_gitlinks").sourceGitlinks.len == 0

  test "the lexical path rule refuses what is not a normalized relative path":
    check gitlinkRequirementPathProblem("src/vendor/yoga") == ""
    check gitlinkRequirementPathProblem("/abs/yoga").contains("absolute")
    check gitlinkRequirementPathProblem("src/../yoga").contains("..")
    check gitlinkRequirementPathProblem("src/./yoga").contains("'.'")
    check gitlinkRequirementPathProblem("src//yoga").contains("empty")
    check gitlinkRequirementPathProblem("src\\yoga").contains("backslash")
    check gitlinkRequirementPathProblem("src/yoga/").contains("separator")
    check gitlinkRequirementPathProblem("C:/yoga").contains("drive")
    check gitlinkRequirementPathProblem("").contains("empty")
    check gitlinkPortableCaseKey("Src/Yoga") == gitlinkPortableCaseKey("src/yoga")

  test "the parser accepts the literal form (positive control)":
    let accepted = checkRecipeSource(recipeWith(
      "    sourceGitlinks:\n      \"src/vendor/yoga\"\n"),
      "source-gitlinks-valid")
    checkpoint accepted.output
    require accepted.ok

  test "the parser rejects every field the bounded form excludes":
    for (member, tag) in [
        ("action: \"fetch-yoga\"", "action"),
        ("command \"git submodule update\"", "command"),
        ("script: \"init.sh\"", "script"),
        ("pool: \"yoga.serial\"", "pool"),
        ("env: \"GIT_DIR=x\"", "env"),
        ("output: \"build/yoga\"", "output"),
        ("branch: \"main\"", "branch"),
        ("revision: \"3acb6cca\"", "revision")]:
      let rejected = checkRecipeSource(recipeWith(
        "    sourceGitlinks:\n      \"src/vendor/yoga\"\n      " & member &
        "\n"), "source-gitlinks-field-" & tag)
      checkpoint member & ": " & rejected.output
      check not rejected.ok
      check rejected.mentions("only literal gitlink path strings are accepted")

  test "the parser rejects non-literal, malformed, duplicate and colliding paths":
    let cases = [
      ("    sourceGitlinks:\n      YogaPath\n", "nonliteral",
        "only literal gitlink path strings are accepted"),
      ("    sourceGitlinks:\n      \"/src/vendor/yoga\"\n", "absolute",
        "is absolute"),
      ("    sourceGitlinks:\n      \"src/../vendor\"\n", "traversal",
        "traverses with '..'"),
      ("    sourceGitlinks:\n      \"src\\\\vendor\"\n", "backslash",
        "contains a backslash"),
      ("    sourceGitlinks:\n      discard\n", "empty",
        "only literal gitlink path strings are accepted"),
      ("    sourceGitlinks:\n      \"src/yoga\"\n      \"src/yoga\"\n",
        "duplicate", "is declared twice"),
      ("    sourceGitlinks:\n      \"src/Yoga\"\n      \"src/yoga\"\n",
        "case", "is declared twice")]
    for (body, tag, expected) in cases:
      let rejected = checkRecipeSource(
        "const YogaPath = \"src/vendor/yoga\"\n" & recipeWith(body),
        "source-gitlinks-" & tag)
      checkpoint tag & ": " & rejected.output
      check not rejected.ok
      check rejected.mentions(expected)
