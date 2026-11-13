## A committed lock whose array value spans several physical lines is read
## WHOLE, and a layout the reader cannot follow is refused by name.
##
## THE DEFECT THIS IS THE REGRESSION FOR (reprobuild-pm issue
## 2026-11-12-the-pre-commit-lock-rewrite-misreads-a-multi-line-deps-entry-
## and-writes-invalid-toml). A `repro.lock` whose `deps` array was laid out
## as TOML continuation lines —
##
##     deps = [{ name = "a", ... }
##     , { name = "b", ... }
##     , { name = "c", ... }]
##
## — is valid TOML. The reader took one PHYSICAL line per key, so it read the
## first line alone: `deps` came back holding only `a`, and the continuation
## lines (whose text before `=` is `, { name`) were skipped as unknown keys.
## The commit-time re-pin then located `deps` by the same physical line,
## replaced that line, and left the continuation lines behind: a file that no
## longer parses as TOML.
##
## Cases:
##   1. the continuation-line layout reads back to exactly the deps the
##      canonical single-line layout reads back to (and so does a layout with
##      one record per line, a trailing comma and comments between records);
##   2. ``lockStatementSource`` returns the whole multi-line `deps` statement,
##      byte for byte, so a writer that replaces it replaces all of it — and
##      replacing it with the canonical line yields the canonical document;
##   3. the document the defect wrote (the first line replaced, the
##      continuation lines left behind) is REFUSED with
##      `SolvedGraphLockParseError` naming the line, rather than read as a
##      lock that pins less than it says;
##   4. an array still open at the end of the document is refused likewise,
##      naming its key (`deps: truncated`);
##   5. the CONTROL: the canonical one-line layout keeps reading exactly as
##      before, and a `deps` statement inside the certificate-policy snapshot
##      is not the lock's.
##
## Falsifiability (observed against `agents` 3a64ddc14, the reader before the
## fix): case 1 reads one dependency instead of three in every layout,
## including CRLF; case 2 does not compile (no ``lockStatementSource``); cases
## 3 and 4 read without raising; case 5 passes.
##
## Test-double policy: NO mocks. The real `serializeLockedDependencies` writes
## each document and the real `parseLockedDependencies` reads it; the
## continuation-line documents are that output re-laid-out by text edits,
## exactly as a hand edit produced codetracer `a0efd6494`'s lock.

import std/[strutils, unittest]

import repro_lock

import ./nlf_lock_fixtures

const Platform = "amd64-linux"

proc vcsDep(name, rev: string; self = false): LockedDep =
  LockedDep(name: name,
    path: (if self: SelfLockedDepPath else: defaultLockedDepCheckoutPath(name)),
    coordinates: Coordinates(kind: ckVcs,
      url: "https://example.invalid/" & name & ".git", revision: rev),
    integrity: "git-sha1:" & rev)

proc threeDepLock(): LockedDependencies =
  result = lockedDepsFromSolved(solutionToLock(
    solutionOf(@[("libfoo", "1.4.2"), ("nim", "2.2.0")], []), Platform,
    "packages: demo"))
  result.deps = @[
    vcsDep("app", repeat('1', 40), self = true),
    vcsDep("lib-b", repeat('2', 40)),
    vcsDep("lib-c", repeat('3', 40))]
  result.deps[0].depends = @["lib-b", "lib-c"]

proc depsLineOf(doc: string): string =
  for line in doc.splitLines():
    if line.startsWith("deps = ["): return line
  ""

proc continuationLayout(doc: string): string =
  ## The layout codetracer `a0efd6494` committed: each record after the first
  ## on its own line, opened by the separating comma.
  let line = depsLineOf(doc)
  doc.replace(line, line.replace("}, { name", "}\n, { name"))

proc depNames(ld: LockedDependencies): seq[string] =
  for d in ld.deps: result.add(d.name)

proc depRevisions(ld: LockedDependencies): seq[string] =
  for d in ld.deps: result.add(d.coordinates.revision)

suite "a lock value spread over several lines":

  test "the continuation-line layout reads every dependency":
    let canonical = serializeLockedDependencies(threeDepLock())
    let spread = continuationLayout(canonical)
    # The fixture really is the issue's layout: three physical lines.
    check spread.count("\n, { name = ") == 2
    let expected = parseLockedDependencies(canonical)
    let got = parseLockedDependencies(spread)
    check depNames(got) == @["app", "lib-b", "lib-c"]
    check depNames(got) == depNames(expected)
    check depRevisions(got) == depRevisions(expected)
    check got.deps[0].depends == @["lib-b", "lib-c"]
    # Read whole, it re-serializes to the canonical document.
    check serializeLockedDependencies(got) == canonical

  test "one record per line, a trailing comma and comments read too":
    let canonical = serializeLockedDependencies(threeDepLock())
    let line = depsLineOf(canonical)
    let body = line["deps = [".len ..< line.len - 1]
    let laidOut = "deps = [ # one record per line\n  " &
      body.replace("}, { name", "},\n  # the next sibling\n  { name") &
      ",\n]"
    let doc = canonical.replace(line, laidOut)
    check doc.count('\n') > canonical.count('\n') + 3
    check serializeLockedDependencies(parseLockedDependencies(doc)) ==
      canonical

  test "lockStatementSource returns the whole multi-line statement":
    let canonical = serializeLockedDependencies(threeDepLock())
    let spread = continuationLayout(canonical)
    let source = lockStatementSource(spread, "deps")
    check source.startsWith("deps = [{ name = \"app\"")
    check source.endsWith("}]")
    check source.count('\n') == 2
    check spread.count(source) == 1
    # Replacing exactly that span with the canonical line is the canonical
    # document: nothing of the old statement is left behind.
    check spread.replace(source, depsLineOf(canonical)) == canonical
    # On the canonical layout it is the one line, unchanged.
    check lockStatementSource(canonical, "deps") == depsLineOf(canonical)
    check lockStatementSource(canonical, "provisioning") == ""

  test "CRLF line endings keep the statement's own bytes":
    let canonical = serializeLockedDependencies(threeDepLock())
    let spread = continuationLayout(canonical).replace("\n", "\r\n")
    let source = lockStatementSource(spread, "deps")
    check source.count("\r\n") == 2
    check not source.endsWith("\r")
    check spread.count(source) == 1
    check depNames(parseLockedDependencies(spread)) ==
      @["app", "lib-b", "lib-c"]

  test "the document the old rewrite left behind is refused by name":
    let canonical = serializeLockedDependencies(threeDepLock())
    let spread = continuationLayout(canonical)
    # What the pre-commit re-pin wrote: the FIRST physical line replaced by a
    # complete one-line array, the continuation lines left where they were.
    let firstLine = depsLineOf(spread)
    check firstLine.len > 0 and firstLine != depsLineOf(canonical)
    let broken = spread.replace(firstLine, depsLineOf(canonical))
    check broken.count("\n, { name = ") == 2
    expect SolvedGraphLockParseError:
      discard parseLockedDependencies(broken)
    try:
      discard parseLockedDependencies(broken)
    except SolvedGraphLockParseError as err:
      check "line" in err.msg
    expect SolvedGraphLockParseError:
      discard lockStatementSource(broken, "deps")

  test "an array still open at the end of the document is refused":
    let canonical = serializeLockedDependencies(threeDepLock())
    let line = depsLineOf(canonical)
    let truncated = canonical.replace(line, line[0 ..< line.len - 1])
    expect SolvedGraphLockParseError:
      discard parseLockedDependencies(truncated)
    # The refusal names the key whose value was cut short, as the per-key
    # readers do for a value truncated on its own line.
    var refusal = ""
    try:
      discard parseLockedDependencies(truncated)
    except SolvedGraphLockParseError as err:
      refusal = err.msg
    check "deps: truncated" in refusal
    expect SolvedGraphLockParseError:
      discard lockStatementSource(truncated, "deps")

  test "the CONTROL: the one-line layout and the policy section":
    let ld = threeDepLock()
    let canonical = serializeLockedDependencies(ld)
    check depNames(parseLockedDependencies(canonical)) ==
      @["app", "lib-b", "lib-c"]
    # A `deps` key inside the certificate-policy snapshot is not the lock's
    # statement, and does not shadow it.
    let withPolicy = canonical & "\n[certificate_policy]\ndeps = [\"x\"]\n"
    check lockStatementSource(withPolicy, "deps") == depsLineOf(canonical)
