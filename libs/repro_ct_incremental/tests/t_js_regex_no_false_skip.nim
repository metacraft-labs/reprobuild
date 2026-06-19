## M3 regression: the JavaScript extractor must be INCAPABLE of a silent
## under-capture (a false SKIP of a genuinely-changed function).
##
## The reviewer's repro: a function body whose first statement is a regex
## literal containing a `}`:
##
##   function used_a() {
##     const re = /}/;     // the `}` is INSIDE a regex literal
##     let x = 1;          // real tail
##     return x;
##   }
##
## The previous brace-only scanner treated the `}` in the regex as the closing
## brace of the function, dropped the `let x = …` / `return x` tail, and so a
## genuine edit to the tail (`1` -> `999`) produced a BYTE-IDENTICAL captured
## body — the engine returned `idSkipUnchanged` for changed code. That is the
## exact false-skip this campaign must never allow.
##
## This test builds a self-contained minimal CodeTracer trace + source in a
## temp dir (so the def line of the regex function is whatever we choose),
## `record()`s, edits ONLY the tail statement, `decide()`s, and asserts
## `idRerunChanged`. It is a true black-box regression: it would FAIL (return
## `idSkipUnchanged`) against the pre-fix extractor and PASS after the fix.

import std/[unittest, os, strutils, times, json]
import repro_ct_incremental

var tempCounter = 0

proc freshRoot(label: string): string =
  ## A unique temp dir for one scenario.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  result = getTempDir() / ("repro_ct_jsregex_" & label & "_" & $stamp & "_" &
    $tempCounter)
  createDir(result)

proc writeMinimalTrace(traceDir, srcRel: string; usedADefLine: int) =
  ## Write a minimal real-schema CodeTracer trace whose only executed function
  ## is `used_a`, recorded at `usedADefLine` in `srcRel`. The schema matches the
  ## committed M3 fixtures (externally-tagged event array + trace_paths.json +
  ## trace_metadata.json).
  createDir(traceDir)
  let paths = %*["", srcRel]
  writeFile(traceDir / "trace_paths.json", paths.pretty())
  let events = %*[
    {"Path": ""},
    {"Path": srcRel},
    {"Function": {"path_id": 1, "line": usedADefLine, "name": "used_a"}},
    {"Call": {"function_id": 0, "args": []}},
    {"Step": {"path_id": 1, "line": usedADefLine + 1}},
    {"Return": {"return_value": {"kind": "None", "type_id": 0}}}
  ]
  writeFile(traceDir / "trace.json", events.pretty())
  let meta = %*{"program": srcRel, "args": [], "workdir": "/"}
  writeFile(traceDir / "trace_metadata.json", meta.pretty())

const testId = "fixture::js_regex_repro"

suite "M3 regression: JS regex/template extraction cannot silently under-capture":

  test "regex literal containing '}' does not drop the tail (no false skip)":
    let root = freshRoot("regex")
    let srcRel = "/src/regex_func.js"
    let srcPath = root / "src" / "regex_func.js"
    createDir(srcPath.parentDir)
    # `used_a` is on line 1; the regex `}` is on line 2; the editable tail is
    # on line 3.
    let original = """function used_a() {
  const re = /}/;
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    # Edit ONLY the tail statement: `let x = 1;` -> `let x = 999;`. If the
    # extractor stopped at the regex `}`, the captured body is identical and the
    # engine would (wrongly) skip.
    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original          # sanity: the edit actually changed bytes
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged    # MUST re-run; a skip here is the bug.
    check "used_a" in d.changedFuncs

  test "template literal with ${} and nested braces does not drop the tail":
    let root = freshRoot("template")
    let srcRel = "/src/tmpl_func.js"
    let srcPath = root / "src" / "tmpl_func.js"
    createDir(srcPath.parentDir)
    # The `${ { … } }` interpolation embeds a brace-balanced object expression;
    # a brace-only scanner would mis-pair the inner `}` and truncate the body.
    let original = """function used_a() {
  const s = `pre ${ { k: 1 } } post`;
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  # ---------------------------------------------------------------------------
  # Control-head `)` followed by a regex — the THIRD-rejection bug. A `)` that
  # closes the head of `if`/`while`/`for`/`switch`/… is a STATEMENT boundary
  # where `/` legally begins a regex (`if (c) /}/.test(s)`). The pre-fix lexer
  # classified EVERY `)` as a value ⇒ division, so it mis-lexed `/}/` as
  # division, counted the regex `}` as the function close, dropped the tail, and
  # false-skipped a real tail edit. The open-bracket stack now distinguishes a
  # control-head `)` (⇒ regex) from a call/grouping `)` (⇒ division). These three
  # cases drive the real record->edit-tail->decide path and assert a re-run.
  # ---------------------------------------------------------------------------

  test "regex after `if (cond)` control-head ) does not drop the tail":
    let root = freshRoot("if_regex")
    let srcRel = "/src/if_regex.js"
    let srcPath = root / "src" / "if_regex.js"
    createDir(srcPath.parentDir)
    let original = """function used_a() {
  if (cond) /}/.test(input);
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "regex after `while (cond)` control-head ) does not drop the tail":
    let root = freshRoot("while_regex")
    let srcRel = "/src/while_regex.js"
    let srcPath = root / "src" / "while_regex.js"
    createDir(srcPath.parentDir)
    let original = """function used_a() {
  while (cond) /}/.exec(input);
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "regex after `for (;;)` control-head ) does not drop the tail":
    let root = freshRoot("for_regex")
    let srcRel = "/src/for_regex.js"
    let srcPath = root / "src" / "for_regex.js"
    createDir(srcPath.parentDir)
    let original = """function used_a() {
  for (;;) /}/.test(input);
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "return /}/ regex (keyword-prefixed) does not drop the tail":
    # `return /}/` — the `/` follows the expression-introducing keyword
    # `return`, so it MUST be lexed as a regex, not division. A keyword-unaware
    # lexer would mis-read it as division and count the regex `}` as the block
    # close, dropping the tail (attempt-2 bug).
    let root = freshRoot("return_regex")
    let srcRel = "/src/return_regex.js"
    let srcPath = root / "src" / "return_regex.js"
    createDir(srcPath.parentDir)
    let original = """function used_a() {
  if (cond) return /}/.test(input);
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "void /}/g; regex (keyword-prefixed, with flags) does not drop the tail":
    # `void /}/g;` — the `/` follows the `void` keyword and the regex carries a
    # flag. Same keyword-unaware mis-lex as above.
    let root = freshRoot("void_regex")
    let srcRel = "/src/void_regex.js"
    let srcPath = root / "src" / "void_regex.js"
    createDir(srcPath.parentDir)
    let original = """function used_a() {
  void /}/g;
  let x = 1;
  return x;
}
"""
    writeFile(srcPath, original)
    let traceDir = root / "trace"
    writeMinimalTrace(traceDir, srcRel, 1)

    var cache = initCache(root / "cache.json")
    check record(cache, testId, traceDir, root).isOk

    let edited = original.replace("let x = 1;", "let x = 999;")
    check edited != original
    writeFile(srcPath, edited)

    let d = decide(testId, traceDir, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "unterminated regex fails safe to Err (=> re-run), never under-captures":
    # If the lexer cannot resolve the construct (here, an unterminated regex on
    # the def's own line so the body never balances), it must NOT return a body
    # it is unsure about. The extractor returns Err; the engine maps that to the
    # `"missing"` shallow hash, so any such function always re-runs.
    let src = @[
      "function used_a() {",
      "  const re = /unterminated ;",   # no closing `/` => ambiguous
      "  let x = 1;",
      "  return x;",
      "}"]
    let body = extractFunctionBody("x.js", src, 1)
    check body.isErr