## The COMPILE-TIME registry of declared lock-file names, and §4.9's error.
##
## Named-Lock-Files NLF-M7, design §4.9:
##
## > **Requirement.** A lock-file name referenced but never declared MUST fail
## > at **recipe compile time**. It MUST NOT be a runtime lookup miss, MUST NOT
## > silently resolve to `default`, and MUST NOT produce an empty or zero
## > value.
##
## ## Why the registry and the macros that touch it are in ONE module
##
## This is a Nim VM constraint and it decides the shape of the whole file, so
## it is stated rather than discovered by the next reader. A `{.compileTime.}`
## variable is reachable only from code that BELONGS to its own module: a
## `{.compileTime.}` proc in another module that mutates it silently loses the
## mutation, and an ordinary global read from a macro body in another module is
## a "cannot evaluate at compile time" error. Measured both ways before
## settling on this layout.
##
## So the registry, the recorder and the checker live together, and the two
## call sites that need them — the stdlib's `lockFile` declaration macro and
## the project DSL's `package` macro — reach them by EMITTING a call to the
## macros below. An emitted macro call is expanded in this module's context,
## which is exactly the thing a cross-module proc call does not get.
##
## ## What this module deliberately does not do
##
## It does not parse doc comments. §4.2 requires the canonical
## `parseDocComment` — which lives in the stdlib, above this leaf — and the
## split is what keeps that requirement satisfiable: the stdlib macro parses
## and hands the already-extracted description down. A registry that parsed
## directives itself would be the hand-rolled scanner NLF-DOC-5 exists to
## catch.

import std/[macros, strutils]

import ./declarations

var declaredCT {.compileTime.}: seq[LockFileDecl] = predeclaredLockFiles()
  ## The compile-time twin of `declarations.declared`. Seeded with the same
  ## well-known set (§4.8) from the same proc, so the compile error and the
  ## run-time listing cannot disagree about what is predeclared.

macro recordLockFileDeclaration*(name: static string; path: static string;
                                 description: static string;
                                 sourceFile: static string;
                                 sourceLine: static int;
                                 sourceColumn: static int;
                                 ownerPackage: static string): untyped =
  ## Record one declaration at compile time. Expands to nothing.
  ##
  ## A duplicate is an error here for the same reason it is at run time (§4.2
  ## reason 2), and raising it HERE is what makes it a compile error rather
  ## than a module-init crash on the first build.
  for d in declaredCT:
    if d.name == name and d.ownerPackage == ownerPackage and not d.predeclared:
      error("duplicate lock file declaration `" & name & "`\n" &
        "  already declared at " & originOf(d))
  var updated = false
  for i in 0 ..< declaredCT.len:
    if declaredCT[i].name == name and declaredCT[i].ownerPackage == ownerPackage:
      # §4.2: `default` is "a declarable symbol, predeclared by the stdlib but
      # writable explicitly at any designation site", which §4.10's whole-graph
      # retargeting spelling (`lockFile default, path = "locks/aarch64.lock"`)
      # relies on. Re-declaring a well-known name updates it.
      declaredCT[i].path = path
      if description.len > 0:
        declaredCT[i].description = description
        declaredCT[i].sourceFile = sourceFile
        declaredCT[i].sourceLine = sourceLine
        declaredCT[i].sourceColumn = sourceColumn
      updated = true
      break
  if not updated:
    declaredCT.add(LockFileDecl(
      name: name, path: path, description: description,
      sourceFile: sourceFile, sourceLine: sourceLine,
      sourceColumn: sourceColumn, ownerPackage: ownerPackage))
  newStmtList()

macro requireDeclaredLockFile*(name: static string;
                               ownerPackage: static string;
                               sourceFile: static string;
                               sourceLine: static int;
                               sourceColumn: static int): untyped =
  ## §4.9's compile error. Expands to nothing when the name is declared.
  ##
  ## The diagnostic is rendered by the shared renderer in `declarations.nim`
  ## over `declaredCT`, so the compile error and `repro lock list` print the
  ## same in-scope set from the same code.
  for d in declaredCT:
    if d.name != name: continue
    if d.ownerPackage.len == 0 or d.ownerPackage == ownerPackage:
      return newStmtList()
  error(undeclaredDiagnosticIn(declaredCT, name, sourceFile, sourceLine,
    sourceColumn, ownerPackage))

macro lockFileNamesInScope*(): untyped =
  ## The declared names, as a `seq[string]` literal, for a test that wants to
  ## observe the compile-time registry from run-time code.
  var names: seq[string] = @[]
  for d in declaredCT: names.add(d.name)
  result = nnkPrefix.newTree(ident("@"), nnkBracket.newTree())
  for n in names:
    result[1].add(newLit(n))

macro lockFileDescriptionInScope*(name: static string): untyped =
  ## The FULL captured description of `name`, as a string literal, read out of
  ## the compile-time registry.
  ##
  ## Distinct from `lockFileScopeListing` on purpose: that renderer prints the
  ## first line of each description, because a diagnostic's in-scope block has
  ## to stay readable. A test that needs to know whether a directive line was
  ## EXTRACTED has to see every line — the directive is never on the first one,
  ## and a first-line-only view reports extraction that did not happen.
  ## Measured: NLF-DOC-5's control passed against a hand-rolled scanner until
  ## this existed.
  for d in declaredCT:
    if d.name == name:
      return newLit(d.description)
  newLit("")

macro lockFileScopeListing*(): untyped =
  ## The compile-time registry's `in scope here:` listing, as a string
  ## literal. Lets a test assert that the compile error's listing and the
  ## run-time listing carry the same descriptions without re-typing either.
  newLit(inScopeListingLinesIn(declaredCT).join("\n"))
