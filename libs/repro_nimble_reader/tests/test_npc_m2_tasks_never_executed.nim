## NPC-M2 `test_npc_m2_tasks_never_executed` (threat model G1): reading a
## `.nimble` never evaluates it. A file whose `task` body, `before install`
## hook and top-level statements would each write a file is read, and none of
## the files exists afterwards; the task and the hook are recorded as flags.
##
## The top-level canary is what makes the test fail if the reader is replaced
## by an evaluation: Nimble runs a `.nimble`'s top-level code on every read
## (`nimble dump` included), so a NimScript evaluation writes it even when no
## task is invoked. The task and hook canaries cover a reader that runs those
## bodies.
##
## The second case is the structural half of the control: the library's
## sources import nothing that can start a process or evaluate Nim code.

import std/[os, strutils, unittest]

import repro_nimble_reader
import repro_nimble_reader/lexer
import repro_test_support/process_fixtures

suite "npc-m2 tasks never executed":
  test "test_npc_m2_tasks_never_executed":
    let dir = getTempDir() / ("npc_m2_tasks_" & $getCurrentProcessId())
    releaseDirAtProcessExit(dir)
    createDir(dir)
    let topCanary = dir / "top-level.canary"
    let execCanary = dir / "exec.canary"
    let taskCanary = dir / "task.canary"
    let hookCanary = dir / "hook.canary"
    writeFile(dir / "hostile.nimble",
      "version = \"0.1.0\"\n" &
      "author = \"someone\"\n" &
      "description = \"reads as data, never runs\"\n" &
      "license = \"MIT\"\n" &
      "srcDir = \"src\"\n" &
      "requires \"nim >= 2.0.0\", \"results >= 0.5.0\"\n" &
      "\n" &
      "writeFile(\"" & topCanary & "\", \"top level ran\")\n" &
      "exec \"touch " & execCanary & "\"\n" &
      "\n" &
      "task build, \"writes a file\":\n" &
      "  writeFile(\"" & taskCanary & "\", \"task ran\")\n" &
      "  requires \"never-a-dependency\"\n" &
      "\n" &
      "before install:\n" &
      "  writeFile(\"" & hookCanary & "\", \"hook ran\")\n")
    let reading = readPackageDir(dir)
    require reading.kind == prRead
    let f = reading.file
    for canary in [topCanary, execCanary, taskCanary, hookCanary]:
      checkpoint canary
      check not fileExists(canary)
    check flHasTasks in f.flags
    check flHasHooks in f.flags
    check flTopLevelExec in f.flags
    # The record is read; a `requires` inside the task body is not.
    check f.readerClass == rcPlain
    check f.srcDir == "src"
    check f.sourceDir(dir) == dir / "src"
    check f.nim.len == 1
    require f.requires.len == 1
    check f.requires[0].requirement.target.name == "results"
    check f.author == "someone"

  test "the reader's sources cannot start a process or evaluate Nim":
    # An allow-list of imports, read from the tokens (so an import list
    # spread over several lines is read whole), over the library's sources
    # and the one module of another library they import. Adding `osproc`,
    # the compiler's modules (and with them the NimScript VM), `dynlib` or
    # anything else fails here. So does a call that needs no import: the
    # compile-time `staticExec`/`gorge`/`staticRead`, a process or file
    # primitive, or a foreign-code pragma. The one file read is the
    # `.nimble` itself (`readNimbleFile`), and the one `open` is parsecfg's,
    # over a string stream.
    const Allowed = ["strutils", "unicode", "options", "parsecfg", "streams",
                     "sequtils", "algorithm", "os",
                     "repro_solver/version_constraints",
                     "./lexer", "./syntax", "./conditions", "./requirements",
                     "./reader", "repro_nimble_reader/reader"]
    const Banned = ["staticExec", "gorge", "gorgeEx", "staticRead", "slurp",
                    "exec", "selfExec", "execShellCmd", "execCmd",
                    "execCmdEx", "execProcess", "startProcess", "writeFile",
                    "readLines", "File", "newFileStream", "openFileStream",
                    "importc", "importcpp", "emit", "dynlib", "compile",
                    "passL", "passC"]
    # identifier -> (the one file that may use it, how often)
    const Counted = [("readFile", "repro_nimble_reader.nim", 1),
                     ("open", "reader.nim", 1)]
    let src = currentSourcePath().parentDir.parentDir / "src"
    var paths: seq[string]
    for path in walkDirRec(src):
      if path.endsWith(".nim"):
        paths.add path
    let solverModule = currentSourcePath().parentDir.parentDir.parentDir /
      "repro_solver" / "src" / "repro_solver" / "version_constraints.nim"
    require fileExists(solverModule)
    paths.add solverModule
    var counted: seq[(string, string)]
    var imports = 0
    for path in paths:
      let lexed = lexNim(readFile(path))
      require lexed.errors.len == 0
      let toks = lexed.tokens
      var i = 0
      while i < toks.len:
        let t = toks[i]
        if t.kind == tkIdent:
          for b in Banned:
            if nimIdentEq(t.text, b):
              checkpoint path & ":" & $t.line & ": " & t.text
              check false
          for (name, _, _) in Counted:
            if nimIdentEq(t.text, name):
              counted.add (name, path.extractFilename)
        if t.kind == tkIdent and t.firstOnLine and (t.isKeyword("import") or
            t.isKeyword("include") or t.isKeyword("from")):
          # The statement runs to the next line start outside brackets that
          # does not continue a comma-separated list.
          var j = i + 1
          var depth = 0
          var prefix = ""
          var module = ""
          template flush(module, prefix: untyped) =
            if module.len > 0:
              inc imports
              checkpoint path & ":" & $t.line & ": " & prefix & module
              check (prefix & module).replace("std/", "") in Allowed
            module = ""
          while j < toks.len and toks[j].kind != tkEof:
            let u = toks[j]
            if u.firstOnLine and depth == 0 and toks[j - 1].kind != tkComma:
              break
            if t.isKeyword("from") and u.isKeyword("import"):
              break
            if u.isKeyword("except") or u.isKeyword("as"):
              break
            case u.kind
            of tkOpenBracket:
              inc depth
              prefix = module
              module = ""
            of tkCloseBracket:
              flush(module, prefix)
              dec depth
              prefix = ""
            of tkComma:
              flush(module, prefix)
            of tkString:
              module.add u.value
            else:
              module.add u.text
            inc j
          flush(module, prefix)
          i = j
          continue
        inc i
    for (name, file, times) in Counted:
      var seen: seq[string]
      for (n, f) in counted:
        if n == name:
          seen.add f
      checkpoint name & " used in " & $seen
      check seen.len == times
      for f in seen:
        check f == file
    check paths.len >= 7
    check imports >= 15
