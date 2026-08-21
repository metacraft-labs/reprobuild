## The declaration document is written while the declarations still exist.
##
## Named-Lock-Files NLF-M8. A regression test for a defect this milestone
## found in NLF-M7's own code while discharging the folded criterion
## "**`repro lock list` verified end to end**, not only at its renderer".
##
## ## The defect, and why it is the campaign's own subject matter
##
## M7 emitted the registry from an `addExitProc` closure. `exitprocs`
## callbacks run after ORC has destroyed module globals, so by the time the
## closure walked `declared` its strings were freed and `strutils.replace`
## faulted on a nil payload — **SIGSEGV in every process that imported
## `repro_lock_files` with `REPRO_EMIT_LOCK_FILES` set.**
##
## What made it invisible is the interesting part. The crash happened in the
## provider CHILD process; the CLI saw exit 139 as a failed command, caught it
## with the lock-list probe's `except CatchableError`, and printed
## `predeclaredLockFiles()`. That output is a perfectly good listing for a
## workspace that declares nothing, so the failure rendered as a plausible
## answer to a different question. `repro lock list` could never have reported
## a workspace's declarations, and nothing said so.
##
## ## What is asserted
##
## That the document exists **before the process exits** — which is the
## property, not an implementation detail. An exit-proc emission cannot
## satisfy it, so re-introducing one fails this file rather than passing it
## and crashing somewhere else.
##
## A SIGSEGV cannot be caught, so there is deliberately no attempt to assert
## on the crash itself. Asserting on the property that replaced it is both
## sufficient and the only thing an in-process test can honestly do.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The real registry, the real emission, the real renderer and the real
## parser, against a real file.

import std/[os, strutils, unittest]

import repro_lock_files

const
  Ship = "shipEagerly"
  MultiLine = "Everything we ship.\nPinned to the aarch64 target graph."

var emitPath = ""

suite "NLF-M8 lock-file declarations are emitted eagerly":

  setup:
    resetLockFileDeclarations()
    emitPath = getTempDir() /
      ("repro-nlf-m8-emit-" & $getCurrentProcessId() & ".tsv")
    removeFile(emitPath)
    putEnv(LockFilesEmitEnvVar, emitPath)

  teardown:
    delEnv(LockFilesEmitEnvVar)
    resetLockFileDeclarations()
    try: removeFile(emitPath)
    except CatchableError: discard

  test "declaring a lock file writes the document immediately":
    check not fileExists(emitPath)
    discard declareLockFile(Ship, description = MultiLine)
    check fileExists(emitPath)

  test "the document carries the declaration and the well-known set":
    discard declareLockFile(Ship, description = MultiLine)
    let parsed = parseLockFileDeclarations(readFile(emitPath))
    var names: seq[string] = @[]
    for d in parsed: names.add(d.name)
    checkpoint("parsed: " & $names)
    check Ship in names
    check DefaultLockFileName in names
    check HostToolsLockFileName in names

  test "a multi-line description round-trips":
    # The field that faulted. It is escaped on the way out because a raw
    # newline would make the record separator ambiguous, so the round trip is
    # the assertion rather than the presence of the text.
    discard declareLockFile(Ship, description = MultiLine)
    var found = ""
    for d in parseLockFileDeclarations(readFile(emitPath)):
      if d.name == Ship: found = d.description
    check found == MultiLine
    check "\n" in found

  test "a second declaration rewrites a COMPLETE document":
    # Each declaration overwrites the file, so the last write has to contain
    # every earlier one. An implementation that appended would produce a
    # second header row and a reader that skipped it silently; an
    # implementation that wrote only the newest would lose the first.
    discard declareLockFile(Ship, description = MultiLine)
    discard declareLockFile("secondEagerly", description = "The other one.")
    var names: seq[string] = @[]
    for d in parseLockFileDeclarations(readFile(emitPath)):
      names.add(d.name)
    check Ship in names
    check "secondEagerly" in names
    check readFile(emitPath).count("# repro lock files v1") == 1

  test "with the variable unset, nothing is written":
    # The emission must be invisible to an ordinary run. It is on a path every
    # recipe takes at module init now, so a version that wrote unconditionally
    # would put a stray file next to every build.
    delEnv(LockFilesEmitEnvVar)
    discard declareLockFile(Ship, description = MultiLine)
    check not fileExists(emitPath)
