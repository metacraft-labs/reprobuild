## `lockFile <name>[, path = "…"]` — the top-level declaration.
##
## Named-Lock-Files NLF-M7, design §4.2.
##
## ```nim
## # workspace.nim / project root — top level, not inside build:
##
## ## Tools that run on the build machine: code generators, compilers,
## ## anything whose output is consumed during the build rather than shipped.
## lockFile hostTools
##
## ## Everything we ship. Pinned to the aarch64 target graph.
## lockFile targetRuntime, path = "locks/aarch64.lock"
## ```
##
## §4.2 settles three things this module implements literally.
##
## **A bare identifier, not a string.** "A lock file is declared with a bare
## identifier, matching how the DSL already declares Nim-bound symbols
## (`package nim:`, `executable mesonBin:`) as opposed to how it *references*
## exported names (`target "name"`, `subcmd "c"`)." §4.9 gives the operational
## reason: "Being a bare **symbol** rather than a string is what makes this
## diagnostic possible … strings are for names that cross a boundary and
## cannot be checked; symbols are for names the compiler can verify."
##
## So the expansion binds a real Nim symbol whose VALUE is the name. A typo at
## a use site is an undeclared-identifier error from Nim itself, before the
## richer §4.9 diagnostic is even reached.
##
## **Top level, not a build block.** §4.2 gives three reasons and the third is
## the one with teeth: "A declaration whose visibility depended on which build
## bodies had executed would make the set of bindable names depend on
## evaluation order — the same class of order-dependence §1.3 is already trying
## to remove."
##
## **The doc comment is captured through the CANONICAL parser.** §4.2:
## "`parseDocComment` … is the one implementation of directive extraction, and
## it runs **at macro-expansion time** so a malformed `@id` or an unknown
## directive is a *compile* error rather than a runtime surprise. A `lockFile`
## declaration MUST call it." It does, below, and NLF-DOC-5 is the regression
## for a hand-rolled substitute.
##
## ## Why the comment is found by reading the source
##
## A top-level `lockFile hostTools` is a command-call statement; the macro
## receives its arguments and nothing else. Nim gives a macro no way to see the
## `nnkCommentStmt` nodes that precede its own call site — the `config:` block
## walker in `eval_config.nim` can only do it because it owns the enclosing
## block.
##
## So attachment is done by reading the recipe source at macro-expansion time,
## upward from the declaration's own line, which `name.lineInfoObj` reports
## exactly. The scan implements Comment-Attachment's ATTACHMENT rules
## (`attachLeadDoc`, in `repro_lock_files`); `parseDocComment` still does the
## DIRECTIVE extraction. Splitting it that way is what keeps §4.2's "use the
## canonical parser" true — the part that could drift is the part that is
## shared.
##
## The block form (`lockFile hostTools:` with an indented `path` and doc
## comment) is accepted too, as §4.2 asks, and it needs no source reading
## because a macro CAN see comments in a body it was handed.

import std/[macros, strutils]

import repro_lock_files
import repro_lock_files/ct_registry

import ./configurables/types
import ./configurables/doc_directives

export ct_registry

proc parsedDescription(raw: string; name: string; site: NimNode): string =
  ## Run the canonical `parseDocComment` and convert its structured errors
  ## into compile errors positioned at the declaration.
  ##
  ## Every `except` arm below is a case NLF-DOC-5 asserts: "`## @id BadID` and
  ## `## @nonsense` both fail at recipe compile time. Catches a hand-rolled
  ## scanner instead of the canonical `parseDocComment`."
  if raw.len == 0:
    return ""
  try:
    return parseDocComment(raw).description
  except EInvalidId as err:
    error("invalid @id in doc comment for lock file `" & name & "`: " &
      err.msg, site)
  except EUnknownDirective as err:
    error("doc comment for lock file `" & name & "`: " & err.msg, site)
  except EFutureDirective as err:
    error("doc comment for lock file `" & name & "`: " & err.msg, site)
  except DocDirectiveError as err:
    error("doc comment for lock file `" & name & "`: " & err.msg, site)
  ""

proc leadDocAt(site: NimNode): AttachedDoc =
  ## The doc-comment run immediately above `site`, read from the recipe
  ## source. Returns an empty result when the source cannot be read, which is
  ## the honest degradation: a description is documentation, and failing a
  ## recipe compile because a source file moved would be a worse trade than
  ## losing one.
  let info = site.lineInfoObj
  if info.filename.len == 0 or info.line <= 0:
    return AttachedDoc()
  var text = ""
  try:
    text = staticRead(info.filename)
  except CatchableError:
    return AttachedDoc()
  attachLeadDoc(text.splitLines(), info.line - 1)

proc emitDeclaration(nameNode: NimNode; path, description: string;
                     docLine, docColumn: int; ownerPackage: string): NimNode =
  let name = $nameNode
  let info = nameNode.lineInfoObj
  # The position is the FIRST `##` line and ITS column when a comment run
  # attaches, and the declaration's own position otherwise. Comment-Attachment
  # rule 6, and §4.2 flags it as "the rule most easily got wrong — the existing
  # variant path emits `descriptionColumn = 0` and the declaration's line
  # rather than the comment run's, while `eval_config.nim` does it correctly.
  # Follow `eval_config.nim`."
  let line = if docLine > 0: docLine else: info.line
  let column = if docLine > 0: docColumn else: info.column
  result = newStmtList()
  result.add(newCall(bindSym"recordLockFileDeclaration",
    newLit(name), newLit(path), newLit(description),
    newLit(info.filename), newLit(line), newLit(column),
    newLit(ownerPackage)))
  # The run-time half: a `let` binding whose value is the name, and whose
  # side effect is registering the declaration in the process that will
  # later print `repro lock list` and resolve `--lock`.
  let letStmt = newNimNode(nnkLetSection).add(
    newNimNode(nnkIdentDefs).add(
      postfix(ident(name), "*"),
      newEmptyNode(),
      newCall(bindSym"declareLockFile",
        newLit(name), newLit(path), newLit(description),
        newLit(info.filename), newLit(line), newLit(column),
        newLit(ownerPackage))))
  result.add(letStmt)

proc pathFromArgs(args: seq[NimNode]; site: NimNode): string =
  result = ""
  for a in args:
    if a.kind == nnkExprEqExpr and a[0].kind == nnkIdent and
        a[0].eqIdent("path"):
      if a[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        error("lockFile: `path =` expects a string literal", a[1])
      result = a[1].strVal
    else:
      error("lockFile: unexpected argument; the forms are " &
        "`lockFile <name>` and `lockFile <name>, path = \"…\"`", a)

macro lockFile*(name: untyped; args: varargs[untyped]): untyped =
  ## The three accepted spellings, in one macro rather than an overload set:
  ##
  ##   * `lockFile <name>` — a complete declaration of an unbound lock file
  ##     (§5.3). "the standalone line is the common spelling."
  ##   * `lockFile <name>, path = "…"` — the committed binding, "which is the
  ##     normal case — bindings are committed, not typed at a prompt" (§4.2).
  ##   * `lockFile <name>:` with `path` and the doc comment indented — the
  ##     block body form §4.2 also asks for.
  ##
  ## One macro because two overloads differing only in a trailing
  ## `varargs[untyped]` are ambiguous for the zero-argument call, which is the
  ## commonest spelling of the three.
  if name.kind != nnkIdent:
    error("lockFile expects a bare identifier, not a string or expression " &
      "— §4.2: declaration binds a symbol, and §4.9's diagnostic depends " &
      "on it being one", name)
  var argList: seq[NimNode] = @[]
  for a in args: argList.add(a)
  # The block form: `lockFile hostTools:` with `path = "…"` and doc comments
  # indented under it. §4.2 asks for it explicitly, and it is the one form
  # whose comments a macro can see directly.
  if argList.len == 1 and argList[0].kind == nnkStmtList:
    var path = ""
    var docText = ""
    var docLine = 0
    var docColumn = 0
    for stmt in argList[0]:
      case stmt.kind
      of nnkCommentStmt:
        if docText.len == 0:
          let info = stmt.lineInfoObj
          docLine = info.line
          docColumn = info.column
        else:
          docText.add("\n")
        docText.add(stmt.strVal)
      of nnkAsgn, nnkExprEqExpr:
        if not stmt[0].eqIdent("path"):
          error("lockFile: only `path = \"…\"` is accepted in the block " &
            "body", stmt)
        if stmt[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          error("lockFile: `path =` expects a string literal", stmt[1])
        path = stmt[1].strVal
      of nnkEmpty:
        discard
      else:
        error("lockFile: only `path = \"…\"` and doc comments are accepted " &
          "in the block body", stmt)
    return emitDeclaration(name, path,
      parsedDescription(docText, $name, name), docLine, docColumn, "")
  let path = pathFromArgs(argList, name)
  let doc = leadDocAt(name)
  emitDeclaration(name, path, parsedDescription(doc.text, $name, name),
    doc.line, doc.column, "")
