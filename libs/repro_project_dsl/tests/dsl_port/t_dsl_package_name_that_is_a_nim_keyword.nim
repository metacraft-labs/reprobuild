## A package whose name is a Nim keyword can be declared under that name.
##
## reprobuild-pm/issues/2026-10-15-package-macro-cannot-declare-a-name-that-is-a-nim-keyword.md:
## the Nix language server is called ``nil``, and no spelling of that name
## declared a package. ``package "nil":`` (and `` package `nil`: ``) reached
## the macro and then failed inside ``packageImpl`` with ``identifier
## expected, but got 'keyword nil'``, because ``selectorModuleName`` passed
## the keyword through unchanged and the macro emitted it as the package's
## value identifier.
##
## Package-Model.md §"Package names" settles it: every identifier the macro
## emits is derived through ``selectorModuleName``, which prefixes ``pkg_`` to
## a result that is a Nim keyword, exactly as it does to one that would begin
## with a digit (``t_dsl_package_name_starting_with_digit.nim``). Nim matches
## keywords style-insensitively — ``n_il`` and ``is_not`` lex as ``nil`` and
## ``isnot`` — so the check compares with underscores removed.
##
## The declarations below cover the emission paths that turn the name into
## code: an empty package (the shape of the issue's ``nil`` interface), a
## package with a typed executable (the legacy ``<Title>Package`` const and
## wrapper path), a package with no executables whose ``build:`` exports a
## cross-project binding (the bridging ``build`` template and per-binding
## accessors in ``cross_project.nim``, reached through the value const the
## wrapper path always emits), the backtick-quoted spelling, and a
## name that is a keyword only once its underscores are ignored. This file
## failing to compile is the regression.
##
## No mocks: the real ``package`` macro and the real registry.

import std/[unittest]

import repro_project_dsl
import repro_project_dsl/selector_names
import repro_dsl_stdlib/types

type
  KeywordToolHandle = object
    path: string

# The issue's interface, verbatim: an empty package named by a keyword.
package "nil":
  discard

# A typed executable: emits the `<Title>Package` type, its value const and
# the typed-tool wrapper procs.
package "type":
  executable typeTool:
    cli:
      subcmd "compile":
        flag source is string
        flag binary is string
        outputs result is KeywordToolHandle, binary

# No executables, one exported `build:` binding: emits the cross-project
# storage, the `build` bridge over the value const and the binding accessor.
package "method":
  build:
    let singleEdge = pkg_type.compile(
      source = "tests/keyword/single.nim",
      binary = "build/keyword/single")

# The backtick-quoted spelling the issue also tried.
package `out`:
  discard

# Not a keyword as written, but `is_not` lexes as the keyword `isnot`.
package "is-not":
  discard

# `depends_on` names a package the way `package` does.
depends_on "method":
  "nil"
  "type"

proc registered(name: string): bool =
  for p in registeredPackages():
    if p.packageName == name:
      return true
  false

suite "package names that are Nim keywords":

  test "isNimKeyword matches the Nim lexer":
    for kw in ["nil", "type", "method", "out", "isnot", "notin", "func",
               "using", "addr", "end", "yield"]:
      check isNimKeyword(kw)
    # Style-insensitive past the first character, as the lexer is.
    check isNimKeyword("n_il")
    check isNimKeyword("is_not")
    check isNimKeyword("nIL")
    # The first character is case-sensitive, and these are not keywords.
    check not isNimKeyword("Nil")
    check not isNimKeyword("Type")
    for word in ["echo", "result", "string", "true", "nix", "types", ""]:
      check not isNimKeyword(word)

  test "isNimIdentifier rejects keywords and malformed identifiers":
    check isNimIdentifier("just")
    check isNimIdentifier("python3")
    check isNimIdentifier("dotnet_sdk")
    check not isNimIdentifier("nil")
    check not isNimIdentifier("ty_pe")
    check not isNimIdentifier("7zip")
    check not isNimIdentifier("dotnet-sdk")
    check not isNimIdentifier("a__b")
    check not isNimIdentifier("trailing_")
    check not isNimIdentifier("")

  test "selectorModuleName never yields a Nim keyword":
    check selectorModuleName("nil") == "pkg_nil"
    check selectorModuleName("type") == "pkg_type"
    check selectorModuleName("method") == "pkg_method"
    check selectorModuleName("is-not") == "pkg_is_not"
    check selectorModuleName("notIn") == "pkg_not_in"
    # `NIL` sanitizes to `n_i_l`, which the lexer still reads as `nil`.
    check selectorModuleName("NIL") == "pkg_n_i_l"
    # A keyword inside a longer name is not a keyword.
    check selectorModuleName("nil-ls") == "nil_ls"
    check selectorModuleName("typescript") == "typescript"
    check selectorModuleName("nix") == "nix"
    # `usesImportCode`'s module path for a selector uses the same mapping.
    check bundledStdlibModuleName("nil") == "pkg_nil"
    for kw in NimKeywords:
      check isNimIdentifier(selectorModuleName(kw))

  test "the canonical name is registered verbatim":
    check registered("nil")
    check registered("type")
    check registered("method")
    check registered("out")
    check registered("is-not")
    check not registered("pkg_nil")

  test "the derived value and type identifiers are declared":
    check declared(pkg_nil)
    check declared(PkgNilPackage)
    check declared(pkg_type)
    check declared(PkgTypePackage)
    check declared(typeTool)
    check declared(pkg_method)
    check declared(pkg_out)
    check declared(pkg_is_not)

  test "the cross-project binding resolves through the derived identifier":
    check compiles(pkg_method.build.singleEdge)
    check compiles(PackageBuild["method"]().singleEdge)
    check not compiles(pkg_method.build.noSuchBinding)

  test "depends_on records a quoted keyword name without its quotes":
    var deps: seq[string] = @[]
    for edge in registeredWorkspaceDeps():
      if edge.package == "method":
        deps.add edge.dependency
    check deps == @["nil", "type"]
