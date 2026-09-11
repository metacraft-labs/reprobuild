## t_m4_pure_unit_consolidation — the shared pure-unit binaries still carry
## every case they absorbed, under the identity that case had before it moved,
## and the move actually removed binaries and bytes.
##
## What this file is for
## ---------------------
## Suite-Modernization M4 consolidates pure-unit tests into shared
## protocol-aware binaries. The saving is real — one test binary re-compiles
## the whole shared library closure into its own private nimcache, so folding N
## of them into one compiles that closure once instead of N times — but the
## saving is trivially obtainable by LOSING cases, and a footprint report that
## cannot tell a consolidation from a deletion is worse than no report at all.
##
## So each of the three cases below is paired with the way it can be made to
## fail:
##
##   * ``test_consolidated_pure_unit_cases_list_individually`` — every case a
##     bundle absorbed is enumerated by that bundle's ``--list-json`` AND runs
##     through ``--run "suite::test"`` with exit 0. Deleting a ``test`` from a
##     member, or breaking its body, turns this red.
##   * ``test_consolidation_reduces_binary_footprint`` — the batch removes
##     binaries and bytes WITHOUT removing cases. Dropping a member from a
##     bundle without dropping it from the ledger turns this red; so does a
##     bundle whose binary is not smaller than the members it replaced.
##   * ``test_consolidation_preserves_selection_names`` — every ``suite::test``
##     selector that addressed a case before the move still addresses it, with
##     the same suite. Renaming a member's ``suite`` turns this red even though
##     the case still runs, which is the whole point: the fork's
##     ``std/unittest`` matches the full ``suite::test`` form only (verified
##     below by the negative controls), so a changed suite name is a broken
##     selector, not a cosmetic edit.
##
## The two sides of "no case was lost"
## -----------------------------------
## One ledger per landed batch — `…-m4-consolidation-batch1.json`,
## `…-m4-consolidation-batch2.json`, see ``LedgerPaths`` — records, per member,
## the exact case names read from THAT MEMBER'S OWN standalone binary before it
## was folded in. That is a measurement, not a restatement of the source: it
## comes from a compiled binary answering ``--list-json``. A later batch adds a
## ledger; it never rewrites an earlier one, because the standalone binaries an
## earlier ledger describes no longer exist and a restated measurement is not
## a measurement.
##
## The ledger alone would still be one document that a careless edit could
## bring back into agreement with a loss. So the case count is cross-checked
## against `scripts/reprobuild-suite-static-case-counts.tsv`, which a different
## program (`scripts/reprobuild_suite_inventory.py`, in a different language,
## gated separately by ``--check-static-case-counts``) derives by scanning the
## members' SOURCES. Two producers, no shared code, and a loss has to be
## written into both before this file goes quiet.
##
## The negative controls, and why they are here
## --------------------------------------------
## An exit-code check on ``--run`` is worthless if ``--run`` exits 0 for a name
## that selects nothing. The first case therefore also runs a name that cannot
## exist and a bare test name with the suite stripped off, and requires BOTH to
## fail. If they ever stop failing, every per-case assertion in this file has
## become vacuous, and this file says so instead of reporting green.
##
## Mocking: none. The binaries are the real graph-built bundles, driven as
## subprocesses; the ledger and the static-count table are the real checked-in
## artifacts. There is no stand-in for either side.

import std/[algorithm, json, os, osproc, sequtils, sets, strutils, tables,
            unittest]

const
  RepoRootMarker = "repro.nim"
  LedgerPaths = [
    "benchmarks/reports/reprobuild-suite-m4-consolidation-batch1.json",
    "benchmarks/reports/reprobuild-suite-m4-consolidation-batch2.json",
  ]
    ## ONE LEDGER PER LANDED BATCH, in the order they landed, and never a
    ## rewrite of an earlier one.
    ##
    ## Each ledger records what each member's OWN standalone binary
    ## enumerated before it was folded in. Those binaries no longer exist once
    ## a batch lands, so an earlier ledger cannot be re-measured — it can only
    ## be restated, which is the one thing a measurement record must not be.
    ## A later batch therefore adds a file here; it does not edit the ones
    ## above it. Everything below iterates all of them, and the suite-level
    ## arithmetic each ledger claims is checked PER LEDGER, because those
    ## totals are dated facts about different trees.
  StaticCountsPath = "scripts/reprobuild-suite-static-case-counts.tsv"
  TestTablePath = "repro_tests.nim"
  GeneratorPath = "scripts/generate_test_edges.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / TestTablePath):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError,
    "could not find the reprobuild checkout root above " & currentSourcePath())

let repoRoot = findRepoRoot()

proc readLedger(relative: string): JsonNode =
  let path = repoRoot / relative
  if not fileExists(path):
    raise newException(IOError,
      "the M4 consolidation ledger is missing at " & path & ". It is the " &
      "record of what each member's own binary enumerated before it was " &
      "folded into a bundle; without it this file cannot tell a " &
      "consolidation from a deletion, and passing would assert exactly the " &
      "thing it cannot check.")
  parseJson(readFile(path))

let ledgers = block:
  var acc: seq[JsonNode] = @[]
  for path in LedgerPaths:
    acc.add(readLedger(path))
  acc

proc allBundles(): seq[JsonNode] =
  ## Every bundle any landed batch measured, in batch order.
  result = @[]
  for ledger in ledgers:
    for bundle in ledger["bundles"]:
      result.add(bundle)

proc bundleBinary(bundle: JsonNode): string =
  result = repoRoot / bundle["binary"].getStr()
  when defined(windows):
    result = result & ".exe"

proc requireBuilt(path: string) =
  if not fileExists(path):
    raise newException(IOError,
      "shared pure-unit binary not built: " & path & ". Its execute edge " &
      "declares every bundle as a typed input (see " &
      "`M4ConsolidationVerificationTest` in repro.nim), so reaching this " &
      "point means the graph ran the test without its inputs — which is a " &
      "defect in the edge, not a reason to skip.")

proc listJson(binary: string): JsonNode =
  ## The bundle's own catalog, read from the binary rather than from a source
  ## scan. `--list-json` writes the document on stdout.
  let outcome = execCmdEx(quoteShell(binary) & " --list-json")
  if outcome.exitCode != 0:
    raise newException(IOError,
      binary & " --list-json exited " & $outcome.exitCode & ":\n" &
      outcome.output)
  let start = outcome.output.find('{')
  if start < 0:
    raise newException(IOError,
      binary & " --list-json produced no JSON document:\n" & outcome.output)
  parseJson(outcome.output[start .. ^1])

proc catalogNames(doc: JsonNode): seq[string] =
  result = @[]
  for entry in doc["tests"]:
    result.add(entry["name"].getStr())

proc catalogFiles(doc: JsonNode): Table[string, string] =
  ## case name -> the `file` field the binary reports for it. Used to
  ## ATTRIBUTE a case the ledger does not record to the member source it came
  ## from; see the extra-case block below for why absence is the wrong test.
  result = initTable[string, string]()
  for entry in doc["tests"]:
    result[entry["name"].getStr()] = entry["file"].getStr()

proc catalogSuites(doc: JsonNode): Table[string, string] =
  ## case name -> the `suite` field the binary reports for it.
  result = initTable[string, string]()
  for entry in doc["tests"]:
    result[entry["name"].getStr()] = entry["suite"].getStr()

proc runOne(binary, caseName: string): int =
  execCmd(quoteShell(binary) & " --run " & quoteShell(caseName) &
    " > " & quoteShell(if defined(windows): "NUL" else: "/dev/null") & " 2>&1")

proc ledgerMemberNames(bundle: JsonNode): seq[string] =
  result = @[]
  for member in bundle["members"]:
    for name in member["cases"]:
      result.add(name.getStr())

proc staticCaseCounts(): Table[string, int] =
  ## source path -> case count, from the separately gated static table.
  result = initTable[string, int]()
  for line in readFile(repoRoot / StaticCountsPath).splitLines():
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.split('\t')
    if fields.len < 3:
      continue
    try:
      result[fields[0]] = parseInt(fields[2])
    except ValueError:
      continue

proc testTableSources(): HashSet[string] =
  ## Every `source:` the generated test table declares. Read as text on
  ## purpose: this file must be able to observe a source LEAVING the table,
  ## which is precisely what consolidation does to a member.
  result = initHashSet[string]()
  for line in readFile(repoRoot / TestTablePath).splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("source: \""):
      continue
    let rest = trimmed["source: \"".len .. ^1]
    let close = rest.find('"')
    if close > 0:
      result.incl(rest[0 ..< close])

suite "M4 pure-unit consolidation":

  test "test_consolidated_pure_unit_cases_list_individually":
    var checkedCases = 0
    var checkedBundles = 0
    for bundle in allBundles():
      let binary = bundleBinary(bundle)
      requireBuilt(binary)
      inc checkedBundles

      let doc = listJson(binary)
      var enumerated = catalogNames(doc)
      var expected = ledgerMemberNames(bundle)
      enumerated.sort()
      expected.sort()

      let missing = expected.filterIt(it notin enumerated.toHashSet)
      let extra = enumerated.filterIt(it notin expected.toHashSet)

      # THE LOSS DETECTOR, and it is exact. Every case name the ledger read
      # out of a member's own standalone binary must still enumerate here.
      check missing.len == 0
      if missing.len > 0:
        checkpoint(bundle["name"].getStr() & " lost " & $missing.len &
          " case(s): " & missing.join(", "))

      # EXTRA CASES ARE ATTRIBUTED, NOT FORBIDDEN.
      #
      # This used to be `check extra.len == 0`, and that was wrong in a way
      # only a merge could show. The ledger is a DATED record of what each
      # member enumerated before it was folded in; it is never rewritten,
      # because the standalone binaries it describes no longer exist. A live
      # repository, meanwhile, keeps adding cases to those member sources —
      # and every such addition made this equality red, permanently, for a
      # reason the author of the addition did not cause and could not fix
      # without rewriting a measurement record.
      #
      # That is not hypothetical. Merging `origin/dev` into this batch turned
      # it red: three unrelated packaging commits added seven `test` blocks to
      # `libs/repro_dsl_stdlib/tests/t_packaging_wrapper_vars_match_flake.nim`,
      # a member of bundle_repro_dsl_stdlib_catalogs_pure_unit, and the bundle
      # enumerated 112 against a recorded 110.
      #
      # What `extra.len == 0` was actually buying is kept in full: it caught a
      # member that was added to the generator's bundle table and never
      # written into the ledger, whose cases would then be compiled, run, and
      # vouched for by nobody. So the test is now attribution rather than
      # absence — every extra case must come from a FILE this bundle's ledger
      # entry lists as a member. A case added to a known member is the
      # repository working; a case arriving from a file no ledger names is the
      # defect, and it still goes red here.
      var memberFiles = initHashSet[string]()
      for member in bundle["members"]:
        memberFiles.incl(extractFilename(member["source"].getStr()))
      let byName = catalogFiles(doc)
      var unattributed: seq[string] = @[]
      for name in extra:
        let file = byName.getOrDefault(name, "")
        if file notin memberFiles:
          unattributed.add(name & " (from `" & file & "`)")
      check unattributed.len == 0
      if unattributed.len > 0:
        checkpoint(bundle["name"].getStr() & " enumerates " &
          $unattributed.len & " case(s) from a file no ledger lists as one " &
          "of its members: " & unattributed.join(", ") & ". A member added " &
          "to `PureUnitBundles` in " & GeneratorPath & " and not written " &
          "into a ledger is a member whose cases nobody vouched for.")
      if extra.len > 0:
        checkpoint(bundle["name"].getStr() & " enumerates " & $extra.len &
          " case(s) added to its members since the batch landed; all are " &
          "attributed to files the ledger names.")

      for name in expected:
        let rc = runOne(binary, name)
        check rc == 0
        if rc != 0:
          checkpoint("`" & binary & " --run " & name & "` exited " & $rc &
            " (0 = passed, 1 = failed or selected nothing, 2 = skipped)")
        inc checkedCases

    # THE DENOMINATOR. A zero that does not say what it looked at is not a
    # result, and a ledger that lost its `bundles` array would otherwise make
    # every loop above pass by never running.
    checkpoint("checked " & $checkedCases & " cases across " &
      $checkedBundles & " bundles")
    check checkedBundles >= 1
    check checkedCases >= 1

    # EVERY BUNDLE IS ACCOUNTED FOR. The execute edge takes all of them as
    # typed inputs, so a bundle added to the generator and forgotten here
    # would be built, depended on, and never asked whether it kept its cases —
    # which is precisely the shape M4 must not ship. A bundle is either
    # measured in `bundles` or named, with a reason, in
    # `bundlesNotCoveredByThisLedger`; there is no third state.
    var covered = initHashSet[string]()
    for bundle in allBundles():
      covered.incl(bundle["name"].getStr())
    for ledger in ledgers:
      if ledger.hasKey("bundlesNotCoveredByThisLedger"):
        for name, _ in ledger["bundlesNotCoveredByThisLedger"]:
          covered.incl(name)
    for line in readFile(repoRoot / GeneratorPath).splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("name: \"bundle_"):
        continue
      let rest = trimmed["name: \"".len .. ^1]
      let close = rest.find('"')
      if close <= 0:
        continue
      let declared = rest[0 ..< close]
      check declared in covered
      if declared notin covered:
        checkpoint(declared & " is declared in " & GeneratorPath &
          " but neither measured in the ledger's `bundles` nor named in " &
          "`bundlesNotCoveredByThisLedger`. Its cases are checked by nothing.")

    # NEGATIVE CONTROLS. Without these the exit-code assertions above prove
    # nothing: they would be satisfied by a `--run` that exits 0 for anything.
    let probe = bundleBinary(allBundles()[0])
    let anchor = ledgerMemberNames(allBundles()[0])[0]
    check runOne(probe, "no such suite::no such test") != 0
    let bare = anchor[(anchor.find("::") + 2) .. ^1]
    check runOne(probe, bare) != 0

  test "test_consolidation_reduces_binary_footprint":
    let declaredSources = testTableSources()
    let staticCounts = staticCaseCounts()
    var removedBinaries = 0
    var casesBefore = 0
    var casesAfter = 0
    # PER LEDGER, because each ledger's suite-level pair is a dated fact about
    # the tree that batch landed on. Summing the removals across batches and
    # comparing to one batch's arithmetic would let one batch's numbers cover
    # for another's.
    var removedByLedger: seq[int] = @[]

    for ledger in ledgers:
      var removedHere = 0

      # THE STATED LIMITS, checked rather than documented. A size cap that
      # lives only in a comment is a cap until the first person in a hurry.
      let limits = ledger["limits"]
      let maxMembers = limits["maxBundleMembers"].getInt()
      let maxDeps = limits["maxDependencyRoots"].getInt()

      for bundle in ledger["bundles"]:
        let name = bundle["name"].getStr()
        let members = bundle["members"]
        check members.len >= 2
        check members.len <= maxMembers
        if members.len > maxMembers:
          checkpoint(name & " has " & $members.len & " members; the limit is " &
            $maxMembers & ". See MaxBundleMembers in " & GeneratorPath &
            " for what that number is and is not.")
        check bundle["dependencyShape"].len <= maxDeps
        # One owner per bundle: a bundle spanning two consolidation groups is a
        # failure nobody can bisect back to a group.
        for member in members:
          check member["source"].getStr().startsWith(
            bundle["owner"].getStr() & "/")

        # The binary really did leave the graph: no member has a spec of its
        # own any more, and the bundle has one.
        for member in members:
          let source = member["source"].getStr()
          check source notin declaredSources
          if source in declaredSources:
            checkpoint(source & " is still its own test binary, so " & name &
              " compiles and counts it twice")
        check bundle["source"].getStr() in declaredSources
        removedHere += members.len - 1

        # NO CASE WAS LOST — measured live, then cross-checked against a
        # different producer.
        let doc = listJson(bundleBinary(bundle))
        let enumerated = catalogNames(doc).len
        let recorded = ledgerMemberNames(bundle).len
        # A FALL IS A LOSS; A RISE IS THE REPOSITORY WORKING. Exact equality
        # here had the same defect as `extra.len == 0` above and for the same
        # reason — see that block. The loss this arm exists to catch is caught
        # by name, exactly, by `missing.len == 0` in case 1; this one holds the
        # count so a loss cannot hide behind a simultaneous addition.
        check enumerated >= recorded
        if enumerated < recorded:
          checkpoint(name & ": binary enumerates " & $enumerated &
            " cases, fewer than the " & $recorded &
            " the ledger records from its members")
        # THE SECOND PRODUCER, compared to the thing it can actually be
        # compared to.
        #
        # This used to read `staticTotal == enumerated`: the Python source
        # scan's count of the bundle against the built binary's own catalog.
        # That equality is FALSE IN GENERAL and the static table's own header
        # says so — the scan "sums every when/else branch and cannot expand
        # wrapper templates". `libs/repro_core/tests/t_smoke_repro_core.nim`
        # is exactly that case: six cases under `when defined(windows)` and
        # one under `else`, so the scan counts 14 where a Linux binary
        # enumerates 8. Batch 1 passed only because none of its 21 members
        # had a platform-conditional case; the invariant was never true, it
        # was untested.
        #
        # The comparison that IS well-formed keeps both producers and drops
        # the assumption that the scanner is exact: the scanner's count of the
        # BUNDLE must equal the scanner's count of the MEMBERS, summed, as
        # recorded per member in the ledger when the batch landed. The
        # over-count is a property of the member sources and survives the
        # move unchanged, so it cancels on both sides; a `test` block deleted
        # from a member does not. That makes the two producers independent for
        # the purpose claimed at the top of this file: a loss shows up here
        # (static) AND in `enumerated == recorded` above (the binary), and has
        # to be written into both before this file goes quiet.
        check staticCounts.hasKey(bundle["source"].getStr())
        let staticTotal = staticCounts.getOrDefault(bundle["source"].getStr())
        var staticFromMembers = 0
        var membersCarryStatic = true
        for member in members:
          if not member.hasKey("staticCaseCountAtBase"):
            membersCarryStatic = false
            break
          staticFromMembers += member["staticCaseCountAtBase"].getInt()
        if membersCarryStatic:
          # `>=`, for the same reason as the two arms above: the right-hand
          # side is a DATED sum and the member sources keep growing. A fall
          # below it is a `test` block that left a member and is the thing
          # this producer exists to catch; a rise is a `test` block someone
          # added, which is not a defect and must not redden this file.
          check staticTotal >= staticFromMembers
          if staticTotal < staticFromMembers:
            checkpoint(name & ": the static source scan counts " &
              $staticTotal & " cases in the bundle, FEWER than the " &
              $staticFromMembers & " its members summed when the batch " &
              "landed. The scan is one producer and the binary catalog is " &
              "the other; this side says a member's source lost a `test` " &
              "block.")
        else:
          # A ledger that predates `staticCaseCountAtBase` keeps the assertion
          # it shipped with, unchanged and unrelaxed. It happens to hold for
          # batch 1's members because none of them is platform-conditional. If
          # one ever becomes so, this goes red for a reason the message names,
          # and the fix is to give that ledger per-member static counts — not
          # to loosen the comparison.
          check staticTotal == enumerated
          if staticTotal != enumerated:
            checkpoint(name & ": the static source scan counts " & $staticTotal &
              " cases where the built binary enumerates " & $enumerated &
              ". This ledger carries no per-member static counts, so the " &
              "comparison is scan-against-binary, which is exact only while " &
              "no member has a `when`-conditional case.")
        casesBefore += recorded
        casesAfter += enumerated

        # FEWER BYTES, and measured on the live artifact rather than read back
        # out of the ledger.
        var standaloneBytes = 0'i64
        for member in members:
          standaloneBytes += member["standalone"]["binaryBytes"].getInt()
        let bundleBytes = getFileSize(bundleBinary(bundle))
        check bundleBytes < standaloneBytes
        if bundleBytes >= standaloneBytes:
          checkpoint(name & ": bundle binary is " & $bundleBytes &
            " bytes against " & $standaloneBytes &
            " bytes for the members it replaced — this batch costs space")

      removedByLedger.add(removedHere)
      removedBinaries += removedHere

      # The suite-level arithmetic THIS ledger claims has to be internally
      # consistent with what THIS ledger's bundles removed.
      let suiteFacts = ledger["suite"]
      let before = suiteFacts["nimTestBinariesBefore"].getInt()
      let after = suiteFacts["nimTestBinariesAfter"].getInt()
      let added = suiteFacts["binariesAddedByThisBatch"].getInt()
      check after < before
      # A batch may bring its own binaries with it (batch 1 brought this
      # verification test), so the suite-level fall can be smaller than the
      # number consolidation removed. Both numbers are stated; netting them
      # silently is how a batch that removed nothing could still look like a
      # reduction.
      check before - after == removedHere - added
      if before - after != removedHere - added:
        checkpoint(ledger["provenance"]["head"].getStr() & ": ledger says " &
          $before & " -> " & $after & " binaries, but " & $removedHere &
          " removed and " & $added & " added")

    check removedBinaries >= 1
    # `>=` for the third time and the last: `casesBefore` sums the ledgers'
    # dated per-member records and `casesAfter` sums what the bundles
    # enumerate today. Consolidation itself contributes zero to the
    # difference — every case that moved is still there, which is what
    # `missing.len == 0` asserts by name — so the only way this total can
    # move is a member source gaining or losing cases afterwards.
    check casesAfter >= casesBefore
    checkpoint("removed " & $removedBinaries & " binaries across " &
      $ledgers.len & " batch ledger(s) " & $removedByLedger & "; cases " &
      $casesBefore & " -> " & $casesAfter &
      (if casesAfter > casesBefore:
         " (+" & $(casesAfter - casesBefore) &
           " added to member sources since the batches landed)"
       else: ""))

    # DELIBERATELY NOT `after == declaredSources.len`.
    #
    # That equality is true today and would be false the moment anyone adds an
    # unrelated test — which is to say it would be red most of the time, and a
    # gate that is red for reasons the author did not cause is a gate somebody
    # deletes. The ledger's suite-wide pair is a dated record of what a batch
    # did, not a live invariant.
    #
    # The live invariant is the one above and it does not go stale: every
    # member has left the table, every bundle is in it, and the suite has at
    # least as many binaries as the MOST RECENT batch left behind. A silent
    # un-consolidation — a member quietly getting its own binary back — is
    # caught by the per-member `notin declaredSources` check, not by an
    # arithmetic total.
    #
    # ANCHORED TO THE NEWEST LEDGER, and that is a correction rather than a
    # refinement. When only batch 1's ledger existed this read
    # `declaredSources.len >= after` for that ledger, on the reasoning that
    # the count only ever grows. It does not: the next consolidation batch
    # makes it FALL, which turned an earlier batch's dated `after` into a
    # bound the tree no longer satisfies. Only the newest batch's `after` is
    # a lower bound, because every batch after it can only remove more.
    let newest = ledgers[^1]["suite"]
    let newestAfter = newest["nimTestBinariesAfter"].getInt()
    check declaredSources.len >= newestAfter
    checkpoint("newest ledger records " &
      $newest["nimTestBinariesBefore"].getInt() & " -> " & $newestAfter &
      " Nim test binaries at its batch; " & TestTablePath & " declares " &
      $declaredSources.len & " now")


  test "test_consolidation_preserves_selection_names":
    # Every selector that worked before the move still works, and still names
    # the same suite. The ledger's per-member case list is the "before": it was
    # read from that member's own binary while it still had one.
    var aliases = initTable[string, string]()
    for ledger in ledgers:
      if ledger.hasKey("compatibilityAliases"):
        for key, value in ledger["compatibilityAliases"]:
          aliases[key] = value.getStr()

    var preserved = 0
    for bundle in allBundles():
      let binary = bundleBinary(bundle)
      requireBuilt(binary)
      let doc = listJson(binary)
      let suites = catalogSuites(doc)

      for member in bundle["members"]:
        for entry in member["cases"]:
          let historic = entry.getStr()
          let current =
            if aliases.hasKey(historic): aliases[historic] else: historic
          check suites.hasKey(current)
          if not suites.hasKey(current):
            checkpoint("selector `" & historic & "` from " &
              member["source"].getStr() & " no longer names a case in " &
              bundle["name"].getStr() &
              ". A renamed suite is a broken selector even when the case " &
              "still runs; give it an explicit `compatibilityAliases` entry " &
              "or restore the name.")
            continue
          # The suite half of the selector is the half a move can silently
          # change, so it is asserted on its own rather than left implied by
          # the joined name.
          let historicSuite = historic[0 ..< historic.find("::")]
          check suites[current] == historicSuite
          inc preserved

    check preserved >= 1
    checkpoint("preserved " & $preserved & " suite::test selectors")

    # The membership table is the human decision point; if it stops agreeing
    # with the ledger, the ledger is describing a batch that is no longer the
    # one in the tree.
    let generator = readFile(repoRoot / GeneratorPath)
    for bundle in allBundles():
      check generator.contains("name: \"" & bundle["name"].getStr() & "\"")
      for member in bundle["members"]:
        check generator.contains("\"" & member["source"].getStr() & "\"")
