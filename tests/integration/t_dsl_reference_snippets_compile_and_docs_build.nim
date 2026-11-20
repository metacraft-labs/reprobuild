## The project-file and profile syntax reference page states only syntax the
## real DSL accepts, and the documentation site builds with it.
##
## WHAT IS UNDER TEST. ``docs/users/content/reference/dsl.md`` is the public
## reference for ``repro.nim``, ``home.nim`` and ``system.nim``. Its examples
## are the part of it a reader copies, so each one is held to the compiler:
##
##   * every fenced block whose info string is ``nim`` is a COMPLETE file. It
##     is written to a scratch directory under the file name its ``title="..."``
##     attribute gives (``repro.nim``, ``reprobuild.nim``, ``home.nim``,
##     ``system.nim``; the name matters -- a file named ``reprobuild.nim``
##     cannot ``import reprobuild``) and ``nim check``ed with
##     ``--warningAsError[UnusedImport]:on``, the way an editor opens it: the
##     only Reprobuild-specific input is a ``nim.cfg`` holding the ``--path``
##     entries of ``consumerCompilePathFlags``, the engine's own consumer
##     compile flag set, and for a helper module (``build_helpers.nim``) the
##     ``<helper>.nims`` the page documents; a file named like a DSL file
##     gets the full DSL by its name. Project files are checked a second time with
##     ``-d:reproProviderMode``, the mode the engine compiles them in.
##   * a block fenced ``nim fragment`` is an excerpt and is not compiled (the
##     page has none today, and says so to its readers). The test prints both
##     counts and fails when no block was compiled, so an extraction that
##     silently matched nothing cannot pass.
##   * every other fence must be one this test knows: ``text`` (a grammar
##     shape). A fence in any other form -- another language, ``nim`` with an
##     attribute this test does not read (``nim runnable``, a misspelt
##     ``titel=``), a ``~~~`` fence -- fails the test instead of being
##     skipped, so a reader-facing example cannot escape the compiler by its
##     spelling.
##   * the page's table of profile resource constructors is compared, row by
##     row, with the constructors ``repro_profile/resources.nim`` exports and
##     the resource kind each one declares.
##
## Then the site itself: ``scripts/build_user_docs.sh build`` must emit the
## page at both of its routes (``reference/dsl/index.html`` and
## ``reference/dsl.md``), ``scripts/render_user_docs_generated.py --check``
## must find every generated artifact current, and ``llms.txt`` must index
## the page.
##
## THE NEGATIVE CONTROL. A misspelt section head -- ``nativeBuildDep:`` for
## ``nativeBuildDeps:`` -- written into a copy of a page example must make
## the same ``nim check`` fail and name the misspelling. Without it, "every
## example compiles" could be the result of a DSL that ignores what it does
## not understand.
##
## NO MOCKS. The real ``nim`` on ``PATH``, the real library tree, the real
## site build and the real generator. The site build needs the documentation
## framework's sibling checkouts (see ``docs/users/README.md``): they are
## looked for where ``scripts/build_user_docs.sh`` looks, in
## ``$REPRO_DOCS_SIBLING_ROOT`` or the parent of this checkout, and
## ``bash scripts/build_user_docs.sh fetch`` puts them there. When they are
## missing or stale the build fails and this test fails with it, naming that
## remedy; it does not skip.

import std/[os, osproc, sequtils, sets, strutils, tables, tempfiles,
  unittest]

# Running `nim`, `bash` and `python3` from PATH is the point of this test (it
# is a reader's and the site build's view of the page), so the
# ambient-execution wrappers say so.
from repro_core/ambient_execution import uncontrolledExecCmdEx,
  uncontrolledFindExe
from repro_project_dsl/mode import ReproDslMainFileNames
import repro_interface_artifacts
import repro_test_support

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  LibsRoot = RepoRoot / "libs"
  PageRel = "docs/users/content/reference/dsl.md"
  PagePath = RepoRoot / PageRel
  ResourcesModule = LibsRoot / "repro_profile" / "src" / "repro_profile" /
    "resources.nim"
  PublicDir = RepoRoot / "docs" / "users" / "public"
  BuiltHtml = PublicDir / "reference" / "dsl" / "index.html"
  BuiltMarkdown = PublicDir / "reference" / "dsl.md"
  ProjectFileNames = ["repro.nim", "reprobuild.nim"]
  HelperNims = "switch(\"define\", \"reproEvalMode\")\n"
    ## The ``<helper>.nims`` the page documents for a helper module that uses
    ## the full DSL.
  SiblingRemedy = "the documentation site needs its framework checkouts: " &
    "run `bash scripts/build_user_docs.sh fetch` (optionally with " &
    "REPRO_DOCS_SIBLING_ROOT pointing at an empty directory) and run this " &
    "test with the same REPRO_DOCS_SIBLING_ROOT"

# ---------------------------------------------------------------------------
# The page's examples.
# ---------------------------------------------------------------------------

type Snippet = object
  ## One fenced ``nim`` block of the page.
  line: int          ## 1-based line of the opening fence.
  fileName: string   ## From ``title="..."``; what the block is a file of.
  code: string
  fragment: bool     ## ``nim fragment``: an excerpt, not compiled.

proc fenceFormProblem(info: string): string =
  ## "" when ``info`` (an opening fence's info string) is one of the forms
  ## this test handles, otherwise why it is not: ``text``,
  ## ``nim title="<file>.nim"`` or ``nim fragment``.
  if info == "text" or info == "nim fragment":
    return ""
  const titlePrefix = "nim title=\""
  if info.startsWith(titlePrefix) and info.endsWith(".nim\"") and
      info.len > titlePrefix.len + ".nim\"".len and
      '"' notin info[titlePrefix.len ..< info.len - 1] and
      ' ' notin info[titlePrefix.len ..< info.len - 1]:
    return ""
  "fence info string `" & info & "` is none of `text`, " &
    "`nim title=\"<file>.nim\"` and `nim fragment`"

proc unrecognizedFences(text: string): seq[string] =
  ## Every opening fence whose form ``fenceFormProblem`` refuses, and every
  ## ``~~~`` fence (which ``parseSnippets`` does not read), as
  ## ``<line>: <problem>``.
  let lines = text.splitLines
  var i = 0
  while i < lines.len:
    let stripped = lines[i].strip(trailing = false)
    if stripped.startsWith("~~~"):
      result.add($(i + 1) & ": a `~~~` fence; write the block with backticks")
      inc i
    elif stripped.startsWith("```"):
      var width = 0
      while width < stripped.len and stripped[width] == '`': inc width
      let problem = fenceFormProblem(stripped[width .. ^1].strip())
      if problem.len > 0:
        result.add($(i + 1) & ": " & problem)
      var j = i + 1
      while j < lines.len and not (lines[j].strip().startsWith(
          repeat('`', width)) and lines[j].strip().allIt(it == '`')):
        inc j
      i = j + 1
    else:
      inc i

proc parseSnippets(text: string): seq[Snippet] =
  ## Every fenced block whose language (the first word of the info string)
  ## is ``nim``. A fence opens with three or more backticks and closes with
  ## a line of at least as many, as CommonMark and the site's renderer read
  ## it.
  let lines = text.splitLines
  var i = 0
  while i < lines.len:
    let stripped = lines[i].strip(trailing = false)
    if stripped.startsWith("```"):
      var width = 0
      while width < stripped.len and stripped[width] == '`': inc width
      let info = stripped[width .. ^1].strip()
      let words = info.splitWhitespace()
      var j = i + 1
      while j < lines.len and not (lines[j].strip().startsWith(
          repeat('`', width)) and lines[j].strip().allIt(it == '`')):
        inc j
      if words.len > 0 and words[0] == "nim":
        var snippet = Snippet(line: i + 1, fileName: "snippet.nim",
          code: lines[i + 1 ..< min(j, lines.len)].join("\n") & "\n",
          fragment: "fragment" in words)
        let titleAt = info.find("title=\"")
        if titleAt >= 0:
          let start = titleAt + "title=\"".len
          let stop = info.find('"', start)
          if stop > start:
            snippet.fileName = info[start ..< stop]
        result.add(snippet)
      i = j + 1
    else:
      inc i

# ---------------------------------------------------------------------------
# The compiler.
# ---------------------------------------------------------------------------

proc nimExe(): string =
  result = uncontrolledFindExe("nim")
  if result.len == 0:
    raise newException(IOError, "no `nim` on PATH; run inside the dev shell")

proc discoveryFlags(workDir: string): seq[string] =
  ## The engine's consumer-compile flag set, with ``$REPROBUILD_LIBS_DIR``
  ## naming THIS checkout's libraries so a dev shell's pinned snapshot does
  ## not stand in for the tree under test.
  let saved = getEnv("REPROBUILD_LIBS_DIR")
  putEnv("REPROBUILD_LIBS_DIR", LibsRoot)
  try:
    result = consumerCompilePathFlags(workDir)
  finally:
    if saved.len > 0: putEnv("REPROBUILD_LIBS_DIR", saved)
    else: delEnv("REPROBUILD_LIBS_DIR")

proc nimCfgFor(flags: seq[string]): string =
  ## The ``--path`` entries: what an editor needs to resolve the DSL. No mode
  ## define: an example named like a DSL file gets the full DSL by its name
  ## (``repro_project_dsl/mode``), and a helper module by the ``<helper>.nims``
  ## the page tells its reader to write (``writeSnippet``).
  for flag in flags:
    if flag.startsWith("--path:"):
      result.add("--path:\"" & flag["--path:".len .. ^1] & "\"\n")

proc nimCheck(dir, file: string; extra: openArray[string] = []):
    tuple[output: string, exitCode: int] =
  ## ``nim check`` run FROM ``dir``: the search path comes from its
  ## ``nim.cfg`` alone.
  var parts = @[nimExe().quoteShell, "check", "--hints:off", "--colors:off",
    "--warningAsError[UnusedImport]:on",
    ("--nimcache:" & dir / "nimcache").quoteShell]
  for e in extra: parts.add(e.quoteShell)
  parts.add(file.quoteShell)
  uncontrolledExecCmdEx(parts.join(" "), options = {poStdErrToStdOut},
    workingDir = dir)

proc writeSnippet(root: string; index: int; snippet: Snippet;
                  nimCfg: string; code = ""): string =
  ## A directory of its own per example, so each one's file name is free.
  result = root / ("example-" & $index)
  createDir(result)
  writeFile(result / "nim.cfg", nimCfg)
  writeFile(result / snippet.fileName,
    if code.len > 0: code else: snippet.code)
  if snippet.fileName notin ReproDslMainFileNames:
    writeFile(result / snippet.fileName.changeFileExt("nims"), HelperNims)

# ---------------------------------------------------------------------------
# The resource-constructor table.
# ---------------------------------------------------------------------------

proc exportedResourceConstructors(): Table[string, string] =
  ## constructor -> resource kind, for every exported routine of
  ## ``repro_profile/resources.nim`` that pushes exactly one resource kind.
  ## Helpers that push none (``scheduleDaily``, ``aclEntry``, ...) build
  ## arguments for a constructor and are not resource constructors.
  var name = ""
  var kinds = initHashSet[string]()
  proc flush(name: string; kinds: HashSet[string];
             into: var Table[string, string]) =
    if name.len > 0 and kinds.len == 1:
      into[name] = toSeq(kinds.items)[0]
  for line in readFile(ResourcesModule).splitLines:
    let words = line.splitWhitespace()
    if words.len >= 2 and words[0] in ["template", "proc", "macro"] and
        line.len > 0 and line[0] != ' ':
      flush(name, kinds, result)
      name = ""
      kinds.clear()
      let head = words[1]
      let star = head.find('*')
      if star > 0 and head[0 ..< star].allIt(it in IdentChars):
        name = head[0 ..< star]
      continue
    # ``pushResource(<target>, "<kind>", ...)``: the kind is the first
    # string literal of the call.
    let call = line.find("pushResource(")
    if name.len > 0 and call >= 0:
      let open = line.find('"', call)
      let close = if open >= 0: line.find('"', open + 1) else: -1
      if close > open:
        kinds.incl(line[open + 1 ..< close])
  flush(name, kinds, result)

proc pageResourceTable(text: string): Table[string, string] =
  ## The rows between the page's ``resource-constructors`` markers:
  ## ``| `<constructor>` | `<kind>` |``.
  let begin = text.find("<!-- resource-constructors:begin -->")
  let finish = text.find("<!-- resource-constructors:end -->")
  if begin < 0 or finish < begin:
    return
  for line in text[begin ..< finish].splitLines:
    let cells = line.split('|').mapIt(it.strip())
    if cells.len == 4 and cells[1].len > 2 and cells[1][0] == '`' and
        cells[2].len > 2 and cells[2][0] == '`':
      result[cells[1].strip(chars = {'`'})] = cells[2].strip(chars = {'`'})

# ---------------------------------------------------------------------------

let pageText = readFile(PagePath)
let snippets = parseSnippets(pageText)
let compiled = snippets.filterIt(not it.fragment)
let scratch = createTempDir("reprobuild-dsl-reference-", "")
let pathCfg = nimCfgFor(discoveryFlags(scratch))

echo "dsl reference: ", compiled.len, " complete examples compiled, ",
  snippets.len - compiled.len, " fragments skipped (", PageRel, ")"

suite "the reference page's examples are what the DSL accepts":
  test "the page has complete examples, and only named fragments are skipped":
    check compiled.len > 0
    # A fence in a form this test does not read would otherwise be skipped
    # without a word.
    let unrecognized = unrecognizedFences(pageText)
    for problem in unrecognized:
      checkpoint PageRel & ":" & problem
    check unrecognized.len == 0
    # Every example is a file a reader can save: it names that file.
    for snippet in compiled:
      checkpoint PageRel & ":" & $snippet.line & " names " & snippet.fileName
      check snippet.fileName.endsWith(".nim")
      check snippet.fileName != "snippet.nim"

  for index, snippet in compiled:
    let label = PageRel & ":" & $snippet.line & " (" & snippet.fileName & ")"
    test "nim check " & label:
      let dir = writeSnippet(scratch / "editor", index, snippet, pathCfg)
      let (output, exitCode) = nimCheck(dir, snippet.fileName)
      checkpoint output
      check exitCode == 0
      check not output.contains(" Error: ")
      check not output.contains("[UnusedImport]")

    if snippet.fileName in ProjectFileNames:
      test "nim check -d:reproProviderMode " & label:
        let dir = writeSnippet(scratch / "provider", index, snippet, pathCfg)
        let (output, exitCode) = nimCheck(dir, snippet.fileName,
          ["-d:reproProviderMode"])
        checkpoint output
        check exitCode == 0
        check not output.contains(" Error: ")

  test "negative control: a misspelt section head in a page example fails":
    let host = compiled.filterIt("  nativeBuildDeps:\n" in it.code)
    check host.len > 0
    if host.len > 0:
      let mutated = host[0].code.replace("  nativeBuildDeps:\n",
        "  nativeBuildDep:\n")
      let dir = writeSnippet(scratch / "mutated", 0, host[0], pathCfg,
        mutated)
      let (output, exitCode) = nimCheck(dir, host[0].fileName)
      checkpoint output
      check exitCode != 0
      check output.contains("nativeBuildDep'")

  test "the resource-constructor table matches repro_profile's constructors":
    let onPage = pageResourceTable(pageText)
    let exported = exportedResourceConstructors()
    check exported.len > 0
    for name, kind in exported:
      checkpoint "exported " & name & " (" & kind & ")"
      check onPage.getOrDefault(name) == kind
    for name in onPage.keys:
      checkpoint "listed on the page " & name
      check name in exported

suite "the documentation site builds with the page":
  test "build_user_docs.sh build emits the page at both routes":
    # Remove an earlier build's copies, so a build that stopped before the
    # page cannot pass on stale files.
    for stale in [BuiltHtml, BuiltMarkdown]:
      if fileExists(stale): removeFile(stale)
    let (output, exitCode) = uncontrolledExecCmdEx(
      "bash " & quoteShell(RepoRoot / "scripts" / "build_user_docs.sh") &
        " build", options = {poStdErrToStdOut}, workingDir = RepoRoot)
    checkpoint output.splitLines.filterIt("ssg_page_written" notin it)
      .join("\n")
    checkpoint SiblingRemedy
    check exitCode == 0
    check fileExists(BuiltHtml)
    check fileExists(BuiltMarkdown)
    if fileExists(BuiltMarkdown):
      check "# Project file and profile syntax" in readFile(BuiltMarkdown)
    let publishedIndex = PublicDir / "llms.txt"
    let indexedOnSite = fileExists(publishedIndex) and
      "/reference/dsl.md" in readFile(publishedIndex)
    check indexedOnSite

  test "render_user_docs_generated.py --check finds everything current":
    let (output, exitCode) = uncontrolledExecCmdEx(
      "python3 " & quoteShell(RepoRoot / "scripts" /
        "render_user_docs_generated.py") & " --check",
      options = {poStdErrToStdOut}, workingDir = RepoRoot)
    checkpoint output
    check exitCode == 0
    let indexedInRepository = "docs.reprobuild.com/reference/dsl.md" in
      readFile(RepoRoot / "llms.txt")
    check indexedInRepository

removeDir(scratch)
