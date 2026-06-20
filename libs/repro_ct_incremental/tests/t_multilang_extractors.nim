## M3 tests: prove the deep-hash invalidation engine is language-agnostic.
##
## These are the automated tests specified for M3 in
## `docs/Trace-Based-Incremental-Testing.milestones.org`. The SAME engine
## (`record`/`decide`) drives Ruby (from M1), Python, and JavaScript — the only
## per-language code is the `FunctionBodyExtractor` selected by file extension
## (`extractors.nim`). Each language test copies its fixture source into a fresh
## temp dir, `record()`s against the committed fixture trace, then edits the
## temp source and `decide()`s — exercising the real extension-selected
## extractor + hashing + decision path, never asserting constants.
##
## A language is described by a `LangFixture` row (fixture dir + the
## trace-recorded relative source path + the per-language edit/delete helpers),
## so the executed/unexecuted change tests are written ONCE and run per
## language — mirroring "identical engine, three languages".

import std/[unittest, os, strutils, times]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"

type
  LangFixture = object
    name: string          ## Human label for the subtest.
    fixtureDir: string    ## `<fixturesDir>/<dir>`.
    relSource: string     ## Source path as the trace records it (leading slash
                          ## stripped) — where the temp copy must live.
    srcFile: string       ## Basename of the source file inside `src/`.
    # Per-language single-line body edit + whole-function delete. Both operate
    # on a function whose body is the line(s) immediately after the def line.
    editBody: proc(path, funcName, newBody: string)
    deleteFn: proc(path, funcName: string)

# ---------------------------------------------------------------------------
# Per-language source manipulation helpers
# ---------------------------------------------------------------------------

proc editAfterDefLine(path, defMatchPrefix, funcName, newBodyLine: string) =
  ## Replace the single line immediately after the line that starts with
  ## `<defMatchPrefix><funcName>` (e.g. `def used_a` / `function used_a`).
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith(defMatchPrefix & funcName):
      doAssert i + 1 < lines.len, "no body line after def of " & funcName
      lines[i + 1] = newBodyLine
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

# Ruby: `def <name>\n  <body>\nend`
proc rubyEdit(path, funcName, newBody: string) =
  editAfterDefLine(path, "def ", funcName, "  " & newBody)

proc rubyDelete(path, funcName: string) =
  var lines = readFile(path).split('\n')
  var outLines: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip() == "def " & funcName:
      i += 1
      while i < lines.len and lines[i].strip() != "end": i += 1
      if i < lines.len: i += 1
      continue
    outLines.add lines[i]
    i += 1
  writeFile(path, outLines.join("\n"))

# Python: `def <name>():\n    <body>` (suite ends at the next def / dedent)
proc pyEdit(path, funcName, newBody: string) =
  editAfterDefLine(path, "def ", funcName, "    " & newBody)

proc pyDelete(path, funcName: string) =
  ## Drop the `def <name>():` line and its indented suite.
  var lines = readFile(path).split('\n')
  var outLines: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip().startsWith("def " & funcName):
      i += 1
      # Skip indented body + interior blanks until a non-blank dedent line.
      while i < lines.len and (lines[i].strip().len == 0 or
            (lines[i].len > 0 and (lines[i][0] == ' ' or lines[i][0] == '\t'))):
        i += 1
      continue
    outLines.add lines[i]
    i += 1
  writeFile(path, outLines.join("\n"))

# JavaScript: `function <name>() {\n  <body>\n  ...\n}`
proc jsEdit(path, funcName, newBody: string) =
  editAfterDefLine(path, "function ", funcName, "  " & newBody)

proc jsDelete(path, funcName: string) =
  ## Drop `function <name>() { … }` by brace matching from its opening `{`.
  var lines = readFile(path).split('\n')
  var outLines: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip().startsWith("function " & funcName):
      var depth = 0
      var sawOpen = false
      while i < lines.len:
        for ch in lines[i]:
          if ch == '{':
            inc depth; sawOpen = true
          elif ch == '}':
            if depth > 0: dec depth
        i += 1
        if sawOpen and depth == 0: break
      continue
    outLines.add lines[i]
    i += 1
  writeFile(path, outLines.join("\n"))

# ---------------------------------------------------------------------------
# Fixture table
# ---------------------------------------------------------------------------

let languages = @[
  LangFixture(
    name: "python",
    fixtureDir: fixturesDir / "m3_python_funcs",
    relSource: "fixtures/m3_python_funcs/src/three_funcs.py",
    srcFile: "three_funcs.py",
    editBody: pyEdit, deleteFn: pyDelete),
  LangFixture(
    name: "javascript",
    fixtureDir: fixturesDir / "m3_js_funcs",
    relSource: "fixtures/m3_js_funcs/src/three_funcs.js",
    srcFile: "three_funcs.js",
    editBody: jsEdit, deleteFn: jsDelete),
]

var tempCounter = 0

proc makeSourceRoot(lf: LangFixture): string =
  ## Fresh temp dir with the fixture source copied to the trace-expected path.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m3_" & lf.name & "_" & $stamp & "_" &
    $tempCounter)
  let dst = root / lf.relSource
  createDir(dst.parentDir)
  copyFile(lf.fixtureDir / "src" / lf.srcFile, dst)
  root

const testId = "fixture::three_funcs"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M3: multi-language extractors (language-agnostic engine)":

  for lf in languages:
    let traceDir = lf.fixtureDir / "trace"

    test lf.name & "_executed_function_change_reruns":
      ## Edit an EXECUTED function (used_a) ⇒ idRerunChanged listing it.
      let root = makeSourceRoot(lf)
      var cache = initCache(root / "cache.json")
      check record(cache, testId, traceDir, root).isOk
      lf.editBody(root / lf.relSource, "used_a",
        (if lf.name == "javascript": "return 42 + 99;" else:
          (if lf.name == "python": "return 42 + 99" else: "42 + 99")))
      let d = decide(testId, traceDir, root, cache)
      check d.kind == idRerunChanged
      check "used_a" in d.changedFuncs
      # Function-level precision: only used_a, not its siblings.
      check d.changedFuncs == @["used_a"]

    test lf.name & "_unexecuted_function_change_skips":
      ## Edit a DEFINED-BUT-UNEXECUTED function (unused_c) ⇒ idSkipUnchanged.
      ## Proves function-level (not file-level) precision per language: the edit
      ## is in the same file as the executed functions.
      let root = makeSourceRoot(lf)
      var cache = initCache(root / "cache.json")
      check record(cache, testId, traceDir, root).isOk
      lf.editBody(root / lf.relSource, "unused_c",
        (if lf.name == "javascript": "return 777;" else:
          (if lf.name == "python": "return 777" else: "777 + 777")))
      let d = decide(testId, traceDir, root, cache)
      check d.kind == idSkipUnchanged

    test lf.name & "_removed_executed_function_reruns":
      ## Deleting an executed function ⇒ idRerunChanged (missing == changed),
      ## proving the per-language delete + extractor agree on the boundary.
      let root = makeSourceRoot(lf)
      var cache = initCache(root / "cache.json")
      check record(cache, testId, traceDir, root).isOk
      lf.deleteFn(root / lf.relSource, "used_b")
      let d = decide(testId, traceDir, root, cache)
      check d.kind == idRerunChanged
      check "used_b" in d.changedFuncs

  test "extractor_selected_by_extension":
    ## The correct extractor is chosen per `.rb`/`.py`/`.js`; an unknown
    ## extension yields a clear error — never a silent wrong result.
    # Each known extension resolves to an extractor.
    check extractorFor("a/b/x.rb").isOk
    check extractorFor("a/b/x.py").isOk
    check extractorFor("a/b/x.js").isOk
    check extractorFor("a/b/x.nim").isOk   # M9: Nim's materialized-source path
    # Case-insensitive on the extension.
    check extractorFor("X.PY").isOk
    # Unknown extension ⇒ clear Err (asserted), never silent.
    let unknown = extractorFor("a/b/x.go")
    check unknown.isErr
    check "unsupported source extension" in unknown.error
    # No extension at all ⇒ clear Err too.
    let noExt = extractorFor("a/b/Makefile")
    check noExt.isErr

    # The selected extractors apply genuinely DIFFERENT strategies. Drive each
    # over a small snippet and assert the captured body matches the language's
    # rule (indentation for .py, braces for .js).
    let pySrc = @[
      "def f():",          # 1
      "    return 1",      # 2
      "    return 2",      # 3
      "",                  # 4
      "def g():",          # 5
      "    return 3"]      # 6
    let pyBody = extractFunctionBody("x.py", pySrc, 1)
    check pyBody.isOk
    # Indentation rule: f's body is lines 1..3, NOT g (dedented def at line 5).
    check pyBody.value == "def f():\n    return 1\n    return 2"

    # Nim (.nim) reuses the SAME indentation strategy (M9): a proc body is its
    # `proc` line through the last more-deeply-indented line; the next sibling
    # `proc` at the def's indentation ends it.
    let nimSrc = @[
      "proc f(): int =",   # 1
      "  result = 1",      # 2
      "  result += 2",     # 3
      "",                  # 4
      "proc g(): int =",   # 5
      "  result = 3"]      # 6
    let nimBody = extractFunctionBody("x.nim", nimSrc, 1)
    check nimBody.isOk
    check nimBody.value == "proc f(): int =\n  result = 1\n  result += 2"

    let jsSrc = @[
      "function f() {",                       # 1
      "  const o = { a: 1, b: { c: 2 } };",   # 2  (nested braces)
      "  return o.a; // closing brace } here", # 3 (brace in comment)
      "}",                                    # 4
      "function g() { return 3; }"]           # 5
    let jsBody = extractFunctionBody("x.js", jsSrc, 1)
    check jsBody.isOk
    # Brace rule: f's body is lines 1..4 (matching `}`), NOT g; nested/string/
    # comment braces did not confuse the matcher.
    check jsBody.value ==
      "function f() {\n  const o = { a: 1, b: { c: 2 } };\n" &
      "  return o.a; // closing brace } here\n}"

    # Regex literal containing a `}`: the matcher must NOT treat the regex `}`
    # as the function's closing brace. The captured body must include the tail
    # statement after the regex line, all the way to the real `}`.
    let jsRegexSrc = @[
      "function f() {",        # 1
      "  const re = /}/;",     # 2  (brace inside a regex literal)
      "  let x = 1;",          # 3  (real tail — must NOT be dropped)
      "  return x;",           # 4
      "}",                     # 5
      "function g() { 1; }"]   # 6
    let jsRegexBody = extractFunctionBody("x.js", jsRegexSrc, 1)
    check jsRegexBody.isOk
    check jsRegexBody.value ==
      "function f() {\n  const re = /}/;\n  let x = 1;\n  return x;\n}"

    # Template literal with `${ … }` interpolation (which itself contains an
    # object brace): interpolation braces are matched on an independent stack,
    # so the tail after the template is captured to the real closing `}`.
    let jsTmplSrc = @[
      "function f() {",                          # 1
      "  const s = `a ${ { k: 1 } } b`;",        # 2  (nested braces in ${})
      "  let x = 1;",                            # 3  (real tail)
      "  return x;",                             # 4
      "}",                                       # 5
      "function g() { 1; }"]                     # 6
    let jsTmplBody = extractFunctionBody("x.js", jsTmplSrc, 1)
    check jsTmplBody.isOk
    check jsTmplBody.value ==
      "function f() {\n  const s = `a ${ { k: 1 } } b`;\n" &
      "  let x = 1;\n  return x;\n}"

    # Division (`/`) must NOT be misread as a regex start: after a value-ending
    # token (a CALL/GROUPING `)`, `]`, identifier/number), `/` is division and
    # the body still balances normally.
    let jsDivSrc = @[
      "function f() {",          # 1
      "  let y = (a + b) / c;",  # 2  (`/` is division, not a regex)
      "  let x = 1;",            # 3
      "}"]                       # 4
    let jsDivBody = extractFunctionBody("x.js", jsDivSrc, 1)
    check jsDivBody.isOk
    check jsDivBody.value ==
      "function f() {\n  let y = (a + b) / c;\n  let x = 1;\n}"

    # Control-head `)` followed by a regex `/}/`: the `)` closes `if (cond)`,
    # which is a STATEMENT boundary, so `/}/` is a regex (NOT division). The
    # in-regex `}` must NOT be counted as the function close — the tail after it
    # must be captured to the real `}`. (Pre-fix: every `)` was a value ⇒ the
    # `/}/` was mis-lexed as division and the tail was dropped — the false-skip.)
    let jsCtrlSrc = @[
      "function f() {",                    # 1
      "  if (cond) /}/.test(input);",      # 2  (regex after control-head `)`)
      "  let x = 1;",                      # 3  (real tail — must NOT be dropped)
      "  return x;",                       # 4
      "}",                                 # 5
      "function g() { 1; }"]               # 6
    let jsCtrlBody = extractFunctionBody("x.js", jsCtrlSrc, 1)
    check jsCtrlBody.isOk
    check jsCtrlBody.value ==
      "function f() {\n  if (cond) /}/.test(input);\n" &
      "  let x = 1;\n  return x;\n}"

    # And `arr[i] / 2` after a `]` must stay division (the body balances and the
    # tail is captured exactly — `]` remains a value).
    let jsIdxDivSrc = @[
      "function f() {",          # 1
      "  let y = arr[i] / 2;",   # 2  (`/` is division after `]`)
      "  let x = 1;",            # 3
      "}"]                       # 4
    let jsIdxDivBody = extractFunctionBody("x.js", jsIdxDivSrc, 1)
    check jsIdxDivBody.isOk
    check jsIdxDivBody.value ==
      "function f() {\n  let y = arr[i] / 2;\n  let x = 1;\n}"

    # Fail-safe: an unbalanced (truncated) function yields an Err, NEVER a
    # partial body — the engine turns that into a conservative re-run.
    let jsTruncSrc = @[
      "function f() {",
      "  let x = 1;"]   # no closing brace
    check extractFunctionBody("x.js", jsTruncSrc, 1).isErr

    # Unknown extension at the body-extraction entrypoint is an Err, never a
    # silent wrong body.
    check extractFunctionBody("x.go", @["func f() {}"], 1).isErr
