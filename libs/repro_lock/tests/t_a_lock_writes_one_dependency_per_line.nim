## The writer lays `deps` out one record per line, with the lock's own
## (volatile) entry set apart, so landings do not conflict.
##
## THE DEFECT THIS IS THE REGRESSION FOR: the writer put the whole `deps` array on
## one line. The lock's own entry carries the repository's current commit and
## is rewritten by every landing, so every landing changed the one line that
## also held every pin: two branches that differed there -- one moving a pin,
## one merely landing -- conflicted, and git cannot merge one line by parts.
##
## Cases:
##   1. each dependency is on its own physical line and the self record comes
##      first, followed by an unchanged comment line before the first pin;
##   2. the document reads back whole and re-serializes byte-identically, and
##      a lock with no self entry, or only one, round-trips too;
##   3. THE REQUIRED MERGE TEST: from one base, branch A moves pin `lib-b`,
##      branch B moves pin `lib-d` AND is a landing (the self revision moves).
##      `git merge-file` merges them with no conflict, the merge holds both
##      pins moved, and the self revision in the merged result is B's;
##   4. the self revision is not on any pin's line, so a landing's diff holds
##      exactly one changed line;
##   5. the old one-line layout still reads (migration is the next write).
##
## Falsifiability: against the writer before the fix, case 1 and 4 fail (one
## `deps` line) and case 3 reports a conflict (exit status 1).
##
## Test-double policy: NO mocks. Real writer, real reader, and the real
## `git merge-file` that git itself uses for a content merge.

import std/[os, osproc, strutils, unittest]

import repro_lock

import ./nlf_lock_fixtures

const Platform = "amd64-linux"

proc vcsDep(name, rev: string; self = false): LockedDep =
  LockedDep(name: name,
    path: (if self: SelfLockedDepPath else: defaultLockedDepCheckoutPath(name)),
    coordinates: Coordinates(kind: ckVcs,
      url: "https://example.invalid/" & name & ".git", revision: rev),
    integrity: "git-sha1:" & rev)

proc lockWith(selfRev: string; pins: openArray[(string, string)]): string =
  var ld = lockedDepsFromSolved(solutionToLock(
    solutionOf(@[("nim", "2.2.0")], []), Platform, "packages: demo"))
  ld.deps = @[vcsDep("app", selfRev, self = true)]
  for (n, r) in pins: ld.deps.add(vcsDep(n, r))
  serializeLockedDependencies(ld)

const Pins = [("lib-a", "1"), ("lib-b", "2"), ("lib-c", "3"),
              ("lib-d", "4")]

proc rev(c: char): string = repeat(c, 40)

proc pinsWith(changed: string; to: char): seq[(string, string)] =
  for (n, r) in Pins:
    result.add((n, if n == changed: rev(to) else: rev(r[0])))

proc recordLines(doc: string): seq[string] =
  for l in doc.splitLines():
    if l.strip().startsWith("{ name"): result.add(l)

suite "the writer lays deps out one record per line":

  test "one record per line, self first, a comment line after it":
    let doc = lockWith(rev('a'), pinsWith("", 'z'))
    let lines = recordLines(doc)
    check lines.len == 5
    check "self = \"true\"" in lines[0]
    for l in lines[1 .. ^1]: check "self = " notin l
    check doc.count("\ndeps = [\n") == 1
    let body = lockStatementSource(doc, "deps")
    check body.count('\n') == 8  # open, self, 2-line comment, 4 pins, close
    check body.splitLines()[2].strip().startsWith("#")

  test "it reads back whole and re-serializes byte-identically":
    for doc in [lockWith(rev('a'), pinsWith("", 'z')),
                lockWith(rev('a'), []),
                lockWith(rev('a'), [("lib-a", rev('1'))])]:
      let ld = parseLockedDependencies(doc)
      check serializeLockedDependencies(ld) == doc
      check ld.deps.len == recordLines(doc).len
    var none = parseLockedDependencies(lockWith(rev('a'), []))
    none.deps = @[]
    check "deps = []\n" in serializeLockedDependencies(none)

  test "branches that move different pins merge cleanly; self stays out":
    let dir = getTempDir() / "lock-merge-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "base", lockWith(rev('a'), pinsWith("", 'z')))
    # A: moves lib-b only. B: a landing (self moves) that also moves lib-d.
    writeFile(dir / "a", lockWith(rev('a'), pinsWith("lib-b", '9')))
    writeFile(dir / "b", lockWith(rev('b'), pinsWith("lib-d", '8')))
    let (output, status) = execCmdEx("git merge-file -p " &
      quoteShell(dir / "a") & " " & quoteShell(dir / "base") & " " &
      quoteShell(dir / "b"))
    check status == 0
    check "<<<<<<<" notin output
    let merged = parseLockedDependencies(output)
    var revs: seq[(string, string)]
    for d in merged.deps: revs.add((d.name, d.coordinates.revision))
    check revs == @[("app", rev('b')), ("lib-a", rev('1')),
      ("lib-b", rev('9')), ("lib-c", rev('3')), ("lib-d", rev('8'))]
    # A branch that only moved a pin never touches the self record.
    check recordLines(lockWith(rev('a'), pinsWith("lib-b", '9')))[0] ==
      recordLines(lockWith(rev('a'), pinsWith("", 'z')))[0]

  test "a landing changes exactly one line":
    let before = recordLines(lockWith(rev('a'), pinsWith("", 'z')))
    let after = recordLines(lockWith(rev('b'), pinsWith("", 'z')))
    var differing = 0
    for i in 0 ..< before.len:
      if before[i] != after[i]: inc differing
    check differing == 1
    check before[0] != after[0]

  test "the old one-line layout still reads":
    let doc = lockWith(rev('a'), pinsWith("", 'z'))
    var flat: seq[string]
    for l in recordLines(doc): flat.add(l.strip().strip(chars = {','}))
    let old = doc.replace(lockStatementSource(doc, "deps"),
      "deps = [" & flat.join(", ") & "]")
    check old.count("deps = [") == 1 and "\n  {" notin old
    check serializeLockedDependencies(parseLockedDependencies(old)) == doc
